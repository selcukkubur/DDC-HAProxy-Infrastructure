#!/bin/bash

#=============================================================================
# DDC HAProxy Infrastructure - Zero-Downtime Reload Script
# Used by ConfigWatcher to reload HAProxy without service interruption
#=============================================================================

set -euo pipefail

# Configuration
HAPROXY_CONFIG="${HAPROXY_CONFIG:-/etc/haproxy/haproxy.cfg}"
HAPROXY_PID_FILE="${HAPROXY_PID_FILE:-/var/run/haproxy.pid}"
HAPROXY_SOCKET="${HAPROXY_SOCKET:-/var/run/haproxy.sock}"
BACKUP_DIR="${BACKUP_DIR:-/etc/haproxy/backups}"
LOG_FILE="${LOG_FILE:-/var/log/haproxy/reload.log}"
VALIDATION_TIMEOUT="${VALIDATION_TIMEOUT:-30}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log() {
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo -e "${BLUE}${message}${NC}" >&2
    echo "$message" >> "$LOG_FILE"
}

success() {
    local message="[SUCCESS] $1"
    echo -e "${GREEN}${message}${NC}" >&2
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE"
}

error() {
    local message="[ERROR] $1"
    echo -e "${RED}${message}${NC}" >&2
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE"
}

warning() {
    local message="[WARNING] $1"
    echo -e "${YELLOW}${message}${NC}" >&2
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE"
}

# Usage information
usage() {
    cat << EOF
HAProxy Zero-Downtime Reload Script

USAGE:
    $0 [OPTIONS]

OPTIONS:
    -c, --config FILE        HAProxy configuration file (default: $HAPROXY_CONFIG)
    -p, --pid-file FILE      HAProxy PID file (default: $HAPROXY_PID_FILE)
    -s, --socket FILE        HAProxy stats socket (default: $HAPROXY_SOCKET)
    -b, --backup-dir DIR     Backup directory (default: $BACKUP_DIR)
    -t, --timeout SECONDS    Validation timeout (default: $VALIDATION_TIMEOUT)
    -v, --validate-only      Only validate configuration, don't reload
    -f, --force              Force reload even if validation warnings exist
    -h, --help               Show this help message

EXAMPLES:
    $0                                    # Standard reload
    $0 --validate-only                   # Just validate configuration
    $0 --config /tmp/new-haproxy.cfg     # Reload with specific config file
    $0 --force                           # Force reload ignoring warnings

RETURN CODES:
    0  - Success
    1  - Configuration validation failed
    2  - HAProxy not running
    3  - Reload failed
    4  - Backup failed
    5  - Invalid arguments
EOF
}

# Parse command line arguments
parse_arguments() {
    local validate_only=false
    local force=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                HAPROXY_CONFIG="$2"
                shift 2
                ;;
            -p|--pid-file)
                HAPROXY_PID_FILE="$2"
                shift 2
                ;;
            -s|--socket)
                HAPROXY_SOCKET="$2"
                shift 2
                ;;
            -b|--backup-dir)
                BACKUP_DIR="$2"
                shift 2
                ;;
            -t|--timeout)
                VALIDATION_TIMEOUT="$2"
                shift 2
                ;;
            -v|--validate-only)
                validate_only=true
                shift
                ;;
            -f|--force)
                force=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                usage
                exit 5
                ;;
        esac
    done
    
    # Export variables for use in other functions
    export VALIDATE_ONLY="$validate_only"
    export FORCE="$force"
}

# Create necessary directories
setup_directories() {
    log "Setting up directories..."
    
    # Create backup directory
    if [[ ! -d "$BACKUP_DIR" ]]; then
        mkdir -p "$BACKUP_DIR"
        log "Created backup directory: $BACKUP_DIR"
    fi
    
    # Create log directory
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir"
        log "Created log directory: $log_dir"
    fi
    
    # Ensure HAProxy socket directory exists
    local socket_dir
    socket_dir=$(dirname "$HAPROXY_SOCKET")
    if [[ ! -d "$socket_dir" ]]; then
        mkdir -p "$socket_dir"
        chown haproxy:haproxy "$socket_dir" 2>/dev/null || true
        log "Created socket directory: $socket_dir"
    fi
}

# Check if HAProxy is running
check_haproxy_running() {
    log "Checking if HAProxy is running..."
    
    if [[ ! -f "$HAPROXY_PID_FILE" ]]; then
        error "HAProxy PID file not found: $HAPROXY_PID_FILE"
        return 2
    fi
    
    local pid
    pid=$(cat "$HAPROXY_PID_FILE")
    
    if ! kill -0 "$pid" 2>/dev/null; then
        error "HAProxy process not running (PID: $pid)"
        return 2
    fi
    
    success "HAProxy is running (PID: $pid)"
    return 0
}

# Validate HAProxy configuration
validate_configuration() {
    log "Validating HAProxy configuration: $HAPROXY_CONFIG"
    
    if [[ ! -f "$HAPROXY_CONFIG" ]]; then
        error "Configuration file not found: $HAPROXY_CONFIG"
        return 1
    fi
    
    # Test configuration syntax
    local validation_output
    if validation_output=$(haproxy -c -f "$HAPROXY_CONFIG" 2>&1); then
        success "Configuration validation passed"
        
        # Check for warnings
        if echo "$validation_output" | grep -i warning > /dev/null; then
            warning "Configuration has warnings:"
            echo "$validation_output" | grep -i warning
            
            if [[ "$FORCE" != "true" ]]; then
                error "Configuration has warnings. Use --force to ignore."
                return 1
            fi
        fi
        
        return 0
    else
        error "Configuration validation failed:"
        echo "$validation_output"
        return 1
    fi
}

# Create configuration backup
create_backup() {
    log "Creating configuration backup..."
    
    if [[ ! -f "$HAPROXY_CONFIG" ]]; then
        warning "Current configuration file not found, skipping backup"
        return 0
    fi
    
    local backup_file
    backup_file="$BACKUP_DIR/haproxy.cfg.backup.$(date +%Y%m%d_%H%M%S)"
    
    if cp "$HAPROXY_CONFIG" "$backup_file"; then
        success "Configuration backed up to: $backup_file"
        
        # Keep only last 10 backups
        local backup_count
        backup_count=$(find "$BACKUP_DIR" -name "haproxy.cfg.backup.*" | wc -l)
        if [[ $backup_count -gt 10 ]]; then
            find "$BACKUP_DIR" -name "haproxy.cfg.backup.*" -type f -printf '%T@ %p\n' | \
                sort -n | head -n $((backup_count - 10)) | cut -d' ' -f2- | \
                xargs rm -f
            log "Cleaned up old backups"
        fi
        
        return 0
    else
        error "Failed to create backup"
        return 4
    fi
}

# Get HAProxy statistics
get_haproxy_stats() {
    log "Retrieving HAProxy statistics..."
    
    if [[ -S "$HAPROXY_SOCKET" ]]; then
        echo "show stat" | socat stdio "$HAPROXY_SOCKET" 2>/dev/null || true
    else
        warning "HAProxy socket not available: $HAPROXY_SOCKET"
    fi
}

# Reload HAProxy with zero downtime
reload_haproxy() {
    log "Starting zero-downtime HAProxy reload..."
    
    local old_pid
    old_pid=$(cat "$HAPROXY_PID_FILE")
    
    log "Current HAProxy PID: $old_pid"
    
    # Get current statistics for comparison
    local stats_before
    stats_before=$(get_haproxy_stats)
    
    # Perform the reload using the -sf option (soft reload)
    log "Executing HAProxy reload..."
    if haproxy -f "$HAPROXY_CONFIG" -D -p "$HAPROXY_PID_FILE" -sf "$old_pid"; then
        success "HAProxy reload command executed successfully"
        
        # Wait for new process to be ready
        local retries=0
        local max_retries=$((VALIDATION_TIMEOUT / 2))
        
        log "Waiting for new HAProxy process to be ready..."
        while [[ $retries -lt $max_retries ]]; do
            if [[ -f "$HAPROXY_PID_FILE" ]]; then
                local new_pid
                new_pid=$(cat "$HAPROXY_PID_FILE")
                
                if [[ "$new_pid" != "$old_pid" ]] && kill -0 "$new_pid" 2>/dev/null; then
                    success "New HAProxy process is running (PID: $new_pid)"
                    
                    # Test health endpoint
                    if curl -f -s http://localhost:8404/health > /dev/null 2>&1; then
                        success "Health check passed for new process"
                        break
                    fi
                fi
            fi
            
            ((retries++))
            sleep 2
        done
        
        if [[ $retries -ge $max_retries ]]; then
            error "New HAProxy process failed to become ready within timeout"
            return 3
        fi
        
        # Compare statistics
        local stats_after
        stats_after=$(get_haproxy_stats)
        
        log "Reload completed successfully"
        
        # Log reload event
        echo "$(date +'%Y-%m-%d %H:%M:%S') - HAProxy reloaded successfully (old PID: $old_pid, new PID: $(cat "$HAPROXY_PID_FILE"))" >> "$LOG_FILE"
        
        return 0
    else
        error "HAProxy reload failed"
        return 3
    fi
}

# Rollback to previous configuration
rollback_configuration() {
    log "Rolling back to previous configuration..."
    
    local latest_backup
    latest_backup=$(find "$BACKUP_DIR" -name "haproxy.cfg.backup.*" -type f -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
    
    if [[ -n "$latest_backup" && -f "$latest_backup" ]]; then
        log "Rolling back to: $latest_backup"
        
        if cp "$latest_backup" "$HAPROXY_CONFIG"; then
            success "Configuration rolled back"
            
            # Reload with previous configuration
            if reload_haproxy; then
                success "Rollback completed successfully"
                return 0
            else
                error "Rollback reload failed"
                return 3
            fi
        else
            error "Failed to restore backup configuration"
            return 4
        fi
    else
        error "No backup configuration found for rollback"
        return 4
    fi
}

# Test configuration with temporary process
test_configuration() {
    log "Testing configuration with temporary HAProxy process..."
    
    local test_config="/tmp/haproxy-test-$$.cfg"
    local test_pid="/tmp/haproxy-test-$$.pid"
    
    # Create test configuration with different ports
    sed 's/bind \*:80/bind *:18080/g; s/bind \*:443/bind *:18443/g; s/bind \*:8404/bind *:18404/g' "$HAPROXY_CONFIG" > "$test_config"
    
    # Start test instance
    if haproxy -f "$test_config" -D -p "$test_pid"; then
        local test_pid_value
        test_pid_value=$(cat "$test_pid")
        
        # Wait a moment for startup
        sleep 2
        
        # Test health endpoint
        if curl -f -s http://localhost:18404/health > /dev/null 2>&1; then
            success "Test configuration is working"
            kill -TERM "$test_pid_value" 2>/dev/null || true
            rm -f "$test_config" "$test_pid"
            return 0
        else
            error "Test configuration health check failed"
            kill -TERM "$test_pid_value" 2>/dev/null || true
            rm -f "$test_config" "$test_pid"
            return 1
        fi
    else
        error "Failed to start test HAProxy instance"
        rm -f "$test_config" "$test_pid"
        return 1
    fi
}

# Main execution function
main() {
    log "Starting HAProxy zero-downtime reload script"
    
    # Setup
    setup_directories
    
    # Validate configuration
    if ! validate_configuration; then
        error "Configuration validation failed"
        exit 1
    fi
    
    # If only validation requested, exit here
    if [[ "$VALIDATE_ONLY" == "true" ]]; then
        success "Configuration validation completed"
        exit 0
    fi
    
    # Check if HAProxy is running
    if ! check_haproxy_running; then
        error "HAProxy is not running"
        exit 2
    fi
    
    # Create backup
    if ! create_backup; then
        error "Failed to create configuration backup"
        exit 4
    fi
    
    # Test configuration with temporary instance
    if ! test_configuration; then
        error "Configuration test failed"
        exit 1
    fi
    
    # Perform reload
    if reload_haproxy; then
        success "HAProxy reloaded successfully with zero downtime"
        exit 0
    else
        error "HAProxy reload failed, attempting rollback..."
        if rollback_configuration; then
            warning "Rollback completed, but original reload failed"
            exit 3
        else
            error "Both reload and rollback failed!"
            exit 3
        fi
    fi
}

# Error handling
handle_error() {
    local exit_code=$?
    error "Script failed with exit code $exit_code"
    
    # Attempt rollback if we're in the middle of a reload
    if [[ $exit_code -eq 3 && "$VALIDATE_ONLY" != "true" ]]; then
        warning "Attempting emergency rollback..."
        rollback_configuration || true
    fi
    
    exit $exit_code
}

# Set up error handling
trap handle_error ERR

# Parse arguments and run main function
parse_arguments "$@"
main 
