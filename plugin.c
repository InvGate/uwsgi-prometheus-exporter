/*
 * ===========================================================================
 * uWSGI Prometheus Metrics Exporter Plugin
 * ===========================================================================
 *
 * This plugin provides TWO ways to expose metrics:
 *
 * 1. ROUTE HANDLER (uses application workers):
 *    --route '^/metrics$ prometheus-metrics:'
 *
 * 2. DEDICATED SERVER (runs in master, no worker overhead):
 *    --prometheus-server :9091
 *    --prometheus-server /tmp/prometheus.sock
 *
 * The dedicated server runs in the master process and doesn't block application
 * workers, making it ideal for high-traffic production environments.
 *
 * ===========================================================================
 */

#include <uwsgi.h>

#ifdef UWSGI_ROUTING

extern struct uwsgi_server uwsgi;

/*
 * ===========================================================================
 * CONFIGURATION
 * ===========================================================================
 */

struct uwsgi_metrics_prometheus_config {
	char *prefix;
	int no_workers;
	int include_help;
	int include_type;
	char *server_address;     // NEW: Dedicated server address (e.g., ":9091")
	int server_fd;            // NEW: Server socket file descriptor
} ump_config;

static struct uwsgi_option metrics_prometheus_options[] = {
	{"prometheus-prefix", required_argument, 0, "set metrics prefix (default: uwsgi_)", uwsgi_opt_set_str, &ump_config.prefix, 0},
	{"prometheus-no-workers", no_argument, 0, "skip per-worker metrics", uwsgi_opt_true, &ump_config.no_workers, 0},
	{"prometheus-no-help", no_argument, 0, "disable HELP comments", uwsgi_opt_false, &ump_config.include_help, 0},
	{"prometheus-no-type", no_argument, 0, "disable TYPE comments", uwsgi_opt_false, &ump_config.include_type, 0},
	{"prometheus-server", required_argument, 0, "enable dedicated metrics server on address (e.g., :9091 or /tmp/metrics.sock)", uwsgi_opt_set_str, &ump_config.server_address, 0},
	UWSGI_END_OF_OPTIONS
};

/*
 * ===========================================================================
 * UTILITY FUNCTIONS
 * ===========================================================================
 */

/*
 * Simple set to track seen metric names (for HELP/TYPE deduplication)
 */
struct seen_metric_name {
	char *name;
	size_t name_len;
	struct seen_metric_name *next;
};

static struct seen_metric_name *seen_names_create(void) {
	return NULL;  // Empty list
}

static int seen_names_contains(struct seen_metric_name *head, const char *name, size_t name_len) {
	struct seen_metric_name *current = head;
	while (current) {
		if (current->name_len == name_len && memcmp(current->name, name, name_len) == 0) {
			return 1;  // Found
		}
		current = current->next;
	}
	return 0;  // Not found
}

static struct seen_metric_name *seen_names_add(struct seen_metric_name *head, const char *name, size_t name_len) {
	struct seen_metric_name *node = uwsgi_malloc(sizeof(struct seen_metric_name));
	if (!node) return head;

	node->name = uwsgi_malloc(name_len);
	if (!node->name) {
		free(node);
		return head;
	}

	memcpy(node->name, name, name_len);
	node->name_len = name_len;
	node->next = head;
	return node;
}

static void seen_names_destroy(struct seen_metric_name *head) {
	while (head) {
		struct seen_metric_name *next = head->next;
		free(head->name);
		free(head);
		head = next;
	}
}

__attribute__((unused))
static int prometheus_escape_string(struct uwsgi_buffer *ub, const char *str, size_t len) {
	size_t i;
	for (i = 0; i < len; i++) {
		switch (str[i]) {
			case '\\':
				if (uwsgi_buffer_append(ub, (char *)"\\\\", 2)) return -1;
				break;
			case '"':
				if (uwsgi_buffer_append(ub, (char *)"\\\"", 2)) return -1;
				break;
			case '\n':
				if (uwsgi_buffer_append(ub, (char *)"\\n", 2)) return -1;
				break;
			default:
				if (uwsgi_buffer_append(ub, (char *)&str[i], 1)) return -1;
				break;
		}
	}
	return 0;
}

static int prometheus_format_metric_name(struct uwsgi_buffer *name_buf, struct uwsgi_buffer *labels_buf,
                                         const char *metric_name, size_t metric_name_len, const char *prefix) {
	size_t i, label_index = 0;
	char segment[256];
	size_t segment_len = 0;
	int is_numeric = 1;
	int in_numeric_sequence = 0;
	char label_names[4][16] = {"worker", "core", "thread", "id"};

	name_buf->pos = 0;
	labels_buf->pos = 0;

	if (uwsgi_buffer_append(name_buf, (char *)prefix, strlen(prefix))) return -1;

	for (i = 0; i <= metric_name_len; i++) {
		if (i == metric_name_len || metric_name[i] == '.') {
			if (segment_len > 0) {
				size_t j;
				is_numeric = 1;
				for (j = 0; j < segment_len; j++) {
					if (segment[j] < '0' || segment[j] > '9') {
						is_numeric = 0;
						break;
					}
				}

				if (is_numeric && segment_len > 0) {
					if (label_index < 4) {
						if (labels_buf->pos > 0) {
							if (uwsgi_buffer_append(labels_buf, (char *)",", 1)) return -1;
						}
						if (uwsgi_buffer_append(labels_buf, label_names[label_index], strlen(label_names[label_index]))) return -1;
						if (uwsgi_buffer_append(labels_buf, (char *)"=\"", 2)) return -1;
						if (uwsgi_buffer_append(labels_buf, segment, segment_len)) return -1;
						if (uwsgi_buffer_append(labels_buf, (char *)"\"", 1)) return -1;
						label_index++;
					}
					in_numeric_sequence = 1;
				} else {
					if (name_buf->pos > strlen(prefix) && !in_numeric_sequence) {
						if (uwsgi_buffer_append(name_buf, (char *)"_", 1)) return -1;
					}
					if (uwsgi_buffer_append(name_buf, segment, segment_len)) return -1;
					in_numeric_sequence = 0;
				}
				segment_len = 0;
			}
		} else {
			if (segment_len < sizeof(segment) - 1) {
				char c = metric_name[i];
				if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
				    (c >= '0' && c <= '9') || c == '_') {
					segment[segment_len++] = c;
				} else {
					segment[segment_len++] = '_';
				}
			}
		}
	}

	return 0;
}

static struct uwsgi_buffer *prometheus_generate_metrics(void) {
	struct uwsgi_buffer *ub = uwsgi_buffer_new(uwsgi.page_size);
	if (!ub) {
		uwsgi_log("[prometheus] Failed to allocate output buffer\n");
		return NULL;
	}

	struct uwsgi_buffer *name_buf = uwsgi_buffer_new(256);
	struct uwsgi_buffer *labels_buf = uwsgi_buffer_new(256);
	if (!name_buf || !labels_buf) {
		uwsgi_log("[prometheus] Failed to allocate conversion buffers\n");
		if (name_buf) uwsgi_buffer_destroy(name_buf);
		if (labels_buf) uwsgi_buffer_destroy(labels_buf);
		uwsgi_buffer_destroy(ub);
		return NULL;
	}

	// Track seen metric names to avoid duplicate HELP/TYPE comments
	struct seen_metric_name *seen_names = seen_names_create();

	const char *prefix = ump_config.prefix ? ump_config.prefix : "uwsgi_";

	if (!uwsgi.has_metrics || !uwsgi.metrics ) {
		uwsgi_log("[prometheus] No metrics available (metrics=%p)\n", uwsgi.metrics);
		uwsgi_buffer_destroy(name_buf);
		uwsgi_buffer_destroy(labels_buf);
		seen_names_destroy(seen_names);
		return ub;
	}

	struct uwsgi_metric *um = uwsgi.metrics;
	while (um){
		if (!um->name || um->name_len == 0 || !um->value) {
			um = um->next;
			continue;
		}

		if (ump_config.no_workers && uwsgi_starts_with(um->name, um->name_len, (char *)"worker.", 7)) {
			um = um->next;
			continue;
		}

		if (prometheus_format_metric_name(name_buf, labels_buf, um->name, um->name_len, prefix) < 0) {
			uwsgi_log("[prometheus] Failed to format metric: %.*s\n", (int)um->name_len, um->name);
			um = um->next;
			continue;
		}

		if (name_buf->pos == 0) {
			um = um->next;
			continue;
		}

		// Append _total suffix for counter metrics (Prometheus best practice)
		if (um->type == UWSGI_METRIC_COUNTER) {
			if (uwsgi_buffer_append(name_buf, (char *)"_total", 6)) {
				uwsgi_log("[prometheus] Failed to append _total suffix\n");
				um = um->next;
				continue;
			}
		}

		// Only emit HELP and TYPE if we haven't seen this metric name before
		int is_new_metric = !seen_names_contains(seen_names, name_buf->buf, name_buf->pos);
		if (is_new_metric) {
			if (ump_config.include_help) {
				if (uwsgi_buffer_append(ub, (char *)"# HELP ", 7)) goto error;
				if (uwsgi_buffer_append(ub, name_buf->buf, name_buf->pos)) goto error;
				if (uwsgi_buffer_append(ub, (char *)" ", 1)) goto error;
				if (uwsgi_buffer_append(ub, um->name, um->name_len)) goto error;
				if (uwsgi_buffer_append(ub, (char *)"\n", 1)) goto error;
			}

			if (ump_config.include_type) {
				if (uwsgi_buffer_append(ub, (char *)"# TYPE ", 7)) goto error;
				if (uwsgi_buffer_append(ub, name_buf->buf, name_buf->pos)) goto error;

				const char *prom_type = "untyped";
				switch (um->type) {
					case UWSGI_METRIC_COUNTER:
						prom_type = "counter";
						break;
					case UWSGI_METRIC_GAUGE:
						prom_type = "gauge";
						break;
					case UWSGI_METRIC_ABSOLUTE:
						prom_type = "gauge";
						break;
				}

				if (uwsgi_buffer_append(ub, (char *)" ", 1)) goto error;
				if (uwsgi_buffer_append(ub, (char *)prom_type, strlen(prom_type))) goto error;
				if (uwsgi_buffer_append(ub, (char *)"\n", 1)) goto error;
			}

			// Mark this metric name as seen
			seen_names = seen_names_add(seen_names, name_buf->buf, name_buf->pos);
		}

		if (uwsgi_buffer_append(ub, name_buf->buf, name_buf->pos)) goto error;

		if (labels_buf->pos > 0) {
			if (uwsgi_buffer_append(ub, (char *)"{", 1)) goto error;
			if (uwsgi_buffer_append(ub, labels_buf->buf, labels_buf->pos)) goto error;
			if (uwsgi_buffer_append(ub, (char *)"}", 1)) goto error;
		}

		if (uwsgi_buffer_append(ub, (char *)" ", 1)) goto error;

		uwsgi_rlock(uwsgi.metrics_lock);
		int64_t value = *um->value;
		uwsgi_rwunlock(uwsgi.metrics_lock);

		if (uwsgi_buffer_num64(ub, value)) goto error;
		if (uwsgi_buffer_append(ub, (char *)"\n", 1)) goto error;

		um = um->next;
	}

	uwsgi_buffer_destroy(name_buf);
	uwsgi_buffer_destroy(labels_buf);
	seen_names_destroy(seen_names);
	return ub;

error:
	uwsgi_buffer_destroy(name_buf);
	uwsgi_buffer_destroy(labels_buf);
	uwsgi_buffer_destroy(ub);
	seen_names_destroy(seen_names);
	return NULL;
}

/*
 * ===========================================================================
 * DEDICATED SERVER (NEW)
 * ===========================================================================
 */

/**
 * Handle incoming connection on dedicated metrics server
 *
 * This runs in the master process, not in workers.
 * Accepts connection, reads HTTP request, sends metrics, closes connection.
 *
 * Called from master_cycle hook when server_fd has activity.
 */
static void prometheus_server_handle_request(void) {
	struct sockaddr_un client_src;
	socklen_t client_src_len = sizeof(struct sockaddr_un);

	// Accept connection
	int client_fd = accept(ump_config.server_fd, (struct sockaddr *) &client_src, &client_src_len);
	if (client_fd < 0) {
		if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
			uwsgi_error("[prometheus] accept()");
		}
		return;
	}

	// Set socket to blocking mode for simplicity
	int flags = fcntl(client_fd, F_GETFL, 0);
	fcntl(client_fd, F_SETFL, flags & ~O_NONBLOCK);

	// Read HTTP request (we don't actually parse it, just read and discard)
	char request_buf[4096];
	ssize_t rlen = read(client_fd, request_buf, sizeof(request_buf) - 1);
	if (rlen <= 0) {
		close(client_fd);
		return;
	}

	// Generate metrics
	struct uwsgi_buffer *metrics = prometheus_generate_metrics();
	if (!metrics) {
		const char *response =
			"HTTP/1.0 500 Internal Server Error\r\n"
			"Content-Type: text/plain\r\n"
			"Content-Length: 28\r\n"
			"\r\n"
			"Failed to generate metrics\n";
		if (write(client_fd, response, strlen(response)) < 0) {
			uwsgi_error("[prometheus] write()");
		}
		close(client_fd);
		return;
	}

	// Build HTTP response
	struct uwsgi_buffer *response = uwsgi_buffer_new(uwsgi.page_size);
	if (!response) {
		uwsgi_buffer_destroy(metrics);
		close(client_fd);
		return;
	}

	// Status line
	uwsgi_buffer_append(response, (char *)"HTTP/1.0 200 OK\r\n", 17);

	// Headers
	uwsgi_buffer_append(response, (char *)"Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n", 56);

	// Content-Length
	uwsgi_buffer_append(response, (char *)"Content-Length: ", 16);
	uwsgi_buffer_num64(response, metrics->pos);
	uwsgi_buffer_append(response, (char *)"\r\n", 2);

	// Connection header
	uwsgi_buffer_append(response, (char *)"Connection: close\r\n", 19);

	// End of headers
	uwsgi_buffer_append(response, (char *)"\r\n", 2);

	// Send headers
	if (write(client_fd, response->buf, response->pos) < 0) {
		uwsgi_error("[prometheus] write()");
	}

	// Send body
	if (write(client_fd, metrics->buf, metrics->pos) < 0) {
		uwsgi_error("[prometheus] write()");
	}

	// Cleanup
	uwsgi_buffer_destroy(response);
	uwsgi_buffer_destroy(metrics);
	close(client_fd);
}

/**
 * Master cycle hook - called repeatedly in master process
 *
 * Checks if there's activity on our server socket and handles it.
 */
static void prometheus_master_cycle(void) {
	// Only run if server is configured
	if (ump_config.server_fd < 0) return;

	// Check if there's a connection waiting (non-blocking check)
	fd_set readfds;
	struct timeval tv = {0, 0};  // Don't block

	FD_ZERO(&readfds);
	FD_SET(ump_config.server_fd, &readfds);

	int ready = select(ump_config.server_fd + 1, &readfds, NULL, NULL, &tv);
	if (ready > 0 && FD_ISSET(ump_config.server_fd, &readfds)) {
		prometheus_server_handle_request();
	}
}

/**
 * Initialize dedicated metrics server
 *
 * Called during post_init (after workers forked, in master process).
 * Creates socket and sets it to non-blocking.
 */
static void prometheus_server_init(void) {
	if (!ump_config.server_address) return;

	uwsgi_log("[prometheus] Initializing dedicated metrics server on %s\n", ump_config.server_address);

	// Parse address (TCP port or Unix socket)
	char *tcp_port = strchr(ump_config.server_address, ':');

	if (tcp_port) {
		// TCP socket
		ump_config.server_fd = bind_to_tcp(ump_config.server_address, uwsgi.listen_queue, tcp_port);
	} else {
		// Unix socket
		ump_config.server_fd = bind_to_unix(ump_config.server_address, uwsgi.listen_queue, uwsgi.chmod_socket, uwsgi.abstract_socket);
	}

	if (ump_config.server_fd < 0) {
		uwsgi_log("[prometheus] ERROR: Failed to bind to %s\n", ump_config.server_address);
		return;
	}

	// Set socket to non-blocking
	uwsgi_socket_nb(ump_config.server_fd);

	uwsgi_log("[prometheus] *** Dedicated metrics server enabled on %s fd: %d ***\n",
	          ump_config.server_address, ump_config.server_fd);
	uwsgi_log("[prometheus] Metrics available at: http://<host>%s/metrics (or just access the address)\n",
	          tcp_port ? tcp_port : "");
}

/*
 * ===========================================================================
 * ROUTE HANDLER (same as before)
 * ===========================================================================
 */

static int uwsgi_routing_func_prometheus_metrics(struct wsgi_request *wsgi_req, struct uwsgi_route *ur) {
	if (!uwsgi.has_metrics || !uwsgi.metrics) {
		uwsgi_log("[prometheus] Metrics subsystem not initialized. Did you enable metrics with --enable-metrics?\n");
		if (uwsgi_response_prepare_headers(wsgi_req, (char *)"503 Service Unavailable", 23)) {
			return UWSGI_ROUTE_BREAK;
		}
		const char *error_msg = "Metrics subsystem not initialized. Enable with --enable-metrics\n";
		uwsgi_response_write_body_do(wsgi_req, (char *)error_msg, strlen(error_msg));
		return UWSGI_ROUTE_BREAK;
	}

	struct uwsgi_buffer *metrics = prometheus_generate_metrics();
	if (!metrics) {
		uwsgi_log("[prometheus] Failed to generate metrics buffer\n");
		if (uwsgi_response_prepare_headers(wsgi_req, (char *)"500 Internal Server Error", 25)) {
			return UWSGI_ROUTE_BREAK;
		}
		const char *error_msg = "Failed to generate metrics\n";
		uwsgi_response_write_body_do(wsgi_req, (char *)error_msg, strlen(error_msg));
		return UWSGI_ROUTE_BREAK;
	}

	if (uwsgi_response_prepare_headers(wsgi_req, (char *)"200 OK", 6)) {
		uwsgi_buffer_destroy(metrics);
		return UWSGI_ROUTE_BREAK;
	}

	if (uwsgi_response_add_content_type(wsgi_req, (char *)"text/plain; version=0.0.4; charset=utf-8", 40)) {
		uwsgi_buffer_destroy(metrics);
		return UWSGI_ROUTE_BREAK;
	}

	if (uwsgi_response_add_content_length(wsgi_req, metrics->pos)) {
		uwsgi_buffer_destroy(metrics);
		return UWSGI_ROUTE_BREAK;
	}

	if (uwsgi_response_write_body_do(wsgi_req, metrics->buf, metrics->pos)) {
		uwsgi_buffer_destroy(metrics);
		return UWSGI_ROUTE_BREAK;
	}

	uwsgi_buffer_destroy(metrics);
	return UWSGI_ROUTE_BREAK;
}

static int uwsgi_router_prometheus_metrics(struct uwsgi_route *ur, char *args) {
	ur->func = uwsgi_routing_func_prometheus_metrics;
	ur->data = args;
	ur->data_len = args ? strlen(args) : 0;
	return 0;
}

/*
 * ===========================================================================
 * PLUGIN INITIALIZATION
 * ===========================================================================
 */

static void metrics_prometheus_init(void) {
	// Initialize config
	ump_config.include_help = 1;
	ump_config.include_type = 1;
	ump_config.server_fd = -1;  // No server by default

	// Register route handler
	uwsgi_register_router("prometheus-metrics", uwsgi_router_prometheus_metrics);

	uwsgi_log("*** Prometheus metrics exporter plugin loaded ***\n");
}

/**
 * Post-init hook - called after workers forked, in master process only
 * This is where we initialize the dedicated server if configured.
 */
static void metrics_prometheus_post_init(void) {
	// Only initialize server if we're the master process
	if (ump_config.server_address) {
		if (uwsgi.master_process) {
			prometheus_server_init();
		} else {
			uwsgi_log("[prometheus] ERROR: dedicated server requires master mode. Add 'master = true' to your config.\n");
		}
	}
}

struct uwsgi_plugin metrics_prometheus_plugin = {
	.name = "metrics_prometheus",
	.options = metrics_prometheus_options,
	.on_load = metrics_prometheus_init,
	.post_init = metrics_prometheus_post_init,
	.master_cycle = prometheus_master_cycle,
};

#else
struct uwsgi_plugin metrics_prometheus_plugin = {
	.name = "metrics_prometheus",
};
#endif
