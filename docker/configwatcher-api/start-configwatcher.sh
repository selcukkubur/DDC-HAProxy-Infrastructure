#!/bin/bash

#=============================================================================
# DDC HAProxy Infrastructure - ConfigWatcher API Startup Script
# Starts the ConfigWatcher API service with proper configuration
#=============================================================================

set -euo pipefail

# Environment variables with defaults
ZONE="${ZONE:-eu}"
API_PORT="${API_PORT:-8080}"
WORKERS="${WORKERS:-4}"
LOG_LEVEL="${LOG_LEVEL:-info}"
HAPROXY_CONFIG_PATH="${HAPROXY_CONFIG_PATH:-/etc/haproxy/haproxy.cfg}"
HAPROXY_SOCKET="${HAPROXY_SOCKET:-/var/run/haproxy.sock}"

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
    mkdir -p /app/logs
    mkdir -p /app/data
    mkdir -p /app/config
    mkdir -p /tmp/configwatcher
}

# Wait for dependencies
wait_for_dependencies() {
    log "Waiting for dependencies..."
    
    # Wait for Redis
    local redis_host="${REDIS_HOST:-redis}"
    local redis_port="${REDIS_PORT:-6379}"
    
    log "Waiting for Redis at $redis_host:$redis_port..."
    while ! nc -z "$redis_host" "$redis_port"; do
        sleep 1
    done
    success "Redis is ready"
    
    # Wait for blockchain (optional)
    local blockchain_host="${BLOCKCHAIN_HOST:-blockchain}"
    local blockchain_port="${BLOCKCHAIN_PORT:-8545}"
    
    log "Checking blockchain at $blockchain_host:$blockchain_port..."
    if nc -z "$blockchain_host" "$blockchain_port"; then
        success "Blockchain is ready"
    else
        warning "Blockchain is not available (optional service)"
    fi
}

# Initialize configuration
init_configuration() {
    log "Initializing configuration..."
    
    # Create default configuration if not exists
    if [[ ! -f /app/config/config.yaml ]]; then
        cat > /app/config/config.yaml << EOF
# ConfigWatcher Configuration
zone: "$ZONE"
api:
  port: $API_PORT
  workers: $WORKERS
  log_level: "$LOG_LEVEL"
  
haproxy:
  config_path: "$HAPROXY_CONFIG_PATH"
  socket_path: "$HAPROXY_SOCKET"
  reload_script: "/app/scripts/reload-haproxy.sh"
  
redis:
  url: "${REDIS_URL:-redis://redis:6379/0}"
  
blockchain:
  rpc_url: "${BLOCKCHAIN_RPC:-http://blockchain:8545}"
  
security:
  jwt_secret: "${JWT_SECRET:-your_jwt_secret_here}"
  api_key: "${API_KEY:-}"
  
monitoring:
  enabled: true
  interval: 30
  health_check_timeout: 10
EOF
        success "Created default configuration"
    fi
}

# Setup logging
setup_logging() {
    log "Setting up logging..."
    
    # Create log configuration
    cat > /app/config/logging.conf << EOF
[loggers]
keys=root,configwatcher

[handlers]
keys=consoleHandler,fileHandler

[formatters]
keys=simpleFormatter

[logger_root]
level=INFO
handlers=consoleHandler

[logger_configwatcher]
level=$LOG_LEVEL
handlers=consoleHandler,fileHandler
qualname=configwatcher
propagate=0

[handler_consoleHandler]
class=StreamHandler
level=INFO
formatter=simpleFormatter
args=(sys.stdout,)

[handler_fileHandler]
class=FileHandler
level=DEBUG
formatter=simpleFormatter
args=('/app/logs/configwatcher.log',)

[formatter_simpleFormatter]
format=%(asctime)s - %(name)s - %(levelname)s - %(message)s
EOF
    
    success "Logging configuration created"
}

# Health check function
health_check() {
    local retries=0
    local max_retries=30
    
    log "Waiting for API to be ready..."
    
    while [[ $retries -lt $max_retries ]]; do
        if curl -f -s http://localhost:$API_PORT/api/v1/health > /dev/null 2>&1; then
            success "API health check passed"
            return 0
        fi
        
        ((retries++))
        sleep 2
    done
    
    error "API health check failed after $max_retries attempts"
    return 1
}

# Start background monitoring
start_monitoring() {
    log "Starting background monitoring..."
    
    # Start blockchain monitoring in background
    python3 -c "
import sys
sys.path.append('/app/src')
from blockchain_monitor import start_monitoring
start_monitoring()
" &
    
    # Start configuration backup service
    python3 -c "
import sys
sys.path.append('/app/src')
from backup_service import start_backup_service
start_backup_service()
" &
    
    success "Background services started"
}

# Signal handlers
cleanup() {
    log "Shutting down ConfigWatcher API..."
    
    # Kill background processes
    jobs -p | xargs -r kill
    
    success "ConfigWatcher API stopped"
    exit 0
}

# Setup signal handlers
trap cleanup SIGTERM SIGINT

# Main execution
main() {
    log "Starting DDC ConfigWatcher API for zone: $ZONE"
    
    # Setup
    create_directories
    wait_for_dependencies
    init_configuration
    setup_logging
    
    # Start background services
    start_monitoring
    
    # Start the main API server
    log "Starting ConfigWatcher API server..."
    cd /app
    
    # Use gunicorn for production
    exec gunicorn \
        --bind 0.0.0.0:$API_PORT \
        --workers $WORKERS \
        --worker-class sync \
        --timeout 120 \
        --keep-alive 2 \
        --max-requests 1000 \
        --max-requests-jitter 100 \
        --preload \
        --log-level $LOG_LEVEL \
        --access-logfile /app/logs/access.log \
        --error-logfile /app/logs/error.log \
        --capture-output \
        --enable-stdio-inheritance \
        src.app:app
}

# Run main function
main "$@" 
