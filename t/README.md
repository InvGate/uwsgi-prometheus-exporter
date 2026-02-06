# Prometheus Plugin Tests

This directory contains tests for the uWSGI Prometheus metrics plugin.

## Prerequisites

- uWSGI built from source
- Plugin compiled: `python uwsgiconfig.py --plugin plugins/metrics_prometheus`
- `curl` installed
- `promtool` (optional, for format validation)

## Running Tests

From the uWSGI root directory:

```bash
./plugins/metrics_prometheus/t/test.sh
```

The script must be run from the uWSGI root directory because it needs to find the `uwsgi` binary and plugin file.

## What Gets Tested

### Route Handler Mode Tests

1. Server starts successfully
2. Application endpoint responds
3. Metrics endpoint (`/metrics`) responds with HTTP 200
4. Content-Type header is correct
5. Output is valid Prometheus format
6. Metrics have the correct prefix
7. Metrics update after generating traffic
8. Worker metrics are present

### Dedicated Server Mode Tests

1. Server starts successfully
2. Application endpoint responds
3. Dedicated metrics server responds with HTTP 200
4. Content-Type header is correct
5. Output is valid Prometheus format
6. Metrics work on any path (not just `/metrics`)
7. Metrics update after generating traffic
8. Worker metrics are present

## Test Configurations

- `route_handler.ini` - Tests route handler mode on port 8080
- `dedicated_server.ini` - Tests dedicated server mode (app on 8081, metrics on 9090)
- `test_app.py` - Simple WSGI app used for testing

## Test Output

The script produces colored output:
- Green [PASS] for successful tests
- Red [FAIL] for failed tests
- Yellow [INFO] for informational messages

Temporary files are created in `/tmp/`:
- `/tmp/metrics_route.txt` - Route handler metrics output
- `/tmp/metrics_route_after.txt` - Metrics after traffic
- `/tmp/metrics_server.txt` - Dedicated server metrics output
- `/tmp/metrics_server_after.txt` - Metrics after traffic

## Exit Codes

- `0` - All tests passed
- `1` - One or more tests failed

## Optional: Install promtool

For complete format validation, install Prometheus tools:

```bash
# On Ubuntu/Debian
wget https://github.com/prometheus/prometheus/releases/download/v2.x.x/prometheus-2.x.x.linux-amd64.tar.gz
tar xvf prometheus-2.x.x.linux-amd64.tar.gz
sudo cp prometheus-2.x.x.linux-amd64/promtool /usr/local/bin/

# Or use your package manager
```

Without `promtool`, the script performs basic validation (checks for HELP and TYPE comments).

## Troubleshooting

### Plugin not found

Make sure you've built the plugin:
```bash
python uwsgiconfig.py --plugin plugins/metrics_prometheus
ls -l metrics_prometheus_plugin.so
```

### Port already in use

The tests use ports 8080, 8081, and 9090. Make sure these are free:
```bash
netstat -ln | grep -E '8080|8081|9090'
```

### Tests hang

If tests hang, kill any running uWSGI processes:
```bash
pkill -f uwsgi
```

### Manual testing

You can run the configurations manually:
```bash
# Route handler mode
./uwsgi --ini plugins/metrics_prometheus/t/route_handler.ini

# In another terminal
curl http://localhost:8080/metrics
```

```bash
# Dedicated server mode
./uwsgi --ini plugins/metrics_prometheus/t/dedicated_server.ini

# In another terminal
curl http://localhost:9090
```
