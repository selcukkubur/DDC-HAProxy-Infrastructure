# ConfigWatcher API Specification

## Overview

The ConfigWatcher API provides a RESTful interface for dynamic HAProxy configuration management. It enables real-time updates to HAProxy backend configurations based on blockchain node discovery and manual operations.

## Base URL

```
Production: https://configwatcher.ddc.example.com/api/v1
EU Zone: https://eu-configwatcher.ddc.example.com/api/v1  
US Zone: https://us-configwatcher.ddc.example.com/api/v1
Local: http://localhost:8080/api/v1
```

## Authentication

All API requests require JWT authentication via the `Authorization` header:

```
Authorization: Bearer <jwt_token>
```

### Obtaining Access Token

```bash
POST /auth/login
Content-Type: application/json

{
  "username": "admin",
  "password": "admin",
  "zone": "eu"
}
```

**Response:**
```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "token_type": "Bearer",
  "expires_in": 3600,
  "zone": "eu",
  "permissions": ["read", "write", "reload"]
}
```

## Core Endpoints

### 1. Health Check

**GET** `/health`

Returns the health status of the ConfigWatcher service.

**Response:**
```json
{
  "status": "healthy",
  "version": "1.0.0",
  "zone": "eu",
  "haproxy_status": "running",
  "blockchain_connection": "connected",
  "last_config_update": "2024-01-15T10:30:00Z",
  "uptime_seconds": 86400
}
```

### 2. Configuration Management

#### Get Current Configuration

**GET** `/config`

**Response:**
```json
{
  "config_version": "v1.2.3",
  "zone": "eu",
  "last_updated": "2024-01-15T10:30:00Z",
  "haproxy_config": {
    "global": {
      "maxconn": 4096,
      "ssl_default_bind_options": "ssl-min-ver TLSv1.2",
      "ssl_default_bind_ciphers": "ECDHE+aRSA+AESGCM"
    },
    "defaults": {
      "mode": "http",
      "timeout_connect": "5000ms",
      "timeout_client": "50000ms",
      "timeout_server": "50000ms"
    },
    "frontends": [
      {
        "name": "https_frontend",
        "bind": "0.0.0.0:443",
        "ssl": true,
        "default_backend": "ddc_nodes_http"
      },
      {
        "name": "grpc_frontend", 
        "bind": "0.0.0.0:8443",
        "mode": "tcp",
        "default_backend": "ddc_nodes_grpc"
      }
    ],
    "backends": [
      {
        "name": "ddc_nodes_http",
        "balance": "roundrobin",
        "servers": [
          {
            "name": "node1",
            "address": "10.1.0.20:80",
            "check": true,
            "check_interval": "5s"
          },
          {
            "name": "node2",
            "address": "10.1.0.21:80", 
            "check": true,
            "check_interval": "5s"
          }
        ]
      },
      {
        "name": "ddc_nodes_grpc",
        "mode": "tcp",
        "balance": "roundrobin",
        "servers": [
          {
            "name": "node1_grpc",
            "address": "10.1.0.20:443",
            "check": true,
            "check_ssl_verify": "none"
          }
        ]
      }
    ]
  }
}
```

#### Update Configuration

**PUT** `/config`

**Request:**
```json
{
  "config_version": "v1.2.4",
  "change_description": "Added new backend node",
  "haproxy_config": {
    // Full HAProxy configuration object
  },
  "validate_only": false,
  "auto_reload": true
}
```

**Response:**
```json
{
  "success": true,
  "config_version": "v1.2.4",
  "validation_result": {
    "valid": true,
    "warnings": [],
    "errors": []
  },
  "reload_result": {
    "success": true,
    "reload_time": "2024-01-15T10:35:00Z",
    "downtime_ms": 0
  },
  "backup_created": "config_backup_v1.2.3_20240115_103500.cfg"
}
```

### 3. Backend Node Management

#### List Backend Nodes

**GET** `/backends/{backend_name}/servers`

**Response:**
```json
{
  "backend_name": "ddc_nodes_http",
  "servers": [
    {
      "name": "node1",
      "address": "10.1.0.20",
      "port": 80,
      "status": "UP",
      "weight": 100,
      "check_status": "L7OK",
      "last_check": "2024-01-15T10:34:55Z",
      "check_duration": "2ms",
      "total_requests": 1234567,
      "health_check_url": "/health"
    },
    {
      "name": "node2", 
      "address": "10.1.0.21",
      "port": 80,
      "status": "UP",
      "weight": 100,
      "check_status": "L7OK",
      "last_check": "2024-01-15T10:34:58Z",
      "check_duration": "3ms",
      "total_requests": 987654,
      "health_check_url": "/health"
    }
  ],
  "total_servers": 2,
  "healthy_servers": 2
}
```

#### Add Backend Node

**POST** `/backends/{backend_name}/servers`

**Request:**
```json
{
  "name": "node3",
  "address": "10.1.0.22",
  "port": 80,
  "weight": 100,
  "check": true,
  "check_interval": "5s",
  "check_rise": 2,
  "check_fall": 3,
  "health_check_url": "/health",
  "ssl": false,
  "backup": false
}
```

**Response:**
```json
{
  "success": true,
  "server_added": {
    "name": "node3",
    "address": "10.1.0.22:80",
    "backend": "ddc_nodes_http"
  },
  "config_version": "v1.2.5",
  "reload_triggered": true,
  "reload_time": "2024-01-15T10:40:00Z"
}
```

#### Update Backend Node

**PUT** `/backends/{backend_name}/servers/{server_name}`

**Request:**
```json
{
  "weight": 50,
  "check_interval": "10s",
  "backup": true
}
```

#### Remove Backend Node

**DELETE** `/backends/{backend_name}/servers/{server_name}`

**Request:**
```json
{
  "drain_first": true,
  "drain_timeout": "30s",
  "force": false
}
```

**Response:**
```json
{
  "success": true,
  "server_removed": "node3",
  "drain_completed": true,
  "drain_duration": "15s",
  "config_version": "v1.2.6",
  "reload_triggered": true
}
```

### 4. Blockchain Integration

#### Get Blockchain Status

**GET** `/blockchain/status`

**Response:**
```json
{
  "connected": true,
  "rpc_endpoint": "https://blockchain-rpc.ddc.example.com",
  "last_sync": "2024-01-15T10:34:00Z",
  "block_height": 1234567,
  "node_registry_contract": "0x1234567890abcdef",
  "monitored_events": [
    "NodeAdded",
    "NodeRemoved", 
    "NodeUpdated"
  ],
  "pending_updates": 0
}
```

#### Get Discovered Nodes

**GET** `/blockchain/nodes`

**Query Parameters:**
- `zone` (optional): Filter by zone (eu, us, asia)
- `status` (optional): Filter by status (active, inactive)
- `protocol` (optional): Filter by protocol (http, grpc)

**Response:**
```json
{
  "nodes": [
    {
      "node_id": "node_eu_001",
      "address": "10.1.0.20",
      "http_port": 80,
      "grpc_port": 443,
      "zone": "eu",
      "status": "active",
      "blockchain_registered": "2024-01-10T09:00:00Z",
      "last_heartbeat": "2024-01-15T10:33:00Z",
      "capabilities": ["storage", "compute"],
      "version": "1.2.3"
    }
  ],
  "total_nodes": 5,
  "active_nodes": 4,
  "last_discovery": "2024-01-15T10:30:00Z"
}
```

#### Sync from Blockchain

**POST** `/blockchain/sync`

**Request:**
```json
{
  "force_full_sync": false,
  "auto_apply_changes": true,
  "backup_current_config": true
}
```

**Response:**
```json
{
  "sync_completed": true,
  "sync_duration": "2.5s",
  "changes_detected": 3,
  "changes_applied": 3,
  "changes": [
    {
      "type": "node_added",
      "node_id": "node_eu_004",
      "address": "10.1.0.23:80",
      "backend": "ddc_nodes_http"
    },
    {
      "type": "node_removed",
      "node_id": "node_eu_002",
      "reason": "deregistered"
    },
    {
      "type": "node_updated",
      "node_id": "node_eu_003", 
      "changes": ["address"]
    }
  ],
  "config_version": "v1.2.7",
  "reload_triggered": true
}
```

### 5. Configuration Validation

#### Validate Configuration

**POST** `/config/validate`

**Request:**
```json
{
  "haproxy_config": {
    // HAProxy configuration to validate
  },
  "strict_mode": true,
  "check_backend_connectivity": true
}
```

**Response:**
```json
{
  "valid": false,
  "validation_time": "1.2s",
  "errors": [
    {
      "severity": "error",
      "line": 45,
      "message": "Invalid backend server address format",
      "suggestion": "Use IP:PORT format (e.g., 10.1.0.20:80)"
    }
  ],
  "warnings": [
    {
      "severity": "warning",
      "line": 23,
      "message": "Timeout value might be too low for production",
      "suggestion": "Consider increasing timeout to 30s"
    }
  ],
  "backend_connectivity": [
    {
      "backend": "ddc_nodes_http",
      "server": "10.1.0.20:80",
      "reachable": true,
      "response_time": "5ms"
    },
    {
      "backend": "ddc_nodes_http", 
      "server": "10.1.0.21:80",
      "reachable": false,
      "error": "Connection timeout"
    }
  ]
}
```

### 6. Configuration Reload

#### Reload HAProxy

**POST** `/reload`

**Request:**
```json
{
  "validate_before_reload": true,
  "backup_current_config": true,
  "rollback_on_failure": true,
  "reload_timeout": "30s"
}
```

**Response:**
```json
{
  "success": true,
  "reload_method": "seamless",
  "downtime_ms": 0,
  "reload_duration": "150ms",
  "old_pid": 12345,
  "new_pid": 12389,
  "reload_time": "2024-01-15T10:45:00Z",
  "backup_created": "config_backup_pre_reload_20240115_104500.cfg",
  "validation_passed": true
}
```

#### Get Reload History

**GET** `/reload/history`

**Query Parameters:**
- `limit`: Number of records to return (default: 50)
- `from`: Start date (ISO 8601)
- `to`: End date (ISO 8601)

**Response:**
```json
{
  "reloads": [
    {
      "id": "reload_001",
      "timestamp": "2024-01-15T10:45:00Z",
      "trigger": "api_request",
      "user": "admin",
      "success": true,
      "downtime_ms": 0,
      "config_version_before": "v1.2.6",
      "config_version_after": "v1.2.7",
      "changes_summary": "Added 1 backend node"
    }
  ],
  "total_reloads": 25,
  "successful_reloads": 24,
  "failed_reloads": 1
}
```

### 7. Monitoring and Statistics

#### Get HAProxy Statistics

**GET** `/stats`

**Response:**
```json
{
  "haproxy_version": "2.4.0",
  "uptime_seconds": 86400,
  "current_connections": 150,
  "total_requests": 1234567,
  "requests_per_second": 45.2,
  "frontends": [
    {
      "name": "https_frontend",
      "status": "OPEN",
      "current_sessions": 75,
      "max_sessions": 200,
      "total_sessions": 567890,
      "bytes_in": 123456789,
      "bytes_out": 987654321
    }
  ],
  "backends": [
    {
      "name": "ddc_nodes_http",
      "status": "UP",
      "active_servers": 2,
      "backup_servers": 0,
      "total_weight": 200,
      "current_queue": 0,
      "response_time_avg": "15ms"
    }
  ]
}
```

### 8. Configuration Backup and Rollback

#### List Configuration Backups

**GET** `/config/backups`

**Response:**
```json
{
  "backups": [
    {
      "id": "backup_001",
      "filename": "config_backup_v1.2.7_20240115_104500.cfg",
      "created": "2024-01-15T10:45:00Z",
      "size_bytes": 4096,
      "config_version": "v1.2.7",
      "created_by": "admin",
      "trigger": "pre_reload"
    }
  ],
  "total_backups": 10,
  "total_size_mb": 0.5
}
```

#### Create Manual Backup

**POST** `/config/backup`

**Request:**
```json
{
  "description": "Manual backup before maintenance",
  "include_certificates": true
}
```

#### Rollback to Previous Configuration

**POST** `/config/rollback`

**Request:**
```json
{
  "backup_id": "backup_001",
  "validate_before_apply": true,
  "create_rollback_backup": true
}
```

**Response:**
```json
{
  "success": true,
  "rollback_completed": "2024-01-15T10:50:00Z",
  "config_version_before": "v1.2.7",
  "config_version_after": "v1.2.6",
  "rollback_backup_created": "rollback_backup_20240115_105000.cfg",
  "reload_triggered": true,
  "validation_passed": true
}
```

## Error Handling

### Standard Error Response

```json
{
  "error": {
    "code": "VALIDATION_FAILED",
    "message": "Configuration validation failed",
    "details": "Invalid server address format in backend configuration",
    "timestamp": "2024-01-15T10:30:00Z",
    "request_id": "req_12345"
  }
}
```

### Error Codes

| Code | HTTP Status | Description |
|------|-------------|-------------|
| `INVALID_REQUEST` | 400 | Invalid request format or parameters |
| `UNAUTHORIZED` | 401 | Invalid or missing authentication |
| `FORBIDDEN` | 403 | Insufficient permissions |
| `NOT_FOUND` | 404 | Resource not found |
| `VALIDATION_FAILED` | 422 | Configuration validation failed |
| `RELOAD_FAILED` | 500 | HAProxy reload failed |
| `BLOCKCHAIN_ERROR` | 503 | Blockchain connection issue |
| `INTERNAL_ERROR` | 500 | Internal server error |

## Rate Limiting

API requests are rate-limited to prevent abuse:

- **Authentication**: 10 requests/minute
- **Configuration reads**: 100 requests/minute  
- **Configuration writes**: 20 requests/minute
- **Reload operations**: 5 requests/minute

Rate limit headers:
```
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 95
X-RateLimit-Reset: 1642248000
```

## Webhooks

ConfigWatcher can send webhook notifications for important events:

### Webhook Configuration

**POST** `/webhooks`

**Request:**
```json
{
  "url": "https://monitoring.example.com/webhooks/configwatcher",
  "events": ["config_updated", "reload_failed", "node_added", "node_removed"],
  "secret": "webhook_secret_key",
  "active": true
}
```

### Webhook Payload

```json
{
  "event": "config_updated",
  "timestamp": "2024-01-15T10:45:00Z",
  "zone": "eu",
  "data": {
    "config_version": "v1.2.7",
    "changes_summary": "Added backend node node3",
    "reload_success": true,
    "downtime_ms": 0
  },
  "signature": "sha256=..."
}
```

## SDK Examples

### Python Example

```python
import requests
import json

class ConfigWatcherClient:
    def __init__(self, base_url, token):
        self.base_url = base_url
        self.headers = {
            'Authorization': f'Bearer {token}',
            'Content-Type': 'application/json'
        }
    
    def add_backend_node(self, backend_name, node_config):
        url = f"{self.base_url}/backends/{backend_name}/servers"
        response = requests.post(url, headers=self.headers, json=node_config)
        return response.json()
    
    def remove_backend_node(self, backend_name, server_name, drain=True):
        url = f"{self.base_url}/backends/{backend_name}/servers/{server_name}"
        data = {"drain_first": drain, "drain_timeout": "30s"}
        response = requests.delete(url, headers=self.headers, json=data)
        return response.json()

# Usage
client = ConfigWatcherClient("https://eu-configwatcher.ddc.example.com/api/v1", "your_jwt_token")

# Add a new backend node
new_node = {
    "name": "node4",
    "address": "10.1.0.24",
    "port": 80,
    "weight": 100,
    "check": True
}

result = client.add_backend_node("ddc_nodes_http", new_node)
print(f"Node added: {result['success']}")
```

### Bash/curl Example

```bash
#!/bin/bash

BASE_URL="https://eu-configwatcher.ddc.example.com/api/v1"
TOKEN="your_jwt_token"

# Add backend node
curl -X POST "$BASE_URL/backends/ddc_nodes_http/servers" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "node5",
    "address": "10.1.0.25", 
    "port": 80,
    "weight": 100,
    "check": true
  }'

# Check health
curl -X GET "$BASE_URL/health" \
  -H "Authorization: Bearer $TOKEN"
```

## Testing the API

Use the provided test suite to validate API functionality:

```bash
# Run integration tests
./tests/integration/test_configwatcher_api.py

# Test specific endpoint
curl -X GET "http://localhost:8080/api/v1/health"
``` 
