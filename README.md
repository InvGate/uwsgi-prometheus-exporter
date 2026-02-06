# uWSGI Prometheus Metrics Exporter

A uWSGI plugin that exports metrics in Prometheus text exposition format.

## What it does

This plugin reads metrics from uWSGI's metrics subsystem and exposes them in Prometheus format. It converts uWSGI's hierarchical metric names (like `worker.1.requests`) into Prometheus metrics with labels (like `uwsgi_worker_requests{worker="1"}`).

The plugin supports two modes:
- **Route handler**: Serves metrics through the application workers at a specific path
- **Dedicated server**: Runs a separate metrics server in the master process

## Building

```bash
cd /path/to/uwsgi
python uwsgiconfig.py --plugin plugins/metrics_prometheus
```

This creates `metrics_prometheus_plugin.so` in the current directory.

## Installation

Copy the plugin to where uWSGI can find it:

```bash
# System-wide installation
cp metrics_prometheus_plugin.so /usr/lib/uwsgi/plugins/

# Or use an absolute path in your config
# plugin = /path/to/metrics_prometheus_plugin.so
```

## Configuration

### Dedicated Server Mode

The dedicated server runs in the master process and doesn't use application workers.

```ini
[uwsgi]
master = true
enable-metrics = true
plugin = metrics_prometheus
prometheus-server = :9090

# Your application config
http = :8080
wsgi-file = app.py
processes = 4
```

Access metrics at `http://localhost:9090` (any path works).

### Route Handler Mode

The route handler serves metrics through application workers.

```ini
[uwsgi]
enable-metrics = true
plugin = metrics_prometheus
route = ^/metrics$ prometheus-metrics:

# Your application config
http = :8080
wsgi-file = app.py
processes = 4
```

Access metrics at `http://localhost:8080/metrics` (only the matched path).

### Using Both Modes

You can enable both modes simultaneously if needed.

```ini
[uwsgi]
master = true
enable-metrics = true
plugin = metrics_prometheus
prometheus-server = :9090
route = ^/metrics$ prometheus-metrics:

# Your application config
http = :8080
wsgi-file = app.py
processes = 4
```

## Configuration Options

| Option | Description |
|--------|-------------|
| `--enable-metrics` | Required. Enables uWSGI's metrics subsystem |
| `--master` | Required for dedicated server mode |
| `--prometheus-server ADDRESS` | Enable dedicated server on ADDRESS (e.g., `:9090`, `127.0.0.1:9090`) |
| `--prometheus-prefix STRING` | Prefix for metric names (default: `uwsgi_`) |
| `--prometheus-no-workers` | Don't export per-worker metrics |
| `--prometheus-no-help` | Don't include HELP comments |
| `--prometheus-no-type` | Don't include TYPE comments |

### Address Formats

TCP socket:
- `:9090` - Listen on all interfaces
- `127.0.0.1:9090` - Listen on localhost only
- `0.0.0.0:9090` - Listen on all interfaces

Unix socket:
- `/tmp/metrics.sock` - Unix domain socket

## Metric Format

The plugin converts uWSGI metrics to Prometheus format:

| uWSGI Metric | Prometheus Metric | Labels |
|--------------|-------------------|--------|
| `worker.1.requests` | `uwsgi_worker_requests` | `worker="1"` |
| `worker.2.exceptions` | `uwsgi_worker_exceptions` | `worker="2"` |
| `core.1.2.requests` | `uwsgi_core_requests` | `worker="1", core="2"` |

Numeric segments in metric names become labels:
- First number: `worker` label
- Second number: `core` label
- Third number: `thread` label
- Fourth number: `id` label

Text segments become the metric name with dots replaced by underscores.

## Prometheus Configuration

Configure Prometheus to scrape the metrics endpoint:

```yaml
scrape_configs:
  - job_name: 'uwsgi'
    static_configs:
      - targets: ['localhost:9090']
    scrape_interval: 15s
```

If using route handler mode, specify the metrics path:

```yaml
scrape_configs:
  - job_name: 'uwsgi'
    static_configs:
      - targets: ['localhost:8080']
    metrics_path: '/metrics'
    scrape_interval: 15s
```

## Verification

Check that metrics are valid:

```bash
curl -s http://localhost:9090 | promtool check metrics
```

## Troubleshooting

### No metrics available

Error: `Metrics subsystem not initialized`

Make sure you have:
```ini
enable-metrics = true
```

Check that your uWSGI binary supports metrics:
```bash
uwsgi --help | grep enable-metrics
```

If the option doesn't appear, your uWSGI binary was compiled without metrics support.

### Dedicated server won't start

Error: `Failed to bind to :9090`

Check if the port is already in use:
```bash
netstat -ln | grep 9090
```

Make sure you have:
```ini
master = true
```

### Plugin not loading

Error: `!!! no plugin loaded !!!`

Check that the plugin file exists:
```bash
ls -l metrics_prometheus_plugin.so
```

Try using an absolute path:
```ini
plugin = /full/path/to/metrics_prometheus_plugin.so
```

## Examples

### Simple setup

```ini
[uwsgi]
master = true
enable-metrics = true
plugin = metrics_prometheus
prometheus-server = 127.0.0.1:9090

http = :8080
wsgi-file = app.py
processes = 4
```

### Custom prefix

```ini
[uwsgi]
master = true
enable-metrics = true
plugin = metrics_prometheus
prometheus-server = :9090
prometheus-prefix = myapp_

http = :8080
wsgi-file = app.py
processes = 4
```

### Reduced output

```ini
[uwsgi]
master = true
enable-metrics = true
plugin = metrics_prometheus
prometheus-server = :9090
prometheus-no-workers = true
prometheus-no-help = true

http = :8080
wsgi-file = app.py
processes = 16
```

### Unix socket

```ini
[uwsgi]
master = true
enable-metrics = true
plugin = metrics_prometheus
prometheus-server = /tmp/uwsgi-metrics.sock
chmod-socket = 660

http = :8080
wsgi-file = app.py
processes = 4
```

## Testing

Start the server:
```bash
./uwsgi --ini config.ini
```

Check metrics:
```bash
curl http://localhost:9090
```

Validate format:
```bash
curl -s http://localhost:9090 | promtool check metrics
```

## Development

### Debug build

Edit `uwsgiplugin.py` and add debug flags:
```python
CFLAGS = ['-g', '-O0']
```

Then rebuild:
```bash
python uwsgiconfig.py --plugin plugins/metrics_prometheus
```

### Testing with GDB

```bash
gdb --args uwsgi --plugin ./metrics_prometheus_plugin.so --ini config.ini
(gdb) break prometheus_generate_metrics
(gdb) run
```

### Testing with Valgrind

```bash
valgrind --leak-check=full uwsgi --plugin ./metrics_prometheus_plugin.so --ini config.ini
```

## Files

- `plugin.c` - Main plugin source code
- `uwsgiplugin.py` - Build configuration
- `README.md` - This file
- `PLUGIN_README.md` - Developer documentation
