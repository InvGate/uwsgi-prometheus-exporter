# uWSGI Prometheus Plugin - Maintainer's Guide

This document explains the internal architecture and implementation details for developers maintaining or extending the Prometheus metrics exporter plugin.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Key Data Structures](#key-data-structures)
3. [Plugin Lifecycle](#plugin-lifecycle)
4. [Request Flow](#request-flow)
5. [Thread Safety](#thread-safety)
6. [Common Pitfalls](#common-pitfalls)
7. [Extending the Plugin](#extending-the-plugin)
8. [Debugging Guide](#debugging-guide)

---

## Architecture Overview

### High-Level Flow

#### Route Handler Mode
```
uWSGI Startup
    ↓
Plugin Load (metrics_prometheus_init)
    ↓
Register Route Handler "prometheus-metrics"
    ↓
[Runtime] HTTP Request → Route Match
    ↓
uwsgi_routing_func_prometheus_metrics()
    ↓
prometheus_generate_metrics()
    ↓
Iterate uwsgi.metrics linked list
    ↓
Format each metric to Prometheus text format
    ↓
Send HTTP response with metrics
```

#### Dedicated Server Mode
```
uWSGI Startup
    ↓
Plugin Load (metrics_prometheus_init)
    ↓
Post-Init Hook (metrics_prometheus_post_init)
    ↓
Initialize Dedicated Server (prometheus_server_init)
    ↓
Bind Socket & Set Non-Blocking
    ↓
[Runtime] Master Cycle Hook (prometheus_master_cycle)
    ↓
Check for Incoming Connections (select)
    ↓
Accept Connection
    ↓
prometheus_server_handle_request()
    ↓
prometheus_generate_metrics()
    ↓
Send HTTP Response with Metrics
    ↓
Close Connection
```

### Design Principles

1. **On-Demand Generation**: Metrics are formatted on each request, not cached
2. **No State**: Plugin doesn't maintain any state between requests
3. **Read-Only**: Plugin never modifies metrics, only reads them
4. **Defensive**: Extensive validation to handle corrupt/incomplete metrics

---

## Key Data Structures

### 1. `struct uwsgi_server uwsgi` (uwsgi.h)

The global uWSGI server instance. Key fields for this plugin:

```c
struct uwsgi_server {
    struct uwsgi_metric *metrics;  // Head of metrics linked list
    void *metrics_lock;            // Read-write lock (pthread_rwlock_t)
    size_t page_size;              // System page size (used for buffer allocation)
    int has_metrics;               // Flag indicating if metrics subsystem is enabled
    // ... many other fields
};
```

**Critical**: Check metrics availability using:
- `uwsgi.has_metrics`: Boolean flag indicating if metrics subsystem is enabled
- `uwsgi.metrics`: Pointer to head of metrics linked list (may be NULL if no metrics registered)

**Always check `uwsgi.has_metrics` before accessing `uwsgi.metrics`!**

### 2. `struct uwsgi_metric` (uwsgi.h)

Individual metric structure (linked list node):

```c
struct uwsgi_metric {
    char *name;              // Metric name (e.g., "worker.1.requests")
    size_t name_len;         // Length of name
    uint8_t type;            // UWSGI_METRIC_COUNTER/GAUGE/ABSOLUTE
    int64_t *value;          // Pointer to actual value (NOT the value itself!)
    int64_t initial_value;   // Reset value
    struct uwsgi_metric *next;  // Next metric in list
    // ... other fields for OID, collection, etc.
};
```

**Important**: `value` is a **pointer**. Always check for NULL before dereferencing.

### 3. `struct uwsgi_buffer` (uwsgi.h)

Dynamic string buffer with automatic growth:

```c
struct uwsgi_buffer {
    char *buf;      // Buffer data
    size_t pos;     // Current position (bytes used)
    size_t size;    // Total allocated size
    size_t chunk;   // Growth increment
    // ... other fields
};
```

**Key Functions**:
- `uwsgi_buffer_new(size)`: Allocate new buffer
- `uwsgi_buffer_append(buf, data, len)`: Append data (auto-grows if needed)
- `uwsgi_buffer_num64(buf, num)`: Append int64 as string
- `uwsgi_buffer_destroy(buf)`: Free buffer

**Critical**: Always destroy buffers to avoid memory leaks!

### 4. `struct wsgi_request` (uwsgi.h)

Per-request context passed to route handlers:

```c
struct wsgi_request {
    // Request data
    char *method;
    uint16_t method_len;
    char *uri;
    uint16_t uri_len;

    // Response handling
    struct uwsgi_buffer *response_headers;

    // Connection state
    int fd;

    // ... many other fields
};
```

Use these functions to build responses:
- `uwsgi_response_prepare_headers(wsgi_req, status, status_len)`
- `uwsgi_response_add_content_type(wsgi_req, type, type_len)`
- `uwsgi_response_add_content_length(wsgi_req, length)`
- `uwsgi_response_write_body_do(wsgi_req, body, body_len)`

### 5. `struct uwsgi_route` (uwsgi.h)

Route configuration:

```c
struct uwsgi_route {
    char *pattern;                  // Regex pattern (e.g., "^/metrics$")
    int (*func)(struct wsgi_request *, struct uwsgi_route *);  // Handler function
    void *data;                     // Custom data
    size_t data_len;
    void *data2;                    // Additional custom data
    // ... other fields
};
```

**Handler Return Values**:
- `UWSGI_ROUTE_BREAK`: Stop processing routes (response sent)
- `UWSGI_ROUTE_NEXT`: Continue to next route
- `UWSGI_ROUTE_CONTINUE`: Re-run routing chain

---

## Plugin Lifecycle

### 1. Plugin Load (Startup)

```c
metrics_prometheus_init()
```

**When**: Once, during uWSGI startup (before workers fork)

**Actions**:
1. Initialize `ump_config` defaults
2. Register route handler via `uwsgi_register_router()`
3. Log initialization message

**Constraints**:
- Don't allocate per-request resources
- Don't access `uwsgi.metrics` (not initialized yet)
- Don't spawn threads/processes

### 2. Route Registration

```c
uwsgi_router_prometheus_metrics(struct uwsgi_route *ur, char *args)
```

**When**: During configuration parsing, when route is encountered

**Actions**:
1. Set `ur->func` to request handler
2. Store route arguments in `ur->data` (if any)

**Example Route**:
```ini
route = ^/metrics$ prometheus-metrics:arg1,arg2
```
- Pattern: `^/metrics$`
- Handler: `prometheus-metrics`
- Args: `arg1,arg2` (passed to registration function)

### 3. Post-Initialization (After Fork)

```c
metrics_prometheus_post_init()
```

**When**: Once, after workers have forked (only in master process if master mode enabled)

**Actions**:
1. Check if `--prometheus-server` is configured
2. Check if master mode is enabled
3. If both true: initialize dedicated server via `prometheus_server_init()`
4. If server configured but no master: log error message

**Constraints**:
- Only runs in master process (`uwsgi.master_process` check)
- Requires master mode for dedicated server

### 4. Request Handling (Runtime)

#### Route Handler Mode

```c
uwsgi_routing_func_prometheus_metrics(struct wsgi_request *wsgi_req, struct uwsgi_route *ur)
```

**When**: Every time a request matches the route pattern

**Flow**:
1. Validate metrics initialized (`uwsgi.has_metrics`)
2. Generate metrics output
3. Build HTTP response
4. Send response
5. Return `UWSGI_ROUTE_BREAK`

#### Dedicated Server Mode

```c
prometheus_master_cycle()
prometheus_server_handle_request()
```

**When**:
- `prometheus_master_cycle()`: Called repeatedly in master process event loop
- `prometheus_server_handle_request()`: Called when connection is available

**Flow**:
1. Check if server socket has incoming connection (non-blocking select)
2. Accept connection
3. Read HTTP request (simplified, don't parse)
4. Generate metrics output
5. Build raw HTTP response with headers
6. Send response
7. Close connection

---

## Request Flow

### Detailed Step-by-Step

1. **Request arrives**: uWSGI receives HTTP request
2. **Route matching**: uWSGI evaluates route patterns
3. **Handler invocation**: If pattern matches, calls our handler
4. **Validation**: Check `uwsgi.metrics` is valid
5. **Allocation**: Create output buffer and temp buffers
6. **Iteration**: Walk `uwsgi.metrics` linked list
7. **Conversion**: For each metric:
   - Parse name and extract labels
   - Generate HELP comment (if enabled)
   - Generate TYPE comment (if enabled)
   - Read value (with locking)
   - Format metric line
8. **Response**: Build HTTP response with headers
9. **Cleanup**: Destroy all buffers
10. **Return**: Stop route processing

### Performance Characteristics

- **Time Complexity**: O(n) where n = number of metrics
- **Space Complexity**: O(n) for output buffer
- **Locks Held**: Read lock held briefly per metric (not across entire loop)
- **Allocations**: 3 buffers per request (main output, name temp, labels temp)

**Typical Response Time**: <10ms for 100 metrics

---

## Thread Safety

### Locking Strategy

**Read-Write Lock**: `uwsgi.metrics_lock` (pthread_rwlock_t)

- **Read Lock** (shared): Multiple readers can hold simultaneously
- **Write Lock** (exclusive): Only one writer, blocks all readers

**This Plugin's Usage**:
- Always acquires **read lock** when reading metric values
- Never acquires write lock (read-only plugin)

### Lock Acquisition Pattern

```c
// CORRECT: Acquire read lock
uwsgi_rlock(uwsgi.metrics_lock);
int64_t value = *um->value;
uwsgi_rwunlock(uwsgi.metrics_lock);

// WRONG: No lock (race condition!)
int64_t value = *um->value;

// WRONG: Checking if lock exists (causes crash!)
if (uwsgi.metrics_lock) {  // metrics_lock is struct, not pointer!
    uwsgi_rlock(uwsgi.metrics_lock);
}
```

### Lock Scope

**Principle**: Hold locks for **minimum duration**

- ✅ **Good**: Lock per metric value read
- ❌ **Bad**: Lock entire linked list iteration

**Rationale**: Other threads need to update metrics. Don't block them unnecessarily.

### Concurrent Access

**Safe Operations** (while holding read lock):
- Reading `um->name`, `um->name_len`, `um->type`
- Reading `*um->value` (the value, not the pointer)

**Unsafe Operations** (even with read lock):
- Modifying any metric fields
- Walking linked list while another thread adds/removes metrics

**Note**: Linked list structure is stable in practice (metrics registered at startup),
but defensive code should still validate pointers.

---

## Common Pitfalls

### 1. Metrics Not Initialized ⚠️

**Problem**: Accessing `uwsgi.metrics` when metrics subsystem is disabled

```c
// WRONG: May crash if metrics not enabled
if (uwsgi.metrics) {
    struct uwsgi_metric *um = uwsgi.metrics;
    // May crash or return invalid data
}

// CORRECT: Check has_metrics flag first
if (!uwsgi.has_metrics || !uwsgi.metrics) {
    // Handle metrics not available case
    uwsgi_log("[prometheus] Metrics subsystem not initialized\n");
    return;
}
```

**Why**: The metrics subsystem must be explicitly enabled with `--enable-metrics`

### 2. String Length Off-by-One 🔢

**Problem**: Including null terminator in string length

```c
// WRONG: Length includes '\0' → "Nul byte in header"
uwsgi_response_add_content_type(wsgi_req, "text/plain", 11);  // 10 + 1

// CORRECT: Length excludes '\0'
uwsgi_response_add_content_type(wsgi_req, "text/plain", 10);
```

**Always use**: `strlen()` or count characters manually (excluding '\0')

### 3. Checking metrics_lock Existence ❌

**Problem**: Treating `metrics_lock` as pointer

```c
// WRONG: metrics_lock is a struct, not pointer!
if (uwsgi.metrics_lock) {
    uwsgi_rlock(uwsgi.metrics_lock);
}

// CORRECT: Just use it directly
uwsgi_rlock(uwsgi.metrics_lock);
uwsgi_rwunlock(uwsgi.metrics_lock);
```

### 4. Memory Leaks 💧

**Problem**: Not destroying buffers on error paths

```c
// WRONG: Leaks buffer on error
struct uwsgi_buffer *buf = uwsgi_buffer_new(1024);
if (some_error) {
    return NULL;  // Buffer leaked!
}
uwsgi_buffer_destroy(buf);

// CORRECT: Destroy on all paths
struct uwsgi_buffer *buf = uwsgi_buffer_new(1024);
if (some_error) {
    uwsgi_buffer_destroy(buf);
    return NULL;
}
uwsgi_buffer_destroy(buf);
```

**Use goto for cleanup**:
```c
struct uwsgi_buffer *buf1 = uwsgi_buffer_new(1024);
struct uwsgi_buffer *buf2 = uwsgi_buffer_new(1024);

if (error) goto cleanup;
// ... more code ...

cleanup:
    if (buf1) uwsgi_buffer_destroy(buf1);
    if (buf2) uwsgi_buffer_destroy(buf2);
    return result;
```

### 5. Dedicated Server Without Master Mode ❌

**Problem**: Configuring `--prometheus-server` without `--master`

```ini
# WRONG: Dedicated server requires master mode
[uwsgi]
enable-metrics = true
prometheus-server = :9090
# master = true  ← Missing!
```

**Result**: Server will not start, error logged:
```
[prometheus] ERROR: dedicated server requires master mode. Add 'master = true' to your config.
```

**Fix**:
```ini
# CORRECT: Enable master mode
[uwsgi]
master = true
enable-metrics = true
prometheus-server = :9090
```

**Why**: The dedicated server runs in the master process event loop, which only exists when master mode is enabled.

### 6. Ignoring Return Values ⚠️

**Problem**: Not checking if buffer operations succeed

```c
// WRONG: Buffer might be full, append fails silently
uwsgi_buffer_append(buf, data, len);
more_code();

// CORRECT: Check return value
if (uwsgi_buffer_append(buf, data, len)) {
    // Handle error (buffer full, allocation failed, etc.)
    goto error;
}
```

---

## Extending the Plugin

### Plugin Configuration Structure

```c
struct uwsgi_metrics_prometheus_config {
    char *prefix;           // Metric name prefix (default: "uwsgi_")
    char *server_address;   // Dedicated server address (e.g., ":9090")
    int server_fd;          // Server socket file descriptor
    int no_workers;         // Skip per-worker metrics flag
    int include_help;       // Include HELP comments flag
    int include_type;       // Include TYPE comments flag
} ump_config;
```

### Adding New Configuration Options

1. **Add field to config struct**:
```c
struct uwsgi_metrics_prometheus_config {
    char *prefix;
    int no_workers;
    int my_new_option;  // Add here
} ump_config;
```

2. **Register option**:
```c
static struct uwsgi_option metrics_prometheus_options[] = {
    // ... existing options ...
    {"prometheus-my-option", required_argument, 0, "description",
     uwsgi_opt_set_int, &ump_config.my_new_option, 0},
    UWSGI_END_OF_OPTIONS
};
```

3. **Use in code**:
```c
if (ump_config.my_new_option) {
    // Do something
}
```

### Adding Custom Label Extraction

Currently, numeric segments become labels. To add custom label extraction:

**Modify `prometheus_format_metric_name()`**:

```c
// Example: Extract custom labels from metric name patterns
if (uwsgi_starts_with(um->name, um->name_len, "custom.", 7)) {
    // Parse custom format
    // Add custom labels to labels_buf
}
```

### Adding Metric Filtering

To filter metrics based on custom criteria:

**Modify `prometheus_generate_metrics()`**:

```c
// Skip metrics matching certain pattern
if (should_skip_metric(um->name, um->name_len)) {
    um = um->next;
    continue;
}
```

### Supporting Additional Output Formats

To support other formats (e.g., JSON, InfluxDB line protocol):

1. Create new generation function: `json_generate_metrics()`
2. Register new route handler: `prometheus-json`
3. Call appropriate generator based on route

---

## Debugging Guide

### Build with Debug Symbols

```bash
# Edit uwsgiplugin.py
CFLAGS = ['-g', '-O0']

# Rebuild
python uwsgiconfig.py --plugin plugins/metrics_prometheus
```

### Using GDB

```bash
# Start under GDB
gdb --args uwsgi --plugin ./metrics_prometheus_plugin.so --enable-metrics ...

# Set breakpoints
(gdb) break prometheus_generate_metrics
(gdb) break uwsgi_routing_func_prometheus_metrics

# Run
(gdb) run

# When breakpoint hits
(gdb) print uwsgi.metrics           # Check metrics pointer
(gdb) print *um                     # Inspect current metric
(gdb) print um->name                # Print metric name
(gdb) print *um->value              # Print metric value
(gdb) backtrace                     # Show call stack
```

### Using Valgrind

```bash
# Check for memory errors
valgrind --leak-check=full \
         --track-origins=yes \
         --log-file=valgrind.log \
         uwsgi --plugin ./metrics_prometheus_plugin.so ...

# Check log
cat valgrind.log
```

### Common Debug Scenarios

**Crash on metrics access**:
1. Check if `uwsgi.has_metrics` is true
2. Check if `uwsgi.metrics` is NULL
3. Check if `um->value` is NULL
4. Verify metrics enabled with `--enable-metrics`

**Wrong output**:
1. Print buffer contents: `(gdb) print ub->buf`
2. Check metric name conversion
3. Verify label extraction logic

**Memory leak**:
1. Valgrind will show leaked buffers
2. Check all error paths destroy buffers
3. Verify cleanup on early returns

### Logging

Add debug logging:

```c
uwsgi_log("[prometheus] Debug info: %s = %ld\n", um->name, *um->value);
```

Enable verbose logging:
```bash
uwsgi --logto /tmp/uwsgi.log --log-date ...
```

---

## Testing

### Automated Test Suite

The plugin includes a test suite in `t/` directory:

```bash
# From uWSGI root directory
./plugins/metrics_prometheus/t/test.sh
```

This tests both operation modes automatically.

### Manual Testing

1. **Test route handler mode**:
   ```bash
   uwsgi --enable-metrics --plugin ./metrics_prometheus_plugin.so \
         --http :8080 --wsgi-file test_app.py \
         --route '^/metrics$ prometheus-metrics:'
   curl http://localhost:8080/metrics
   ```

2. **Test dedicated server mode**:
   ```bash
   uwsgi --master --enable-metrics --plugin ./metrics_prometheus_plugin.so \
         --http :8080 --wsgi-file test_app.py \
         --prometheus-server :9090
   curl http://localhost:9090
   ```

3. **Test metrics disabled**:
   ```bash
   uwsgi --plugin ./metrics_prometheus_plugin.so \
         --http :8080 --wsgi-file test_app.py \
         --route '^/metrics$ prometheus-metrics:'
   curl http://localhost:8080/metrics  # Should get 503
   ```

4. **Test with load**:
   ```bash
   ab -n 10000 -c 100 http://localhost:8080/
   curl http://localhost:9090  # Should show requests counter
   ```

5. **Test with valgrind**:
   ```bash
   valgrind --leak-check=full uwsgi --master --enable-metrics \
            --plugin ./metrics_prometheus_plugin.so \
            --http :8080 --wsgi-file test_app.py \
            --prometheus-server :9090 &
   # Generate requests
   curl http://localhost:9090
   # Kill uwsgi, check valgrind output for leaks
   ```

### Integration Testing

Test with real Prometheus:

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'uwsgi'
    static_configs:
      - targets: ['localhost:9090']
    metrics_path: '/metrics'
```

```bash
prometheus --config.file=prometheus.yml
# Check http://localhost:9090/targets
# Should show uwsgi endpoint as "UP"
```

---

## References

### uWSGI Headers

- **uwsgi.h**: Main header with all structures
- **core/metrics.c**: Metrics subsystem implementation
- **core/routing.c**: Routing subsystem implementation

### Key Functions

From uwsgi.h:

```c
// Buffer operations
struct uwsgi_buffer *uwsgi_buffer_new(size_t);
int uwsgi_buffer_append(struct uwsgi_buffer *, char *, size_t);
int uwsgi_buffer_num64(struct uwsgi_buffer *, int64_t);
void uwsgi_buffer_destroy(struct uwsgi_buffer *);

// Response building
int uwsgi_response_prepare_headers(struct wsgi_request *, char *, uint16_t);
int uwsgi_response_add_content_type(struct wsgi_request *, char *, uint16_t);
int uwsgi_response_add_content_length(struct wsgi_request *, uint64_t);
int uwsgi_response_write_body_do(struct wsgi_request *, char *, size_t);

// Routing
struct uwsgi_router *uwsgi_register_router(char *, int (*)(struct uwsgi_route *, char *));

// Metrics
struct uwsgi_metric *uwsgi_register_metric(char *, char *, uint8_t, char *, void *, uint32_t, void *);

// Locking
void uwsgi_rlock(pthread_rwlock_t);
void uwsgi_wlock(pthread_rwlock_t);
void uwsgi_rwunlock(pthread_rwlock_t);

// Utility
int uwsgi_starts_with(char *, size_t, char *, size_t);
void uwsgi_log(const char *, ...);

// Socket operations (for dedicated server)
int bind_to_tcp(char *address, int listen_queue, char *tcp_port);
int bind_to_unix(char *address, int listen_queue, int chmod_socket, int abstract_socket);
void uwsgi_socket_nb(int fd);  // Set socket non-blocking
void uwsgi_error(const char *);  // Log errno-based error

// I/O operations
ssize_t read(int fd, void *buf, size_t count);
ssize_t write(int fd, const void *buf, size_t count);
int fcntl(int fd, int cmd, ...);  // File control operations
```

### External Documentation

- [uWSGI Metrics Subsystem](https://uwsgi-docs.readthedocs.io/en/latest/Metrics.html)
- [uWSGI Internal Routing](https://uwsgi-docs.readthedocs.io/en/latest/InternalRouting.html)
- [Prometheus Exposition Format](https://prometheus.io/docs/instrumenting/exposition_formats/)

---

## Maintenance Checklist

When making changes:

- [ ] Update comments in plugin.c
- [ ] Update this README if architecture changes
- [ ] Test with valgrind for memory leaks
- [ ] Test with metrics enabled and disabled
- [ ] Test with high load (concurrent requests)
- [ ] Verify output with `promtool check metrics`
- [ ] Check uWSGI logs for errors
- [ ] Update version/changelog if applicable

---

## Contact / Questions

For questions about uWSGI plugin development:
- uWSGI mailing list
- uWSGI GitHub issues
- #uwsgi IRC channel

For Prometheus format questions:
- Prometheus documentation
- Prometheus mailing list
