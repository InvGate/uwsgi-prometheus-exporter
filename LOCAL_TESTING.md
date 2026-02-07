# Local Testing Guide

Test the plugin build and test suite locally before pushing to GitHub.

## Quick Start

```bash
# Run the full test suite
./test-local.sh
```

This will:
1. ✅ Check dependencies
2. ✅ Clone uWSGI source
3. ✅ Build uWSGI with Python support
4. ✅ Build the plugin
5. ✅ Run smoke tests
6. ✅ Run the full test suite
7. ✅ Clean up automatically

## Prerequisites

Install required dependencies:

### Ubuntu/Debian
```bash
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    python3 \
    python3-dev \
    libpcre3-dev \
    libssl-dev \
    zlib1g-dev \
    git \
    curl
```

### Optional: Install promtool for format validation
```bash
PROMTOOL_VERSION="2.48.1"
wget https://github.com/prometheus/prometheus/releases/download/v${PROMTOOL_VERSION}/prometheus-${PROMTOOL_VERSION}.linux-amd64.tar.gz
tar xzf prometheus-${PROMTOOL_VERSION}.linux-amd64.tar.gz
sudo cp prometheus-${PROMTOOL_VERSION}.linux-amd64/promtool /usr/local/bin/
```

## Usage Options

### Basic usage
```bash
./test-local.sh
```

### Test against a specific uWSGI version
```bash
UWSGI_VERSION="2.0.23" ./test-local.sh
```

### Keep the build directory for inspection
```bash
CLEAN_ON_EXIT=no ./test-local.sh
```

### Use a custom work directory
```bash
WORK_DIR=/tmp/my-test ./test-local.sh
```

### Combine options
```bash
UWSGI_VERSION="2.0.23" CLEAN_ON_EXIT=no WORK_DIR=/tmp/test ./test-local.sh
```

## What Gets Tested

The script replicates the GitHub Actions workflow:

1. **Dependency Check** - Verifies all build tools are available
2. **uWSGI Clone** - Downloads uWSGI source code
3. **uWSGI Build** - Compiles uWSGI with full Python support
4. **Plugin Copy** - Copies plugin files to uWSGI plugins directory
5. **Plugin Build** - Compiles the Prometheus plugin
6. **Plugin Load Test** - Verifies the plugin loads and registers options
7. **Smoke Test** - Starts uWSGI briefly to ensure basic functionality
8. **Route Handler Tests** - Tests metrics via route handler mode
9. **Dedicated Server Tests** - Tests metrics via dedicated server mode

## Troubleshooting

### Missing dependencies

If you see errors about missing dependencies:
```bash
sudo apt-get install build-essential python3-dev libpcre3-dev
```

### Build fails

Check the build log:
```bash
cat /tmp/uwsgi-build.log
```

### Tests fail

Check uWSGI logs:
```bash
cat /tmp/uwsgi_route.log
cat /tmp/uwsgi_server.log
```

### Keep files for debugging

```bash
CLEAN_ON_EXIT=no ./test-local.sh
```

Then inspect:
```bash
cd /tmp/uwsgi-test-*/uwsgi
./uwsgi --version
ls -la metrics_prometheus_plugin.so
```

## Fast Iteration

If you're making changes to the plugin and want to test quickly:

```bash
# Keep the work directory
CLEAN_ON_EXIT=no WORK_DIR=/tmp/uwsgi-test ./test-local.sh

# Make changes to your plugin code
vim plugin.c

# Rebuild just the plugin
cd /tmp/uwsgi-test/uwsgi
python3 uwsgiconfig.py --plugin plugins/metrics_prometheus

# Run tests manually
plugins/metrics_prometheus/t/test.sh
```

## Differences from GitHub Actions

The local script is essentially identical to GitHub Actions, with these differences:

- **Location**: Runs in `/tmp` instead of GitHub runner workspace
- **Cleanup**: Controlled via `CLEAN_ON_EXIT` variable
- **Promtool**: Only used if already installed
- **Parallel**: Runs sequentially (GitHub Actions may run steps in parallel)

## Exit Codes

- `0` - All tests passed successfully
- `1` - Build or tests failed

## Output

The script provides colored output:
- 🔵 **INFO** (blue) - Informational messages
- 🟢 **SUCCESS** (green) - Successful operations
- 🟡 **WARNING** (yellow) - Non-critical warnings
- 🔴 **ERROR** (red) - Failures

## CI/CD Validation

After local tests pass:

```bash
# Commit your changes
git add .
git commit -m "Your changes"

# Push to GitHub
git push origin main

# Watch the Actions tab for results
```

The GitHub Actions workflow should now succeed since you've validated locally!

## Examples

### Test the current plugin
```bash
./test-local.sh
```

### Test against uWSGI 2.0.22
```bash
UWSGI_VERSION="2.0.22" ./test-local.sh
```

### Debug a failing test
```bash
# Run with preserved files
CLEAN_ON_EXIT=no ./test-local.sh

# Inspect the logs
cat /tmp/uwsgi_route.log

# Check the build directory
cd /tmp/uwsgi-test-*/uwsgi
./uwsgi --version
./uwsgi --plugin ./metrics_prometheus_plugin.so --help
```

### Quick rebuild after code changes
```bash
# First run (saves to /tmp/uwsgi-dev)
CLEAN_ON_EXIT=no WORK_DIR=/tmp/uwsgi-dev ./test-local.sh

# Make changes to plugin.c
vim plugin.c

# Copy updated file and rebuild
cp plugin.c /tmp/uwsgi-dev/uwsgi/plugins/metrics_prometheus/
cd /tmp/uwsgi-dev/uwsgi
python3 uwsgiconfig.py --plugin plugins/metrics_prometheus

# Run tests
plugins/metrics_prometheus/t/test.sh
```

## Integration with Your Workflow

Add to your development workflow:

```bash
# 1. Make changes
vim plugin.c

# 2. Test locally
./test-local.sh

# 3. If tests pass, commit
git add plugin.c
git commit -m "Fix: your change description"

# 4. Push to GitHub
git push origin main

# 5. Verify GitHub Actions passes
```

This ensures you catch issues locally before they fail in CI!
