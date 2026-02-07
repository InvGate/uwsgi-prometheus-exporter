#!/bin/bash
#
# Local testing script for uWSGI Prometheus plugin
# Run this to test the build process locally before pushing to GitHub
#

set -e  # Exit on error

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Cleanup function
cleanup() {
    if [ ! -z "$UWSGI_PID" ] && ps -p $UWSGI_PID > /dev/null 2>&1; then
        info "Cleaning up uWSGI process (PID: $UWSGI_PID)..."
        kill $UWSGI_PID 2>/dev/null || true
        sleep 0.5
        kill -9 $UWSGI_PID 2>/dev/null || true
    fi
    if [ "$CLEAN_ON_EXIT" = "yes" ] && [ -d "$WORK_DIR" ]; then
        info "Cleaning up work directory: $WORK_DIR"
        cd /
        rm -rf "$WORK_DIR"
    fi
}

trap cleanup EXIT INT TERM

# Configuration
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-/tmp/uwsgi-test-$$}"
UWSGI_VERSION="${UWSGI_VERSION:-latest}"
CLEAN_ON_EXIT="${CLEAN_ON_EXIT:-yes}"

echo ""
echo "========================================="
echo "  uWSGI Prometheus Plugin Local Test"
echo "========================================="
echo ""
info "Plugin directory: $PLUGIN_DIR"
info "Work directory: $WORK_DIR"
info "uWSGI version: $UWSGI_VERSION"
echo ""

# Check dependencies
info "Checking dependencies..."
MISSING_DEPS=()

for cmd in git python3 gcc make curl; do
    if ! command -v $cmd &> /dev/null; then
        MISSING_DEPS+=($cmd)
    fi
done

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    error "Missing required dependencies: ${MISSING_DEPS[*]}"
    echo ""
    echo "Install them with:"
    echo "  sudo apt-get install ${MISSING_DEPS[*]} build-essential python3-dev libpcre3-dev"
    exit 1
fi
success "All dependencies found"

# Check for promtool
if command -v promtool &> /dev/null; then
    success "promtool found - will validate Prometheus format"
    HAS_PROMTOOL=1
else
    warning "promtool not found - skipping format validation"
    HAS_PROMTOOL=0
fi

# Create work directory
info "Creating work directory..."
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Clone uWSGI
info "Cloning uWSGI source..."
if [ "$UWSGI_VERSION" = "latest" ]; then
    git clone --depth 1 https://github.com/unbit/uwsgi.git
else
    git clone --depth 1 --branch "$UWSGI_VERSION" https://github.com/unbit/uwsgi.git
fi
success "uWSGI cloned"

# Copy plugin files
info "Copying plugin files..."
mkdir -p uwsgi/plugins/metrics_prometheus
cp "$PLUGIN_DIR/plugin.c" uwsgi/plugins/metrics_prometheus/
cp "$PLUGIN_DIR/uwsgiplugin.py" uwsgi/plugins/metrics_prometheus/
cp "$PLUGIN_DIR/README.md" uwsgi/plugins/metrics_prometheus/ 2>/dev/null || true
cp "$PLUGIN_DIR/PLUGIN_README.md" uwsgi/plugins/metrics_prometheus/ 2>/dev/null || true
cp -r "$PLUGIN_DIR/t" uwsgi/plugins/metrics_prometheus/
success "Plugin files copied"

cd uwsgi

# Build uWSGI
info "Building uWSGI (this may take a few minutes)..."
python3 uwsgiconfig.py --build > /tmp/uwsgi-build.log 2>&1
if [ $? -ne 0 ]; then
    error "uWSGI build failed!"
    echo "Build log:"
    tail -50 /tmp/uwsgi-build.log
    exit 1
fi
success "uWSGI built successfully"

# Check uWSGI capabilities
info "Checking uWSGI capabilities..."
./uwsgi --version | head -5

echo ""
info "Checking for required features..."
./uwsgi --help | grep -q "wsgi-file" && success "  ✓ Python/WSGI support" || error "  ✗ Python/WSGI support missing"
./uwsgi --help | grep -q "enable-metrics" && success "  ✓ Metrics support" || error "  ✗ Metrics support missing"
./uwsgi --help | grep -q "route " && success "  ✓ Routing support" || error "  ✗ Routing support missing"

# Build plugin
info "Building Prometheus plugin..."
python3 uwsgiconfig.py --plugin plugins/metrics_prometheus
if [ ! -f metrics_prometheus_plugin.so ]; then
    error "Plugin build failed - metrics_prometheus_plugin.so not found"
    exit 1
fi
success "Plugin built: $(ls -lh metrics_prometheus_plugin.so | awk '{print $5}')"

# Test plugin loading
info "Testing plugin loading..."
./uwsgi --plugin ./metrics_prometheus_plugin.so --help | grep -q "prometheus-prefix"
if [ $? -eq 0 ]; then
    success "Plugin loads correctly and registers options"
else
    error "Plugin failed to register options"
    exit 1
fi

# Smoke test
info "Running smoke test (starting uWSGI briefly)..."
timeout 5 ./uwsgi \
    --plugin ./metrics_prometheus_plugin.so \
    --enable-metrics \
    --http-socket :18888 \
    --wsgi-file plugins/metrics_prometheus/t/test_app.py \
    --processes 1 \
    --route '^/metrics$ prometheus-metrics:' \
    > /tmp/uwsgi-smoke.log 2>&1 &
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
    echo "Smoke test log:"
    cat /tmp/uwsgi-smoke.log
    exit 1
fi

# Run full test suite
info "Running full test suite..."
echo ""
chmod +x plugins/metrics_prometheus/t/test.sh
if plugins/metrics_prometheus/t/test.sh; then
    echo ""
    success "All tests passed! ✨"
else
    echo ""
    error "Tests failed!"
    echo ""
    echo "Check logs at:"
    echo "  - /tmp/uwsgi_route.log"
    echo "  - /tmp/uwsgi_server.log"
    exit 1
fi

echo ""
echo "========================================="
success "Local testing completed successfully!"
echo "========================================="
echo ""
info "The plugin is ready to push to GitHub"
info "Built plugin location: $WORK_DIR/uwsgi/metrics_prometheus_plugin.so"
echo ""

if [ "$CLEAN_ON_EXIT" = "yes" ]; then
    info "Work directory will be cleaned up on exit"
    info "To keep it, set: export CLEAN_ON_EXIT=no"
else
    info "Work directory preserved: $WORK_DIR"
fi
