#!/bin/bash
#
# CI Build and Test Script for uWSGI Prometheus Plugin
# This script is used by GitHub Actions but can also be run locally
#

set -e  # Exit on error

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Cleanup function
cleanup() {
    if [ ! -z "$UWSGI_PID" ] && ps -p $UWSGI_PID > /dev/null 2>&1; then
        info "Cleaning up uWSGI process..."
        kill $UWSGI_PID 2>/dev/null || true
        sleep 0.5
        kill -9 $UWSGI_PID 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM

# Configuration
PLUGIN_DIR="${PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
WORK_DIR="${WORK_DIR:-$(pwd)}"
UWSGI_VERSION="${UWSGI_VERSION:-latest}"

echo ""
echo "========================================="
echo "  uWSGI Prometheus Plugin CI Build"
echo "========================================="
echo ""
info "Plugin source: $PLUGIN_DIR"
info "Work directory: $WORK_DIR"
info "uWSGI version: $UWSGI_VERSION"
echo ""

cd "$WORK_DIR"

# Step 1: Check dependencies
info "Checking dependencies..."
MISSING_DEPS=()
for cmd in git python3 gcc make curl; do
    if ! command -v $cmd &> /dev/null; then
        MISSING_DEPS+=($cmd)
    fi
done

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    error "Missing required dependencies: ${MISSING_DEPS[*]}"
    exit 1
fi
success "All required dependencies found"

if command -v promtool &> /dev/null; then
    success "promtool found - will validate Prometheus format"
    HAS_PROMTOOL=1
else
    warning "promtool not found - skipping format validation"
    HAS_PROMTOOL=0
fi
echo ""

# Step 2: Clone uWSGI
if [ ! -d "uwsgi" ]; then
    info "Cloning uWSGI source..."
    if [ "$UWSGI_VERSION" = "latest" ]; then
        git clone --depth 1 https://github.com/unbit/uwsgi.git
    else
        git clone --depth 1 --branch "$UWSGI_VERSION" https://github.com/unbit/uwsgi.git
    fi
    success "uWSGI cloned"
else
    info "Using existing uWSGI directory"
fi

cd uwsgi
UWSGI_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
info "uWSGI commit: $UWSGI_COMMIT"
echo ""

# Step 3: Copy plugin files
info "Copying plugin files..."
mkdir -p plugins/metrics_prometheus
cp "$PLUGIN_DIR/plugin.c" plugins/metrics_prometheus/
cp "$PLUGIN_DIR/uwsgiplugin.py" plugins/metrics_prometheus/
cp "$PLUGIN_DIR"/README.md plugins/metrics_prometheus/ 2>/dev/null || true
cp "$PLUGIN_DIR"/PLUGIN_README.md plugins/metrics_prometheus/ 2>/dev/null || true
cp -r "$PLUGIN_DIR/t" plugins/metrics_prometheus/
success "Plugin files copied"
ls -lh plugins/metrics_prometheus/
echo ""

# Step 4: Build uWSGI
if [ ! -f "uwsgi" ] || [ "${REBUILD:-no}" = "yes" ]; then
    info "Building uWSGI with Python support (this may take a few minutes)..."
    python3 uwsgiconfig.py --build > /tmp/uwsgi-build.log 2>&1 || {
        error "uWSGI build failed!"
        echo ""
        echo "Last 50 lines of build log:"
        tail -50 /tmp/uwsgi-build.log
        exit 1
    }
    success "uWSGI built successfully"
else
    info "Using existing uWSGI binary"
fi

./uwsgi --version | head -5
echo ""

# Step 5: Check uWSGI capabilities
info "Checking uWSGI capabilities..."
MISSING_FEATURES=()
./uwsgi --help | grep -q "wsgi-file" || MISSING_FEATURES+=("Python/WSGI")
./uwsgi --help | grep -q "enable-metrics" || MISSING_FEATURES+=("Metrics")
./uwsgi --help | grep -q "route " || MISSING_FEATURES+=("Routing")

if [ ${#MISSING_FEATURES[@]} -ne 0 ]; then
    error "Missing required features: ${MISSING_FEATURES[*]}"
    exit 1
fi
success "All required features available"
echo ""

# Step 6: Build plugin
if [ ! -f "metrics_prometheus_plugin.so" ] || [ "${REBUILD:-no}" = "yes" ]; then
    info "Building Prometheus plugin..."
    python3 uwsgiconfig.py --plugin plugins/metrics_prometheus || {
        error "Plugin build failed!"
        exit 1
    }
    success "Plugin built successfully"
else
    info "Using existing plugin"
fi

ls -lh metrics_prometheus_plugin.so
file metrics_prometheus_plugin.so
echo ""

# Step 7: Test plugin loading
info "Testing plugin loading..."
if ./uwsgi --plugin ./metrics_prometheus_plugin.so --help 2>&1 | grep -q "prometheus-prefix"; then
    success "Plugin loads and registers options correctly"
else
    error "Plugin failed to register options"
    exit 1
fi
echo ""

# Step 8: Quick startup test
info "Quick startup test (verifying uWSGI can start with plugin)..."
echo "Config:"
cat plugins/metrics_prometheus/t/route_handler.ini | head -20
echo ""

timeout 3 ./uwsgi --ini plugins/metrics_prometheus/t/route_handler.ini > /tmp/quick-test.log 2>&1 &
UWSGI_PID=$!
sleep 2

if ps -p $UWSGI_PID > /dev/null 2>&1; then
    success "uWSGI started successfully (PID: $UWSGI_PID)"
    kill $UWSGI_PID 2>/dev/null || true
    sleep 1
    kill -9 $UWSGI_PID 2>/dev/null || true
    UWSGI_PID=""
else
    error "uWSGI failed to start"
    echo ""
    echo "Startup log:"
    cat /tmp/quick-test.log
    exit 1
fi
echo ""

# Step 9: Run full test suite
info "Running full test suite..."
echo ""

chmod +x plugins/metrics_prometheus/t/test.sh

# Run tests with monitoring
(
    while true; do
        if [ -f /tmp/uwsgi_route.log ] && [ ! -f /tmp/.shown_route ]; then
            echo ""
            warning "uWSGI route handler log detected:"
            echo "----------------------------------------"
            cat /tmp/uwsgi_route.log
            echo "----------------------------------------"
            touch /tmp/.shown_route
        fi
        if [ -f /tmp/uwsgi_server.log ] && [ ! -f /tmp/.shown_server ]; then
            echo ""
            warning "uWSGI dedicated server log detected:"
            echo "----------------------------------------"
            cat /tmp/uwsgi_server.log
            echo "----------------------------------------"
            touch /tmp/.shown_server
        fi
        sleep 0.5
    done
) &
MONITOR_PID=$!

plugins/metrics_prometheus/t/test.sh 2>&1 | tee /tmp/test_output.log
TEST_RESULT=$?

kill $MONITOR_PID 2>/dev/null || true
rm -f /tmp/.shown_route /tmp/.shown_server

echo ""
if [ $TEST_RESULT -eq 0 ]; then
    success "All tests passed! ✨"
else
    error "Tests failed (exit code: $TEST_RESULT)"
    echo ""
    echo "Recent test output:"
    tail -30 /tmp/test_output.log || true
    echo ""
    echo "Recent uWSGI logs:"
    if [ -f /tmp/uwsgi_route.log ]; then
        echo "--- Route handler (last 20 lines) ---"
        tail -20 /tmp/uwsgi_route.log
    fi
    if [ -f /tmp/uwsgi_server.log ]; then
        echo "--- Dedicated server (last 20 lines) ---"
        tail -20 /tmp/uwsgi_server.log
    fi
    exit 1
fi

# Step 10: Create artifact
info "Preparing artifact..."
cp metrics_prometheus_plugin.so metrics_prometheus.so
PLUGIN_SIZE=$(du -h metrics_prometheus.so | cut -f1)
success "Plugin ready: $PLUGIN_SIZE"
echo ""

echo "========================================="
success "Build and test completed successfully!"
echo "========================================="
echo ""
info "Plugin location: $(pwd)/metrics_prometheus.so"
info "Plugin size: $PLUGIN_SIZE"
echo ""
