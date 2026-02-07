#!/bin/bash
#
# Test suite for uWSGI Prometheus metrics plugin
#
# This script tests both operation modes:
# 1. Route handler mode
# 2. Dedicated server mode
#

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Utility functions
info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

run_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
    info "Test $TESTS_RUN: $1"
}

# Check if we're in the right directory
if [ ! -f "uwsgi" ] || [ ! -f "uwsgiconfig.py" ]; then
    echo "Error: Must be run from uWSGI root directory"
    exit 1
fi

# Check if plugin is built
if [ ! -f "metrics_prometheus_plugin.so" ]; then
    echo "Error: Plugin not built. Run: python uwsgiconfig.py --plugin plugins/metrics_prometheus"
    exit 1
fi

# Check if promtool is available
HAS_PROMTOOL=0
if command -v promtool &> /dev/null; then
    HAS_PROMTOOL=1
    info "promtool found - will validate Prometheus format"
else
    info "promtool not found - skipping format validation"
fi

# Cleanup function
cleanup() {
    if [ ! -z "$UWSGI_PID" ] && ps -p $UWSGI_PID > /dev/null 2>&1; then
        kill $UWSGI_PID 2>/dev/null || true
        sleep 0.2
        # Force kill if still running
        if ps -p $UWSGI_PID > /dev/null 2>&1; then
            kill -9 $UWSGI_PID 2>/dev/null || true
        fi
    fi
}

trap cleanup EXIT INT TERM

#
# Validation functions
#

validate_http_response() {
    local url="$1"
    local expected_code="$2"

    local code=$(curl --max-time 5 -s -o /dev/null -w "%{http_code}" "$url")
    if [ "$code" = "$expected_code" ]; then
        success "HTTP response code is $code"
        return 0
    else
        fail "Expected HTTP $expected_code, got $code"
        return 1
    fi
}

validate_content_type() {
    local url="$1"

    local content_type=$(curl --max-time 5 -s -I "$url" | grep -i "content-type" | cut -d: -f2 | tr -d ' \r')
    if echo "$content_type" | grep -q "text/plain"; then
        success "Content-Type is correct: $content_type"
        return 0
    else
        fail "Content-Type is wrong: $content_type"
        return 1
    fi
}

validate_prometheus_format() {
    local url="$1"
    local output_file="$2"

    curl --max-time 5 -s "$url" > "$output_file" 2>/tmp/curl_error.log
    local curl_exit=$?

    if [ $curl_exit -ne 0 ]; then
        fail "Failed to fetch metrics from $url (curl exit code: $curl_exit)"
        return 1
    fi

    local size=$(stat -f%z "$output_file" 2>/dev/null || stat -c%s "$output_file")
    if [ "$size" -eq 0 ]; then
        fail "Metrics output is empty (0 bytes)"
        return 1
    fi

    if [ $HAS_PROMTOOL -eq 1 ]; then
        if timeout 5 promtool check metrics < "$output_file" > /dev/null 2>&1; then
            success "Prometheus format is valid (promtool)"
            return 0
        else
            fail "Prometheus format is invalid (promtool)"
            return 1
        fi
    else
        # Basic validation without promtool
        if grep -q "^# HELP" "$output_file" && grep -q "^# TYPE" "$output_file"; then
            success "Output contains HELP and TYPE comments"
            return 0
        else
            fail "Output missing HELP or TYPE comments"
            return 1
        fi
    fi
}

validate_metric_present() {
    local file="$1"
    local metric="$2"

    if grep -q "^$metric" "$file"; then
        success "Metric '$metric' is present"
        return 0
    else
        fail "Metric '$metric' is missing"
        return 1
    fi
}

validate_metric_format() {
    local file="$1"

    # Check that metric lines have proper format: name{labels} value
    local invalid_lines=$(grep -v "^#" "$file" | grep -v "^$" | grep -v -E '^[a-zA-Z_:][a-zA-Z0-9_:]* |^[a-zA-Z_:][a-zA-Z0-9_:]*\{.*\} ')

    if [ -z "$invalid_lines" ]; then
        success "All metric lines have valid format"
        return 0
    else
        fail "Some metric lines have invalid format"
        echo "$invalid_lines"
        return 1
    fi
}

generate_traffic() {
    local url="$1"
    local requests="$2"

    info "Generating $requests requests to $url"
    for i in $(seq 1 $requests); do
        curl --max-time 2 -s "$url" > /dev/null
    done
    success "Generated $requests requests"
}

#
# Test 1: Route Handler Mode
#

echo ""
echo "========================================="
echo "TEST SUITE 1: Route Handler Mode"
echo "========================================="
echo ""

info "Starting uWSGI with route handler configuration..."
./uwsgi --ini plugins/metrics_prometheus/t/route_handler.ini > /tmp/uwsgi_route.log 2>&1 &
UWSGI_PID=$!

info "Waiting for server to start..."
sleep 2

run_test "SIerver is running"
if ps -p $UWSGI_PID > /dev/null; then
    success "uWSGI process is running (PID: $UWSGI_PID)"
else
    fail "uWSGI process died"
    exit 1
fi

run_test "Application endpoint responds"
validate_http_response "http://127.0.0.1:8082/" "200"

run_test "Metrics endpoint responds"
validate_http_response "http://127.0.0.1:8082/metrics" "200"

run_test "Metrics endpoint has correct Content-Type"
validate_content_type "http://127.0.0.1:8082/metrics"

run_test "Metrics output is valid Prometheus format"
validate_prometheus_format "http://127.0.0.1:8082/metrics" "/tmp/metrics_route.txt"

run_test "Output contains uwsgi prefix"
if grep -q "^uwsgi_" "/tmp/metrics_route.txt"; then
    success "Metrics have uwsgi_ prefix"
else
    fail "Metrics missing uwsgi_ prefix"
fi

# Generate traffic and check metrics update
generate_traffic "http://127.0.0.1:8082/" 10

sleep 1

run_test "Metrics update after traffic"
curl --max-time 5 -s "http://127.0.0.1:8082/metrics" > "/tmp/metrics_route_after.txt"
if ! diff -q "/tmp/metrics_route.txt" "/tmp/metrics_route_after.txt" > /dev/null; then
    success "Metrics changed after traffic"
else
    fail "Metrics did not update"
fi

run_test "Worker metrics are present"
validate_metric_present "/tmp/metrics_route_after.txt" "uwsgi_workerrequests"

info "Stopping uWSGI (route handler test)..."
kill $UWSGI_PID 2>/dev/null || true
sleep 0.5
kill -9 $UWSGI_PID 2>/dev/null || true
UWSGI_PID=""

sleep 1

#
# Test 2: Dedicated Server Mode
#

echo ""
echo "========================================="
echo "TEST SUITE 2: Dedicated Server Mode"
echo "========================================="
echo ""

info "Starting uWSGI with dedicated server configuration..."
./uwsgi --ini plugins/metrics_prometheus/t/dedicated_server.ini > /tmp/uwsgi_server.log 2>&1 &
UWSGI_PID=$!

info "Waiting for server to start..."
sleep 3

run_test "Server is running"
if ps -p $UWSGI_PID > /dev/null; then
    success "uWSGI process is running (PID: $UWSGI_PID)"
else
    fail "uWSGI process died"
    exit 1
fi

run_test "Application endpoint responds"
validate_http_response "http://127.0.0.1:8081/" "200"

run_test "Dedicated metrics server responds"
validate_http_response "http://127.0.0.1:9091" "200"

run_test "Metrics server has correct Content-Type"
validate_content_type "http://127.0.0.1:9091"

sleep 0.5

run_test "Metrics output is valid Prometheus format"
validate_prometheus_format "http://127.0.0.1:9091" "/tmp/metrics_server.txt"

run_test "Metrics work on any path"
validate_http_response "http://127.0.0.1:9091/any/path" "200"

# Generate traffic and check metrics update
generate_traffic "http://127.0.0.1:8081/" 10

sleep 1

run_test "Metrics update after traffic"
curl --max-time 5 -s "http://127.0.0.1:9091" > "/tmp/metrics_server_after.txt"
if ! diff -q "/tmp/metrics_server.txt" "/tmp/metrics_server_after.txt" > /dev/null; then
    success "Metrics changed after traffic"
else
    fail "Metrics did not update"
fi

run_test "Worker metrics are present"
validate_metric_present "/tmp/metrics_server_after.txt" "uwsgi_workerrequests"

info "Stopping uWSGI (dedicated server test)..."
kill $UWSGI_PID 2>/dev/null || true
sleep 0.5
kill -9 $UWSGI_PID 2>/dev/null || true
UWSGI_PID=""

#
# Summary
#

echo ""
echo "========================================="
echo "TEST SUMMARY"
echo "========================================="
echo ""
echo "Total tests run:    $TESTS_RUN"
echo -e "${GREEN}Tests passed:       $TESTS_PASSED${NC}"
if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "${RED}Tests failed:       $TESTS_FAILED${NC}"
else
    echo "Tests failed:       $TESTS_FAILED"
fi
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
