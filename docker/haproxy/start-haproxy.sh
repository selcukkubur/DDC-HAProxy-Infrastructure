#!/bin/bash

#=============================================================================
# DDC HAProxy Infrastructure - Docker Container Startup Script
# Starts HAProxy and Keepalived with proper configuration
#=============================================================================

set -eo pipefail

# Environment variables with defaults
ZONE="${ZONE:-eu}"
ROLE="${ROLE:-master}"
VIP_ADDRESS="${VIP_ADDRESS:-10.1.0.100}"
KEEPALIVED_PRIORITY="${KEEPALIVED_PRIORITY:-110}"
PEER_ADDRESS="${PEER_ADDRESS:-10.1.0.11}"

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
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

# Create necessary directories
create_directories() {
    log "Creating necessary directories..."
    mkdir -p /var/run/haproxy
    mkdir -p /var/log/haproxy
    mkdir -p /var/log/keepalived
    chown -R haproxy:haproxy /var/run/haproxy
}

# Generate Keepalived configuration
generate_keepalived_config() {
    log "Generating Keepalived configuration for $ZONE zone ($ROLE)..."
    
    # Calculate virtual router ID
    local virtual_router_id
    if [[ "$ZONE" == "eu" ]]; then
        virtual_router_id=51
    else
        virtual_router_id=52
    fi
    
    # Generate configuration file
    cat > /etc/keepalived/keepalived.conf << EOF
! Configuration File for keepalived

global_defs {
    router_id ${ZONE}_haproxy_${ROLE}
    script_user root
    enable_script_security
}

vrrp_script chk_haproxy {
    script "/bin/curl -f http://localhost:8404/health || exit 1"
    interval 2
    weight -2
    fall 3
    rise 2
}

vrrp_instance VI_1 {
    state ${ROLE^^}
    interface eth0
    virtual_router_id ${virtual_router_id}
    priority ${KEEPALIVED_PRIORITY}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass ${ZONE}_vrrp_pass
    }
    virtual_ipaddress {
        ${VIP_ADDRESS}/24
    }
    track_script {
        chk_haproxy
    }
    notify_master "/bin/echo 'Became master' > /var/log/keepalived/state.log"
    notify_backup "/bin/echo 'Became backup' > /var/log/keepalived/state.log"
    notify_fault "/bin/echo 'Fault detected' > /var/log/keepalived/state.log"
}
EOF
    
    success "Keepalived configuration generated"
}

# Configure HAProxy
configure_haproxy() {
    log "Configuring HAProxy for $ZONE zone..."
    
    # Ensure HAProxy config exists
    if [[ ! -f /etc/haproxy/haproxy.cfg ]]; then
        error "HAProxy configuration not found!"
        exit 1
    fi
    
    # Test HAProxy configuration
    if ! haproxy -c -f /etc/haproxy/haproxy.cfg; then
        error "HAProxy configuration is invalid!"
        exit 1
    fi
    
    success "HAProxy configuration validated"
}

# Start services
start_keepalived() {
    log "Starting Keepalived..."
    
    # Enable IP forwarding
    echo 1 > /proc/sys/net/ipv4/ip_forward
    echo 1 > /proc/sys/net/ipv4/ip_nonlocal_bind
    
    # Start Keepalived in background
    keepalived -f /etc/keepalived/keepalived.conf -l -D -P &
    KEEPALIVED_PID=$!
    
    success "Keepalived started with PID $KEEPALIVED_PID"
}

start_haproxy() {
    log "Starting HAProxy..."
    
    # Start HAProxy
    haproxy -f /etc/haproxy/haproxy.cfg -D -p /var/run/haproxy.pid
    HAPROXY_PID=$(cat /var/run/haproxy.pid)
    
    success "HAProxy started with PID $HAPROXY_PID"
}

# Health check function
health_check() {
    local retries=0
    local max_retries=30
    
    log "Waiting for services to be ready..."
    
    while [[ $retries -lt $max_retries ]]; do
        if curl -f http://localhost:8404/health > /dev/null 2>&1; then
            success "HAProxy health check passed"
            return 0
        fi
        
        ((retries++))
        sleep 2
    done
    
    error "Health check failed after $max_retries attempts"
    return 1
}

# Signal handlers
cleanup() {
    log "Shutting down services..."
    
    if [[ -n "${HAPROXY_PID:-}" ]]; then
        kill -TERM "$HAPROXY_PID" 2>/dev/null || true
    fi
    
    if [[ -n "${KEEPALIVED_PID:-}" ]]; then
        kill -TERM "$KEEPALIVED_PID" 2>/dev/null || true
    fi
    
    success "Services stopped"
    exit 0
}

# Reload HAProxy configuration
reload_haproxy() {
    log "Reloading HAProxy configuration..."
    
    if [[ -f /var/run/haproxy.pid ]]; then
        local old_pid
        old_pid=$(cat /var/run/haproxy.pid)
        
        # Test new configuration
        if haproxy -c -f /etc/haproxy/haproxy.cfg; then
            # Start new process
            haproxy -f /etc/haproxy/haproxy.cfg -D -p /var/run/haproxy.pid -sf "$old_pid"
            success "HAProxy reloaded successfully"
        else
            error "HAProxy configuration test failed"
            return 1
        fi
    else
        error "HAProxy PID file not found"
        return 1
    fi
}

# Monitor services
monitor_services() {
    log "Starting service monitoring..."
    
    while true; do
        # Check HAProxy
        if [[ -f /var/run/haproxy.pid ]]; then
            local haproxy_pid
            haproxy_pid=$(cat /var/run/haproxy.pid)
            if ! kill -0 "$haproxy_pid" 2>/dev/null; then
                error "HAProxy process died, restarting..."
                start_haproxy
            fi
        fi
        
        # Check Keepalived
        if [[ -n "${KEEPALIVED_PID:-}" ]]; then
            if ! kill -0 "$KEEPALIVED_PID" 2>/dev/null; then
                error "Keepalived process died, restarting..."
                start_keepalived
            fi
        fi
        
        sleep 10
    done
}

# Setup signal handlers
trap cleanup SIGTERM SIGINT

# Main execution
main() {
    log "Starting DDC HAProxy Infrastructure ($ZONE zone, $ROLE role)"
    log "VIP: $VIP_ADDRESS, Priority: $KEEPALIVED_PRIORITY"
    
    # Setup
    create_directories
    generate_keepalived_config
    configure_haproxy
    
    # Start services
    start_keepalived
    start_haproxy
    
    # Health check
    if ! health_check; then
        error "Initial health check failed"
        exit 1
    fi
    
    success "All services started successfully"
    
    # Monitor services
    monitor_services
}

# Handle reload signal
trap reload_haproxy SIGHUP

# Run main function
main "$@" 
