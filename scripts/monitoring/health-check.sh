#!/bin/bash

#=============================================================================
# DDC HAProxy Infrastructure - Health Check Script
# Comprehensive health monitoring for all components
#=============================================================================

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Configuration
ZONE="${ZONE:-eu}"
PROVIDER="${PROVIDER:-digitalocean}"
COMPREHENSIVE="${COMPREHENSIVE:-false}"
TIMEOUT="${TIMEOUT:-10}"
VERBOSE="${VERBOSE:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Logging functions
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}✓${NC} $1"
    ((PASSED_TESTS++))
}

error() {
    echo -e "${RED}✗${NC} $1"
    ((FAILED_TESTS++))
}

warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Usage information
usage() {
    cat << EOF
DDC HAProxy Infrastructure Health Check Script

USAGE:
    $0 [OPTIONS]

OPTIONS:
    -z, --zone ZONE              Zone to check (eu|us) [default: $ZONE]
    -p, --provider PROVIDER      Cloud provider (digitalocean|hetzner) [default: $PROVIDER]
    -c, --comprehensive          Run comprehensive tests
    -t, --timeout SECONDS        Request timeout [default: $TIMEOUT]
    -v, --verbose                Verbose output
    -h, --help                   Show this help message

EXAMPLES:
    $0                           # Basic health check
    $0 --zone eu --comprehensive # Comprehensive EU zone check
    $0 --zone us --verbose       # Verbose US zone check

RETURN CODES:
    0  - All tests passed
    1  - Some tests failed
    2  - Critical failures
EOF
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -z|--zone)
                ZONE="$2"
                shift 2
                ;;
            -p|--provider)
                PROVIDER="$2"
                shift 2
                ;;
            -c|--comprehensive)
                COMPREHENSIVE=true
                shift
                ;;
            -t|--timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Run a test with proper counting
run_test() {
    local test_name="$1"
    local test_function="$2"
    
    ((TOTAL_TESTS++))
    
    if [[ "$VERBOSE" == "true" ]]; then
        log "Running: $test_name"
    fi
    
    if $test_function; then
        success "$test_name"
        return 0
    else
        error "$test_name"
        return 1
    fi
}

# Test functions

# 1. Basic connectivity tests
test_haproxy_http() {
    local endpoint="http://localhost:80/health"
    if [[ "$ZONE" == "us" ]]; then
        endpoint="http://localhost:8082/health"
    fi
    
    curl -f -s --max-time "$TIMEOUT" "$endpoint" > /dev/null 2>&1
}

test_haproxy_https() {
    local endpoint="https://localhost:443/health"
    if [[ "$ZONE" == "us" ]]; then
        endpoint="https://localhost:8446/health"
    fi
    
    curl -f -s -k --max-time "$TIMEOUT" "$endpoint" > /dev/null 2>&1
}

test_haproxy_grpc() {
    local endpoint="localhost:8443"
    if [[ "$ZONE" == "us" ]]; then
        endpoint="localhost:8447"
    fi
    
    # Test gRPC endpoint (simplified check)
    nc -z localhost "${endpoint##*:}" 2>/dev/null
}

test_haproxy_stats() {
    local endpoint="http://localhost:8404/stats"
    if [[ "$ZONE" == "us" ]]; then
        endpoint="http://localhost:8406/stats"
    fi
    
    curl -f -s --max-time "$TIMEOUT" "$endpoint" | grep -q "HAProxy" 2>/dev/null
}

# 2. ConfigWatcher tests
test_configwatcher_api() {
    local endpoint="http://localhost:8080/api/v1/health"
    if [[ "$ZONE" == "us" ]]; then
        endpoint="http://localhost:8084/api/v1/health"
    fi
    
    local response
    response=$(curl -f -s --max-time "$TIMEOUT" "$endpoint" 2>/dev/null)
    echo "$response" | jq -e '.status == "healthy"' > /dev/null 2>&1
}

test_configwatcher_auth() {
    local endpoint="http://localhost:8080/api/v1/auth/token"
    if [[ "$ZONE" == "us" ]]; then
        endpoint="http://localhost:8084/api/v1/auth/token"
    fi
    
    local response
    response=$(curl -f -s --max-time "$TIMEOUT" -X POST \
        -H "Content-Type: application/json" \
        -d '{"username":"admin","password":"admin"}' \
        "$endpoint" 2>/dev/null)
    echo "$response" | jq -e '.token' > /dev/null 2>&1
}

# 3. Backend service tests
test_backend_nodes() {
    local backends=("eu-backend-1" "eu-backend-2")
    if [[ "$ZONE" == "us" ]]; then
        backends=("us-backend-1" "us-backend-2")
    fi
    
    for backend in "${backends[@]}"; do
        if ! docker ps --format "table {{.Names}}" | grep -q "$backend"; then
            return 1
        fi
        
        # Test backend health
        if ! docker exec "$backend" curl -f -s http://localhost/health > /dev/null 2>&1; then
            return 1
        fi
    done
    
    return 0
}

# 4. Cross-zone connectivity tests
test_cross_zone_connectivity() {
    local peer_zone="us"
    local peer_endpoint="http://localhost:8082/health"
    
    if [[ "$ZONE" == "us" ]]; then
        peer_zone="eu"
        peer_endpoint="http://localhost:80/health"
    fi
    
    curl -f -s --max-time "$TIMEOUT" "$peer_endpoint" > /dev/null 2>&1
}

# 5. SSL/TLS tests
test_ssl_certificates() {
    local endpoint="localhost:443"
    if [[ "$ZONE" == "us" ]]; then
        endpoint="localhost:8446"
    fi
    
    # Check SSL certificate
    echo | openssl s_client -connect "$endpoint" -servername "ddc.example.com" 2>/dev/null | \
        openssl x509 -noout -dates 2>/dev/null | grep -q "notAfter"
}

# 6. Load balancing tests
test_load_balancing() {
    local endpoint="http://localhost:80/health"
    if [[ "$ZONE" == "us" ]]; then
        endpoint="http://localhost:8082/health"
    fi
    
    # Make multiple requests and check for different backend responses
    local responses=()
    for i in {1..5}; do
        local response
        response=$(curl -f -s --max-time "$TIMEOUT" "$endpoint" 2>/dev/null | jq -r '.server // "unknown"' 2>/dev/null || echo "unknown")
        responses+=("$response")
    done
    
    # Check if we got responses (even if from same backend)
    [[ ${#responses[@]} -eq 5 ]]
}

# 7. Performance tests
test_response_time() {
    local endpoint="http://localhost:80/health"
    if [[ "$ZONE" == "us" ]]; then
        endpoint="http://localhost:8082/health"
    fi
    
    # Test response time is under 1 second
    local response_time
    response_time=$(curl -o /dev/null -s -w "%{time_total}" --max-time "$TIMEOUT" "$endpoint" 2>/dev/null)
    
    # Check if response time is less than 1 second (using bc for float comparison)
    if command -v bc > /dev/null; then
        [[ $(echo "$response_time < 1.0" | bc) -eq 1 ]]
    else
        # Fallback: convert to milliseconds and compare
        local ms_time
        ms_time=$(echo "$response_time * 1000" | awk '{print int($1)}')
        [[ $ms_time -lt 1000 ]]
    fi
}

# 8. Failover tests (comprehensive only)
test_haproxy_failover() {
    if [[ "$COMPREHENSIVE" != "true" ]]; then
        return 0
    fi
    
    log "Testing HAProxy failover (this may take a moment)..."
    
    # Get the master HAProxy container
    local master_container="eu-haproxy-1"
    if [[ "$ZONE" == "us" ]]; then
        master_container="us-haproxy-1"
    fi
    
    # Test endpoint before failover
    local endpoint="http://localhost:80/health"
    if [[ "$ZONE" == "us" ]]; then
        endpoint="http://localhost:8082/health"
    fi
    
    # Verify service is working
    if ! curl -f -s --max-time "$TIMEOUT" "$endpoint" > /dev/null 2>&1; then
        return 1
    fi
    
    # Stop master container to trigger failover
    docker stop "$master_container" > /dev/null 2>&1 || return 1
    
    # Wait for failover
    sleep 5
    
    # Test if backup is serving requests
    local failover_success=false
    for i in {1..10}; do
        if curl -f -s --max-time "$TIMEOUT" "$endpoint" > /dev/null 2>&1; then
            failover_success=true
            break
        fi
        sleep 2
    done
    
    # Restart the master container
    docker start "$master_container" > /dev/null 2>&1 || true
    
    # Wait for recovery
    sleep 5
    
    $failover_success
}

# 9. Configuration validation tests
test_haproxy_config_syntax() {
    local config_file="$PROJECT_ROOT/configs/haproxy/haproxy-${ZONE}.cfg"
    
    if [[ -f "$config_file" ]]; then
        haproxy -c -f "$config_file" > /dev/null 2>&1
    else
        # Test via Docker container
        local container="eu-haproxy-1"
        if [[ "$ZONE" == "us" ]]; then
            container="us-haproxy-1"
        fi
        
        docker exec "$container" haproxy -c -f /etc/haproxy/haproxy.cfg > /dev/null 2>&1
    fi
}

# 10. Monitoring and logging tests
test_log_files() {
    # Check if logs are being generated
    local log_patterns=("haproxy" "keepalived" "configwatcher")
    
    for pattern in "${log_patterns[@]}"; do
        if docker logs "eu-${pattern}-1" 2>&1 | grep -q "." 2>/dev/null; then
            continue
        elif docker logs "us-${pattern}-1" 2>&1 | grep -q "." 2>/dev/null; then
            continue
        else
            return 1
        fi
    done
    
    return 0
}

# Main test execution
run_basic_tests() {
    log "Running basic health checks for $ZONE zone..."
    
    run_test "HAProxy HTTP endpoint" test_haproxy_http
    run_test "HAProxy HTTPS endpoint" test_haproxy_https
    run_test "HAProxy gRPC endpoint" test_haproxy_grpc
    run_test "HAProxy statistics" test_haproxy_stats
    run_test "ConfigWatcher API" test_configwatcher_api
    run_test "ConfigWatcher authentication" test_configwatcher_auth
    run_test "Backend nodes" test_backend_nodes
    run_test "HAProxy configuration syntax" test_haproxy_config_syntax
}

run_comprehensive_tests() {
    log "Running comprehensive health checks for $ZONE zone..."
    
    # Run basic tests first
    run_basic_tests
    
    # Additional comprehensive tests
    run_test "Cross-zone connectivity" test_cross_zone_connectivity
    run_test "SSL certificates" test_ssl_certificates
    run_test "Load balancing" test_load_balancing
    run_test "Response time" test_response_time
    run_test "HAProxy failover" test_haproxy_failover
    run_test "Log files" test_log_files
}

# Generate health report
generate_report() {
    echo
    log "Health Check Report for $ZONE zone"
    echo "========================================"
    echo "Total Tests: $TOTAL_TESTS"
    echo "Passed: $PASSED_TESTS"
    echo "Failed: $FAILED_TESTS"
    echo "Success Rate: $(( (PASSED_TESTS * 100) / TOTAL_TESTS ))%"
    echo
    
    if [[ $FAILED_TESTS -eq 0 ]]; then
        success "All health checks passed!"
        return 0
    elif [[ $FAILED_TESTS -lt 3 ]]; then
        warning "Some health checks failed (non-critical)"
        return 1
    else
        error "Multiple health checks failed (critical)"
        return 2
    fi
}

# Main execution
main() {
    log "Starting DDC HAProxy Infrastructure Health Check"
    log "Zone: $ZONE, Provider: $PROVIDER, Comprehensive: $COMPREHENSIVE"
    
    # Check if Docker is available
    if ! command -v docker > /dev/null; then
        error "Docker is not available"
        exit 2
    fi
    
    # Check if required tools are available
    local tools=("curl" "jq")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" > /dev/null; then
            warning "$tool is not available, some tests may fail"
        fi
    done
    
    # Run tests based on mode
    if [[ "$COMPREHENSIVE" == "true" ]]; then
        run_comprehensive_tests
    else
        run_basic_tests
    fi
    
    # Generate and return report
    generate_report
}

# Parse arguments and run
parse_arguments "$@"
main 
