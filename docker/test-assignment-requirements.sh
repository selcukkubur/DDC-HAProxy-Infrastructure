#!/bin/bash

#=============================================================================
# DDC HAProxy Infrastructure - Assignment Requirements Testing Script
# Tests all required features: HAProxy clusters, Keepalived VIP, DNS, SSL
#=============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test configuration
TEST_TIMEOUT=10
RETRY_COUNT=3
VERBOSE=${VERBOSE:-false}

# Service endpoints
EU_HAPROXY_1="http://localhost:80"
EU_HAPROXY_2="http://localhost:8085"
US_HAPROXY_1="http://localhost:8086"
US_HAPROXY_2="http://localhost:8087"

EU_STATS="http://localhost:8404/stats"
US_STATS="http://localhost:8406/stats"

EU_CONFIGWATCHER="http://localhost:9080"
US_CONFIGWATCHER="http://localhost:9081"

DNS_SERVER="127.0.0.1:1053"
PROMETHEUS="http://localhost:9090"
GRAFANA="http://localhost:3000"

# Logging functions
log() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

error() {
    echo -e "${RED}[✗]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

# Test helper functions
test_http_endpoint() {
    local url="$1"
    local description="$2"
    local expected_status="${3:-200}"
    
    if curl -s --max-time $TEST_TIMEOUT -o /dev/null -w "%{http_code}" "$url" | grep -q "$expected_status"; then
        success "$description is responding (HTTP $expected_status)"
        return 0
    else
        error "$description failed to respond"
        return 1
    fi
}

test_dns_resolution() {
    local domain="$1"
    local expected_ip="$2"
    local description="$3"
    
    if nslookup "$domain" "$DNS_SERVER" | grep -q "$expected_ip"; then
        success "$description resolves correctly to $expected_ip"
        return 0
    else
        error "$description DNS resolution failed"
        return 1
    fi
}

wait_for_service() {
    local url="$1"
    local service_name="$2"
    local max_attempts=30
    local attempt=1
    
    log "Waiting for $service_name to be ready..."
    
    while [ $attempt -le $max_attempts ]; do
        if curl -s --max-time 5 "$url" > /dev/null 2>&1; then
            success "$service_name is ready"
            return 0
        fi
        
        echo -n "."
        sleep 2
        ((attempt++))
    done
    
    error "$service_name failed to start within $((max_attempts * 2)) seconds"
    return 1
}

#=============================================================================
# Assignment Requirements Testing
#=============================================================================

# 1. HAProxy Cluster Deployment for both EU and US zones
test_haproxy_clusters() {
    log "Testing HAProxy cluster deployment..."
    local failures=0
    
    # Test EU zone HAProxy instances
    test_http_endpoint "$EU_HAPROXY_1/health" "EU HAProxy Master" || ((failures++))
    test_http_endpoint "$EU_HAPROXY_2/health" "EU HAProxy Backup" || ((failures++))
    
    # Test US zone HAProxy instances  
    test_http_endpoint "$US_HAPROXY_1/health" "US HAProxy Master" || ((failures++))
    test_http_endpoint "$US_HAPROXY_2/health" "US HAProxy Backup" || ((failures++))
    
    # Test HAProxy stats
    test_http_endpoint "$EU_STATS" "EU HAProxy Stats" || ((failures++))
    test_http_endpoint "$US_STATS" "US HAProxy Stats" || ((failures++))
    
    if [ $failures -eq 0 ]; then
        success "HAProxy cluster deployment test PASSED"
        return 0
    else
        error "HAProxy cluster deployment test FAILED ($failures failures)"
        return 1
    fi
}

# 2. Keepalived VIP Management (simulated in Docker)
test_keepalived_vip() {
    log "Testing Keepalived VIP management simulation..."
    local failures=0
    
    # Check if HAProxy containers have the required environment variables
    if docker exec eu-haproxy-1 env | grep -q "VIP_ADDRESS=10.1.0.100"; then
        success "EU VIP configuration present"
    else
        error "EU VIP configuration missing"
        ((failures++))
    fi
    
    if docker exec us-haproxy-1 env | grep -q "VIP_ADDRESS=10.2.0.100"; then
        success "US VIP configuration present"
    else
        error "US VIP configuration missing"
        ((failures++))
    fi
    
    # Check VRRP priority configuration
    if docker exec eu-haproxy-1 env | grep -q "KEEPALIVED_PRIORITY=110"; then
        success "EU master priority configured correctly"
    else
        error "EU master priority configuration missing"
        ((failures++))
    fi
    
    if docker exec us-haproxy-1 env | grep -q "KEEPALIVED_PRIORITY=100"; then
        success "US master priority configured correctly"
    else
        error "US master priority configuration missing"
        ((failures++))
    fi
    
    if [ $failures -eq 0 ]; then
        success "Keepalived VIP management test PASSED"
        return 0
    else
        error "Keepalived VIP management test FAILED ($failures failures)"
        return 1
    fi
}

# 3. Basic DNS setup for geo-routing
test_dns_geo_routing() {
    log "Testing DNS geo-routing setup..."
    local failures=0
    
    # Test DNS server availability
    if nc -z -w5 localhost 1053; then
        success "DNS server is running"
    else
        error "DNS server is not accessible"
        ((failures++))
        return 1
    fi
    
    # Test geo-routing DNS resolution
    test_dns_resolution "ddc.local" "10.1.0.100" "Main domain (defaults to EU)" || ((failures++))
    test_dns_resolution "eu.ddc.local" "10.1.0.100" "EU zone" || ((failures++))
    test_dns_resolution "us.ddc.local" "10.2.0.100" "US zone" || ((failures++))
    
    # Test API endpoints
    test_dns_resolution "eu-api.ddc.local" "10.1.0.100" "EU API" || ((failures++))
    test_dns_resolution "us-api.ddc.local" "10.2.0.100" "US API" || ((failures++))
    
    # Test VIP resolution
    test_dns_resolution "eu-vip.ddc.local" "10.1.0.100" "EU VIP" || ((failures++))
    test_dns_resolution "us-vip.ddc.local" "10.2.0.100" "US VIP" || ((failures++))
    
    if [ $failures -eq 0 ]; then
        success "DNS geo-routing test PASSED"
        return 0
    else
        error "DNS geo-routing test FAILED ($failures failures)"
        return 1
    fi
}

# 4. Simple certificate management
test_certificate_management() {
    log "Testing SSL certificate management..."
    local failures=0
    
    # Check if SSL certificate manager is running
    if docker ps | grep -q ssl-cert-manager; then
        success "SSL certificate manager is running"
    else
        error "SSL certificate manager is not running"
        ((failures++))
    fi
    
    # Check if certificates are generated
    if docker exec ssl-cert-manager ls /certs/haproxy.pem > /dev/null 2>&1; then
        success "HAProxy SSL certificate generated"
    else
        error "HAProxy SSL certificate missing"
        ((failures++))
    fi
    
    if docker exec ssl-cert-manager ls /certs/eu-combined.pem > /dev/null 2>&1; then
        success "EU zone SSL certificate generated"
    else
        error "EU zone SSL certificate missing"
        ((failures++))
    fi
    
    if docker exec ssl-cert-manager ls /certs/us-combined.pem > /dev/null 2>&1; then
        success "US zone SSL certificate generated"
    else
        error "US zone SSL certificate missing"
        ((failures++))
    fi
    
    # Test certificate validity
    if docker exec ssl-cert-manager openssl x509 -in /certs/haproxy.pem -noout -checkend 86400 > /dev/null 2>&1; then
        success "SSL certificates are valid"
    else
        error "SSL certificates are invalid or expired"
        ((failures++))
    fi
    
    if [ $failures -eq 0 ]; then
        success "Certificate management test PASSED"
        return 0
    else
        error "Certificate management test FAILED ($failures failures)"
        return 1
    fi
}

# 5. ConfigWatcher Integration
test_configwatcher_integration() {
    log "Testing ConfigWatcher integration..."
    local failures=0
    
    # Test ConfigWatcher API availability
    test_http_endpoint "$EU_CONFIGWATCHER/api/v1/health" "EU ConfigWatcher API" || ((failures++))
    test_http_endpoint "$US_CONFIGWATCHER/api/v1/health" "US ConfigWatcher API" || ((failures++))
    
    # Test authentication endpoint
    if curl -s -X POST "$EU_CONFIGWATCHER/api/v1/auth/token" \
        -H "Content-Type: application/json" \
        -d '{"username": "admin", "password": "admin"}' | grep -q "access_token"; then
        success "EU ConfigWatcher authentication working"
    else
        error "EU ConfigWatcher authentication failed"
        ((failures++))
    fi
    
    if curl -s -X POST "$US_CONFIGWATCHER/api/v1/auth/token" \
        -H "Content-Type: application/json" \
        -d '{"username": "admin", "password": "admin"}' | grep -q "access_token"; then
        success "US ConfigWatcher authentication working"
    else
        error "US ConfigWatcher authentication failed"
        ((failures++))
    fi
    
    if [ $failures -eq 0 ]; then
        success "ConfigWatcher integration test PASSED"
        return 0
    else
        error "ConfigWatcher integration test FAILED ($failures failures)"
        return 1
    fi
}

# 6. Multi-Zone Architecture
test_multi_zone_architecture() {
    log "Testing multi-zone architecture..."
    local failures=0
    
    # Test zone isolation
    if docker network ls | grep -q "docker_eu_zone"; then
        success "EU zone network exists"
    else
        error "EU zone network missing"
        ((failures++))
    fi
    
    if docker network ls | grep -q "docker_us_zone"; then
        success "US zone network exists"
    else
        error "US zone network missing"
        ((failures++))
    fi
    
    # Test cross-zone connectivity via management network
    if docker exec eu-haproxy-1 ping -c 1 us-haproxy-1 > /dev/null 2>&1; then
        success "Cross-zone connectivity working"
    else
        error "Cross-zone connectivity failed"
        ((failures++))
    fi
    
    # Test zone-specific backend access
    if curl -s --max-time $TEST_TIMEOUT "$EU_HAPROXY_1" | grep -q "eu"; then
        success "EU zone serving EU backends"
    else
        error "EU zone backend routing failed"
        ((failures++))
    fi
    
    if curl -s --max-time $TEST_TIMEOUT "$US_HAPROXY_1" | grep -q "us"; then
        success "US zone serving US backends"
    else
        error "US zone backend routing failed"
        ((failures++))
    fi
    
    if [ $failures -eq 0 ]; then
        success "Multi-zone architecture test PASSED"
        return 0
    else
        error "Multi-zone architecture test FAILED ($failures failures)"
        return 1
    fi
}

# 7. Monitoring and Health Checks
test_monitoring() {
    log "Testing monitoring setup..."
    local failures=0
    
    # Test Prometheus
    test_http_endpoint "$PROMETHEUS" "Prometheus" || ((failures++))
    
    # Test Grafana
    test_http_endpoint "$GRAFANA" "Grafana" || ((failures++))
    
    # Test health monitoring
    if docker ps | grep -q health-monitor; then
        success "Health monitor is running"
    else
        error "Health monitor is not running"
        ((failures++))
    fi
    
    if [ $failures -eq 0 ]; then
        success "Monitoring test PASSED"
        return 0
    else
        error "Monitoring test FAILED ($failures failures)"
        return 1
    fi
}

# 8. Blockchain Integration
test_blockchain_integration() {
    log "Testing blockchain integration..."
    local failures=0
    
    # Test blockchain mock service
    if curl -s --max-time $TEST_TIMEOUT "http://localhost:8545" \
        -X POST -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | grep -q "result"; then
        success "Blockchain RPC is responding"
    else
        error "Blockchain RPC failed"
        ((failures++))
    fi
    
    # Test ConfigWatcher blockchain integration
    local token
    token=$(curl -s -X POST "$EU_CONFIGWATCHER/api/v1/auth/token" \
        -H "Content-Type: application/json" \
        -d '{"username": "admin", "password": "admin"}' | jq -r '.access_token' 2>/dev/null || echo "")
    
    if [ -n "$token" ] && [ "$token" != "null" ]; then
        if curl -s -H "Authorization: Bearer $token" "$EU_CONFIGWATCHER/api/v1/blockchain/nodes" | grep -q "nodes"; then
            success "ConfigWatcher blockchain integration working"
        else
            error "ConfigWatcher blockchain integration failed"
            ((failures++))
        fi
    else
        error "Could not get authentication token for blockchain test"
        ((failures++))
    fi
    
    if [ $failures -eq 0 ]; then
        success "Blockchain integration test PASSED"
        return 0
    else
        error "Blockchain integration test FAILED ($failures failures)"
        return 1
    fi
}

#=============================================================================
# Main Test Execution
#=============================================================================

run_all_tests() {
    log "Starting DDC HAProxy Infrastructure Assignment Requirements Testing"
    log "=================================================================="
    
    local total_tests=8
    local passed_tests=0
    
    # Wait for critical services to be ready
    log "Waiting for services to be ready..."
    wait_for_service "$EU_HAPROXY_1/health" "EU HAProxy" || true
    wait_for_service "$US_HAPROXY_1/health" "US HAProxy" || true
    wait_for_service "$EU_CONFIGWATCHER/api/v1/health" "EU ConfigWatcher" || true
    sleep 10  # Additional time for all services to stabilize
    
    # Run all tests
    echo ""
    log "Running assignment requirement tests..."
    echo ""
    
    # Test 1: HAProxy Cluster Deployment
    if test_haproxy_clusters; then
        ((passed_tests++))
    fi
    echo ""
    
    # Test 2: Keepalived VIP Management
    if test_keepalived_vip; then
        ((passed_tests++))
    fi
    echo ""
    
    # Test 3: DNS Geo-routing
    if test_dns_geo_routing; then
        ((passed_tests++))
    fi
    echo ""
    
    # Test 4: Certificate Management
    if test_certificate_management; then
        ((passed_tests++))
    fi
    echo ""
    
    # Test 5: ConfigWatcher Integration
    if test_configwatcher_integration; then
        ((passed_tests++))
    fi
    echo ""
    
    # Test 6: Multi-Zone Architecture
    if test_multi_zone_architecture; then
        ((passed_tests++))
    fi
    echo ""
    
    # Test 7: Monitoring
    if test_monitoring; then
        ((passed_tests++))
    fi
    echo ""
    
    # Test 8: Blockchain Integration
    if test_blockchain_integration; then
        ((passed_tests++))
    fi
    echo ""
    
    # Final results
    log "=================================================================="
    log "Assignment Requirements Testing Complete"
    log "=================================================================="
    
    if [ $passed_tests -eq $total_tests ]; then
        success "ALL TESTS PASSED ($passed_tests/$total_tests)"
        echo ""
        success "🎉 DDC HAProxy Infrastructure meets ALL assignment requirements!"
        echo ""
        log "✅ HAProxy cluster deployment for both EU and US zones"
        log "✅ Keepalived configuration for VIP management in each zone"
        log "✅ Basic DNS setup for geo-routing"
        log "✅ Simple certificate management approach"
        log "✅ ConfigWatcher integration with blockchain"
        log "✅ Multi-zone architecture with cross-zone failover"
        log "✅ Monitoring and health checks"
        log "✅ Blockchain integration for node discovery"
        echo ""
        return 0
    else
        error "SOME TESTS FAILED ($passed_tests/$total_tests passed)"
        echo ""
        warning "Please check the failed tests above and ensure all services are running correctly."
        echo ""
        return 1
    fi
}

# Script execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Check if Docker Compose is running
    if ! docker-compose ps | grep -q "Up"; then
        error "Docker Compose services are not running!"
        log "Please start the services with: docker-compose up -d"
        exit 1
    fi
    
    # Install required tools if missing
    if ! command -v jq &> /dev/null; then
        log "Installing jq for JSON parsing..."
        if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y jq
        elif command -v yum &> /dev/null; then
            sudo yum install -y jq
        elif command -v brew &> /dev/null; then
            brew install jq
        else
            warning "Please install 'jq' manually for full test functionality"
        fi
    fi
    
    # Run tests
    run_all_tests
fi 
