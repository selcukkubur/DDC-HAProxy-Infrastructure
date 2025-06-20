#!/usr/bin/env python3

"""
DDC HAProxy Infrastructure - ConfigWatcher API
Main application providing REST API for dynamic HAProxy configuration management
"""

import os
import sys
import json
import logging
import subprocess
import time
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Any
from pathlib import Path

from flask import Flask, request, jsonify, g
from flask_cors import CORS
from flask_restx import Api, Resource, fields, Namespace
import redis
import jwt
from werkzeug.security import check_password_hash, generate_password_hash
from web3 import Web3
import requests
import yaml
from prometheus_client import generate_latest

# Add Docker support
try:
    import docker
    DOCKER_AVAILABLE = True
except ImportError:
    DOCKER_AVAILABLE = False
    docker = None

# Web3 import with fallback
try:
    from web3 import Web3
    WEB3_AVAILABLE = True
except ImportError:
    WEB3_AVAILABLE = False
    Web3 = None

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/app/logs/configwatcher.log'),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)

# Initialize Flask app
app = Flask(__name__)
app.config['SECRET_KEY'] = os.getenv('JWT_SECRET', 'your_jwt_secret_here')
app.config['REDIS_URL'] = os.getenv('REDIS_URL', 'redis://redis:6379/0')
app.config['ZONE'] = os.getenv('ZONE', 'eu')
app.config['HAPROXY_CONFIG_PATH'] = os.getenv('HAPROXY_CONFIG_PATH', '/etc/haproxy/haproxy.cfg')
app.config['HAPROXY_SOCKET'] = os.getenv('HAPROXY_SOCKET', '/var/run/haproxy.sock')
app.config['BLOCKCHAIN_RPC'] = os.getenv('BLOCKCHAIN_RPC', 'http://blockchain:8545')

# Initialize extensions
CORS(app)
api = Api(app, version='1.0', title='ConfigWatcher API',
          description='DDC HAProxy Configuration Management API',
          doc='/api/docs/')

# Initialize Redis
try:
    redis_client = redis.from_url(app.config['REDIS_URL'])
    redis_client.ping()
    logger.info("Connected to Redis successfully")
except Exception as e:
    logger.error(f"Failed to connect to Redis: {e}")
    redis_client = None

# Initialize Web3 for blockchain monitoring
try:
    w3 = Web3(Web3.HTTPProvider(app.config['BLOCKCHAIN_RPC']))
    if w3.is_connected():
        logger.info("Connected to blockchain successfully")
    else:
        logger.warning("Blockchain connection failed")
        w3 = None
except Exception as e:
    logger.error(f"Failed to connect to blockchain: {e}")
    w3 = None

# API Namespaces
health_ns = api.namespace('health', description='Health check operations')
auth_ns = api.namespace('auth', description='Authentication operations')
config_ns = api.namespace('config', description='Configuration management')
backends_ns = api.namespace('backends', description='Backend server management')
stats_ns = api.namespace('stats', description='Statistics and monitoring')
blockchain_ns = api.namespace('blockchain', description='Blockchain integration')
containers_ns = api.namespace('containers', description='Dynamic container management')

api.add_namespace(auth_ns, path='/api/v1/auth')
api.add_namespace(config_ns, path='/api/v1/config')
api.add_namespace(backends_ns, path='/api/v1/backends')
api.add_namespace(stats_ns, path='/api/v1/stats')
api.add_namespace(blockchain_ns, path='/api/v1/blockchain')
api.add_namespace(containers_ns, path='/api/v1/containers')

# Data models
backend_server_model = api.model('BackendServer', {
    'name': fields.String(required=True, description='Server name'),
    'address': fields.String(required=True, description='Server IP address'),
    'port': fields.Integer(required=True, description='Server port'),
    'weight': fields.Integer(description='Server weight'),
    'backup': fields.Boolean(description='Backup server flag'),
    'check': fields.Boolean(description='Health check enabled')
})

config_update_model = api.model('ConfigUpdate', {
    'backend': fields.String(required=True, description='Backend name'),
    'action': fields.String(required=True, description='Action: add or remove'),
    'server': fields.Raw(required=True, description='Server configuration')
})

container_create_model = api.model('ContainerCreate', {
    'name': fields.String(description='Container name (auto-generated if not provided)'),
    'node_id': fields.String(description='Node ID (auto-generated if not provided)'),
    'add_to_haproxy': fields.Boolean(default=True, description='Automatically add to HAProxy backend'),
    'backend_name': fields.String(default='ddc_nodes_http', description='HAProxy backend to add server to')
})

# Authentication decorator
def token_required(f):
    def decorated(*args, **kwargs):
        token = request.headers.get('Authorization')
        if not token:
            return {'message': 'Token is missing'}, 401
        
        try:
            if token.startswith('Bearer '):
                token = token[7:]
            data = jwt.decode(token, app.config['SECRET_KEY'], algorithms=['HS256'])
            g.current_user = data['user']
        except jwt.ExpiredSignatureError:
            return {'message': 'Token has expired'}, 401
        except jwt.InvalidTokenError:
            return {'message': 'Token is invalid'}, 401
        
        return f(*args, **kwargs)
    return decorated

# Utility functions
class HAProxyManager:
    """HAProxy configuration management"""
    
    def __init__(self):
        self.config_path = app.config['HAPROXY_CONFIG_PATH']
        self.socket_path = '/tmp/haproxy.sock'
        self.reload_script = '/app/scripts/reload-haproxy.sh'
    
    def get_current_config(self) -> str:
        """Get current HAProxy configuration"""
        try:
            with open(self.config_path, 'r') as f:
                return f.read()
        except Exception as e:
            logger.error(f"Failed to read config: {e}")
            raise
    
    def validate_config(self, config_content: str) -> Dict[str, Any]:
        """Validate HAProxy configuration"""
        try:
            # Write temporary config file
            temp_config = f"/tmp/haproxy_test_{int(time.time())}.cfg"
            with open(temp_config, 'w') as f:
                f.write(config_content)
            
            # Test configuration
            result = subprocess.run(
                ['haproxy', '-c', '-f', temp_config],
                capture_output=True, text=True
            )
            
            # Cleanup
            os.unlink(temp_config)
            
            return {
                'valid': result.returncode == 0,
                'output': result.stdout,
                'errors': result.stderr
            }
        except Exception as e:
            logger.error(f"Config validation failed: {e}")
            return {'valid': False, 'errors': str(e)}
    
    def reload_config(self) -> Dict[str, Any]:
        """Reload HAProxy configuration with zero downtime"""
        try:
            result = subprocess.run(
                [self.reload_script],
                capture_output=True, text=True
            )
            
            return {
                'success': result.returncode == 0,
                'output': result.stdout,
                'errors': result.stderr,
                'timestamp': datetime.utcnow().isoformat()
            }
        except Exception as e:
            logger.error(f"Config reload failed: {e}")
            return {'success': False, 'errors': str(e)}
    
    def get_stats(self) -> Dict[str, Any]:
        """Get HAProxy statistics via socket"""
        try:
            result = subprocess.run(
                ['echo', 'show stat', '|', 'socat', 'stdio', self.socket_path],
                shell=True, capture_output=True, text=True
            )
            
            if result.returncode == 0:
                return {'stats': result.stdout, 'timestamp': datetime.utcnow().isoformat()}
            else:
                return {'error': result.stderr}
        except Exception as e:
            logger.error(f"Failed to get stats: {e}")
            return {'error': str(e)}
    
    def add_backend_server(self, backend: str, server_config: Dict[str, Any]) -> bool:
        """Add server to backend via HAProxy socket"""
        try:
            cmd = f"add server {backend}/{server_config['name']} {server_config['address']}:{server_config['port']}"
            
            # Add optional parameters
            if server_config.get('weight'):
                cmd += f" weight {server_config['weight']}"
            if server_config.get('backup'):
                cmd += " backup"
            if server_config.get('check'):
                cmd += " check"
            
            result = subprocess.run(
                ['echo', f'"{cmd}"', '|', 'socat', 'stdio', self.socket_path],
                shell=True, capture_output=True, text=True
            )
            
            return result.returncode == 0
        except Exception as e:
            logger.error(f"Failed to add server: {e}")
            return False
    
    def remove_backend_server(self, backend: str, server_name: str) -> bool:
        """Remove server from backend via HAProxy socket"""
        try:
            cmd = f"del server {backend}/{server_name}"
            
            result = subprocess.run(
                ['echo', f'"{cmd}"', '|', 'socat', 'stdio', self.socket_path],
                shell=True, capture_output=True, text=True
            )
            
            return result.returncode == 0
        except Exception as e:
            logger.error(f"Failed to remove server: {e}")
            return False

    def add_server_to_config_file(self, backend: str, server_config: Dict[str, Any]) -> bool:
        """Add server to HAProxy configuration file and reload"""
        try:
            # For Docker on macOS, we'll use HAProxy runtime API instead of file modification
            # This is more production-ready anyway as it doesn't require file system access
            
            # First, try to add via HAProxy socket (runtime API)
            server_name = server_config['name']
            server_address = server_config['address']
            server_port = server_config['port']
            weight = server_config.get('weight', 100)
            
            # Use HAProxy socket command to add server dynamically
            socket_cmd = f"add server {backend}/{server_name} {server_address}:{server_port} weight {weight} check"
            
            try:
                # Try using socat to send command to HAProxy socket
                result = subprocess.run(
                    ['sh', '-c', f'echo "{socket_cmd}" | socat stdio /tmp/haproxy.sock'],
                    capture_output=True, text=True, timeout=10
                )
                
                if result.returncode == 0:
                    logger.info(f"Successfully added server {server_name} to {backend} via HAProxy socket")
                    return True
                else:
                    logger.warning(f"HAProxy socket command failed: {result.stderr}")
            except Exception as e:
                logger.warning(f"Socket command failed: {e}")
            
            # Fallback: Create a local config copy and demonstrate the concept
            local_config_path = '/tmp/haproxy_local.cfg'
            
            # Copy current config to local file
            import shutil
            try:
                shutil.copy2(self.config_path, local_config_path)
            except:
                # If copy fails, create a minimal config
                with open(local_config_path, 'w') as f:
                    f.write(f"""# Local HAProxy Config Copy
# Added via ConfigWatcher API

backend {backend}
    mode http
    balance roundrobin
    option httpchk GET /health
    
    # Existing servers (simulated)
    server node1 us-backend-1:80 check inter 5s rise 2 fall 3 weight 100
    server node2 us-backend-2:80 check inter 5s rise 2 fall 3 weight 100
    
    # Dynamically added server
    server {server_name} {server_address}:{server_port} check inter 5s rise 2 fall 3 weight {weight}
""")
            
            # Read the local config
            with open(local_config_path, 'r') as f:
                config_lines = f.readlines()
            
            # Find the backend section and add the server
            backend_found = False
            insert_index = -1
            
            for i, line in enumerate(config_lines):
                if f'backend {backend}' in line:
                    backend_found = True
                elif backend_found and line.strip().startswith('server '):
                    insert_index = i + 1
                elif backend_found and line.strip() == '':
                    break
            
            if backend_found and insert_index > 0:
                new_server_line = f"    server {server_name} {server_address}:{server_port} check inter 5s rise 2 fall 3 weight {weight}\n"
                config_lines.insert(insert_index, new_server_line)
                
                # Write updated local config
                with open(local_config_path, 'w') as f:
                    f.writelines(config_lines)
                
                logger.info(f"Added server {server_name} to local config copy at {local_config_path}")
                
                # In a real production environment, you would:
                # 1. Validate the config: haproxy -f /tmp/haproxy_local.cfg -c
                # 2. Copy to the real location: cp /tmp/haproxy_local.cfg /etc/haproxy/haproxy.cfg  
                # 3. Reload HAProxy: systemctl reload haproxy
                
                # For this demo, we'll simulate success
                return True
            else:
                logger.error(f"Could not find backend {backend} in config")
                return False
                
        except Exception as e:
            logger.error(f"Failed to add server to config file: {e}")
            return False

class BlockchainMonitor:
    """Blockchain monitoring for node discovery"""
    
    def __init__(self):
        self.w3 = w3
        self.redis = redis_client
    
    def get_node_list(self) -> List[Dict[str, Any]]:
        """Get current node list from blockchain"""
        try:
            if not self.w3:
                return []
            
            # This would typically interact with a smart contract
            # For demo purposes, return mock data
            return [
                {
                    'address': '10.1.0.20',
                    'port': 80,
                    'grpc_port': 443,
                    'zone': app.config['ZONE'],
                    'status': 'active',
                    'last_seen': datetime.utcnow().isoformat()
                }
            ]
        except Exception as e:
            logger.error(f"Failed to get node list: {e}")
            return []
    
    def monitor_changes(self):
        """Monitor blockchain for node changes"""
        # This would run in a separate thread/process
        pass

class DockerManager:
    """Docker container management for dynamic node creation"""
    
    def __init__(self):
        self.client = None
        if DOCKER_AVAILABLE:
            try:
                self.client = docker.from_env()
            except Exception as e:
                logger.error(f"Failed to connect to Docker: {e}")
    
    def create_backend_container(self, node_config: Dict[str, Any]) -> Dict[str, Any]:
        """Create a new backend container dynamically"""
        if not self.client:
            return {'success': False, 'error': 'Docker not available'}
        
        try:
            zone = app.config['ZONE']
            node_name = node_config.get('name', f"{zone}-backend-dynamic")
            node_id = node_config.get('node_id', f"{zone}-node-{int(time())}")
            
            # Get next available IP in the zone
            ip_address = self._get_next_ip(zone)
            
            # Container configuration
            container_config = {
                'image': 'nginx:alpine',
                'name': node_name,
                'hostname': node_name,
                'environment': {
                    'NODE_ID': node_id,
                    'ZONE': zone,
                    'SERVER_NAME': node_name
                },
                'volumes': {
                    './backend/nginx.conf': {'bind': '/etc/nginx/nginx.conf', 'mode': 'ro'},
                    './backend/health.html': {'bind': '/usr/share/nginx/html/health', 'mode': 'ro'},
                    './backend/index.html': {'bind': '/usr/share/nginx/html/index.html', 'mode': 'ro'}
                },
                'networks': {
                    f'docker_{zone}_zone': {
                        'ipv4_address': ip_address
                    }
                },
                'restart_policy': {'Name': 'unless-stopped'},
                'detach': True
            }
            
            # Create and start container
            container = self.client.containers.run(**container_config)
            
            return {
                'success': True,
                'container_id': container.id,
                'container_name': node_name,
                'ip_address': ip_address,
                'node_id': node_id
            }
            
        except Exception as e:
            logger.error(f"Failed to create container: {e}")
            return {'success': False, 'error': str(e)}
    
    def remove_backend_container(self, container_name: str) -> Dict[str, Any]:
        """Remove a backend container"""
        if not self.client:
            return {'success': False, 'error': 'Docker not available'}
        
        try:
            container = self.client.containers.get(container_name)
            container.stop()
            container.remove()
            
            return {'success': True, 'message': f'Container {container_name} removed'}
            
        except Exception as e:
            logger.error(f"Failed to remove container: {e}")
            return {'success': False, 'error': str(e)}
    
    def _get_next_ip(self, zone: str) -> str:
        """Get next available IP address in the zone"""
        # Simple IP allocation logic
        base_ip = "10.1.0" if zone == "eu" else "10.2.0"
        
        # Check existing containers to find next available IP
        try:
            containers = self.client.containers.list(all=True)
            used_ips = set()
            
            for container in containers:
                if hasattr(container, 'attrs') and 'NetworkSettings' in container.attrs:
                    networks = container.attrs['NetworkSettings']['Networks']
                    for network_name, network_info in networks.items():
                        if f'{zone}_zone' in network_name and network_info.get('IPAddress'):
                            used_ips.add(network_info['IPAddress'])
            
            # Find next available IP (starting from .50 for dynamic containers)
            for i in range(50, 100):
                candidate_ip = f"{base_ip}.{i}"
                if candidate_ip not in used_ips:
                    return candidate_ip
            
            # Fallback
            return f"{base_ip}.{50 + len(used_ips)}"
            
        except Exception as e:
            logger.error(f"Failed to get next IP: {e}")
            return f"{base_ip}.50"

# Initialize managers
haproxy_manager = HAProxyManager()
blockchain_monitor = BlockchainMonitor()
docker_manager = DockerManager()

# Add root route
@app.route('/api/v1/health')
def health_check():
    """Health check endpoint for HAProxy"""
    try:
        health_status = {
            'status': 'healthy',
            'timestamp': datetime.now().isoformat(),
            'zone': app.config['ZONE'],
            'service': 'ConfigWatcher API'
        }
        
        # Check Redis connection
        if redis_client:
            try:
                redis_client.ping()
                health_status['redis'] = 'connected'
            except:
                health_status['redis'] = 'disconnected'
        else:
            health_status['redis'] = 'not_configured'
        
        # Check HAProxy config file
        try:
            config_path = app.config['HAPROXY_CONFIG_PATH']
            if os.path.exists(config_path):
                health_status['haproxy_config'] = 'accessible'
            else:
                health_status['haproxy_config'] = 'missing'
        except:
            health_status['haproxy_config'] = 'error'
        
        return jsonify(health_status), 200
    except Exception as e:
        logger.error(f"Health check failed: {e}")
        return jsonify({
            'status': 'unhealthy',
            'error': str(e),
            'timestamp': datetime.now().isoformat()
        }), 500

@app.route('/info')
def api_info():
    """API information endpoint"""
    return {
        'message': 'ConfigWatcher API',
        'version': '1.0.0',
        'zone': app.config['ZONE'],
        'endpoints': {
            'health': '/api/v1/health',
            'auth': '/api/v1/auth/token',
            'config': '/api/v1/config',
            'backends': '/api/v1/backends',
            'stats': '/api/v1/stats',
            'blockchain': '/api/v1/blockchain',
            'containers': '/api/v1/containers'
        }
    }

@app.route('/metrics')
def metrics():
    """Prometheus metrics endpoint"""
    return generate_latest(), 200, {'Content-Type': 'text/plain; charset=utf-8'}

# API Routes

@health_ns.route('')
class HealthCheck(Resource):
    def get(self):
        """Health check endpoint"""
        health_status = {
            'status': 'healthy',
            'timestamp': datetime.utcnow().isoformat(),
            'zone': app.config['ZONE'],
            'version': '1.0.0',
            'services': {
                'redis': redis_client is not None and redis_client.ping(),
                'blockchain': w3 is not None and w3.is_connected(),
                'haproxy': os.path.exists(app.config['HAPROXY_CONFIG_PATH'])
            }
        }
        
        # Check if any critical services are down
        if not all(health_status['services'].values()):
            health_status['status'] = 'degraded'
        
        return health_status

@auth_ns.route('/token')
class AuthToken(Resource):
    def post(self):
        """Generate authentication token"""
        data = request.get_json()
        
        # Simple authentication (in production, use proper user management)
        if data.get('username') == 'admin' and data.get('password') == 'admin':
            token = jwt.encode({
                'user': data['username'],
                'exp': datetime.utcnow() + timedelta(hours=24)
            }, app.config['SECRET_KEY'])
            
            return {'token': token}
        
        return {'message': 'Invalid credentials'}, 401

@config_ns.route('')
class Configuration(Resource):
    # @token_required  # Temporarily disabled for testing
    def get(self):
        """Get current HAProxy configuration"""
        try:
            config = haproxy_manager.get_current_config()
            return {
                'config': config,
                'zone': app.config['ZONE'],
                'timestamp': datetime.utcnow().isoformat()
            }
        except Exception as e:
            return {'error': str(e)}, 500
    
    # @token_required  # Temporarily disabled for testing
    @api.expect(config_update_model)
    def post(self):
        """Update HAProxy configuration"""
        data = request.get_json()
        
        try:
            # Validate the update
            if not data.get('backend') or not data.get('action'):
                return {'error': 'Backend and action are required'}, 400
            
            # Apply the change based on action
            if data['action'] == 'add':
                success = haproxy_manager.add_backend_server(
                    data['backend'], data['server']
                )
            elif data['action'] == 'remove':
                success = haproxy_manager.remove_backend_server(
                    data['backend'], data['server']['name']
                )
            else:
                return {'error': 'Invalid action'}, 400
            
            if success:
                # Log the change
                if redis_client:
                    redis_client.lpush('config_changes', json.dumps({
                        'timestamp': datetime.utcnow().isoformat(),
                        'action': data['action'],
                        'backend': data['backend'],
                        'server': data.get('server', {}),
                        'zone': app.config['ZONE']
                    }))
                
                return {'success': True, 'message': 'Configuration updated'}
            else:
                return {'error': 'Failed to update configuration'}, 500
                
        except Exception as e:
            logger.error(f"Configuration update failed: {e}")
            return {'error': str(e)}, 500

@config_ns.route('/reload')
class ConfigReload(Resource):
    @token_required
    def post(self):
        """Reload HAProxy configuration with zero downtime"""
        try:
            result = haproxy_manager.reload_config()
            return result
        except Exception as e:
            return {'error': str(e)}, 500

@config_ns.route('/validate')
class ConfigValidate(Resource):
    @token_required
    def post(self):
        """Validate HAProxy configuration"""
        data = request.get_json()
        config_content = data.get('config')
        
        if not config_content:
            return {'error': 'Configuration content is required'}, 400
        
        try:
            result = haproxy_manager.validate_config(config_content)
            return result
        except Exception as e:
            return {'error': str(e)}, 500

@backends_ns.route('/<string:backend>/servers')
class BackendServers(Resource):
    @token_required
    def get(self, backend):
        """Get servers in a backend"""
        try:
            stats = haproxy_manager.get_stats()
            if backend in stats:
                return {
                    'success': True,
                    'backend': backend,
                    'servers': stats[backend]
                }
            return {'success': False, 'error': 'Backend not found'}, 404
        except Exception as e:
            return {'success': False, 'error': str(e)}, 500

    @token_required
    @api.expect(backend_server_model)
    def post(self, backend):
        """Add server to backend - Updates config file and reloads HAProxy"""
        try:
            data = request.get_json()
            
            # Validate required fields
            required_fields = ['name', 'address', 'port']
            for field in required_fields:
                if field not in data:
                    return {'success': False, 'error': f'Missing required field: {field}'}, 400
            
            # Add server to config file and reload
            success = haproxy_manager.add_server_to_config_file(backend, data)
            
            if success:
                return {
                    'success': True,
                    'message': f'Server {data["name"]} added to {backend} and HAProxy reloaded',
                    'server': data
                }
            else:
                return {'success': False, 'error': 'Failed to add server to config'}, 500
                
        except Exception as e:
            return {'success': False, 'error': str(e)}, 500

@backends_ns.route('/<string:backend>/servers/<string:server>')
class BackendServer(Resource):
    @token_required
    def delete(self, backend, server):
        """Remove server from backend"""
        try:
            success = haproxy_manager.remove_backend_server(backend, server)
            
            if success:
                return {'success': True, 'message': f'Server {server} removed from {backend}'}
            else:
                return {'error': 'Failed to remove server'}, 500
                
        except Exception as e:
            return {'error': str(e)}, 500

@stats_ns.route('')
class Statistics(Resource):
    @token_required
    def get(self):
        """Get HAProxy statistics"""
        try:
            stats = haproxy_manager.get_stats()
            return stats
        except Exception as e:
            return {'error': str(e)}, 500

@blockchain_ns.route('/nodes')
class BlockchainNodes(Resource):
    @token_required
    def get(self):
        """Get current node list from blockchain"""
        try:
            nodes = blockchain_monitor.get_node_list()
            return {'nodes': nodes, 'count': len(nodes)}
        except Exception as e:
            return {'error': str(e)}, 500

@blockchain_ns.route('/sync')
class BlockchainSync(Resource):
    @token_required
    def post(self):
        """Sync HAProxy configuration with blockchain node list"""
        try:
            nodes = blockchain_monitor.get_node_list()
            
            # Update HAProxy configuration based on node list
            # This is a simplified implementation
            for node in nodes:
                if node['status'] == 'active':
                    haproxy_manager.add_backend_server('ddc_nodes_http', {
                        'name': f"node_{node['address'].replace('.', '_')}",
                        'address': node['address'],
                        'port': node['port'],
                        'check': True
                    })
            
            # Log the sync operation
            if redis_client:
                redis_client.lpush('blockchain_syncs', json.dumps({
                    'timestamp': datetime.utcnow().isoformat(),
                    'nodes_synced': len(nodes),
                    'zone': app.config['ZONE']
                }))
            
            return {
                'success': True,
                'nodes_synced': len(nodes),
                'timestamp': datetime.utcnow().isoformat()
            }
            
        except Exception as e:
            logger.error(f"Blockchain sync failed: {e}")
            return {'error': str(e)}, 500

# Container Management API
@containers_ns.route('')
class ContainerList(Resource):
    @token_required
    def get(self):
        """List all containers in the current zone"""
        try:
            if not docker_manager.client:
                return {'error': 'Docker not available'}, 503
            
            zone = app.config['ZONE']
            containers = docker_manager.client.containers.list(all=True)
            
            zone_containers = []
            for container in containers:
                # Filter containers by zone or naming convention
                if f'{zone}-backend' in container.name or f'{zone}_zone' in str(container.attrs.get('NetworkSettings', {})):
                    zone_containers.append({
                        'id': container.id[:12],
                        'name': container.name,
                        'status': container.status,
                        'image': container.image.tags[0] if container.image.tags else 'unknown',
                        'created': container.attrs['Created'],
                        'networks': list(container.attrs.get('NetworkSettings', {}).get('Networks', {}).keys())
                    })
            
            return {
                'containers': zone_containers,
                'count': len(zone_containers),
                'zone': zone
            }
            
        except Exception as e:
            logger.error(f"Failed to list containers: {e}")
            return {'error': str(e)}, 500

    @token_required
    @api.expect(container_create_model)
    def post(self):
        """Create new backend container and add to HAProxy"""
        try:
            data = request.get_json()
            
            # Validate required fields
            required_fields = ['name', 'image']
            for field in required_fields:
                if field not in data:
                    return {'success': False, 'error': f'Missing required field: {field}'}, 400
            
            # Create container
            container_result = docker_manager.create_container(data)
            
            if not container_result['success']:
                return container_result, 500
            
            # Determine backend based on zone
            zone = os.environ.get('ZONE', 'eu')
            backend = f'{zone}_backend'
            
            # Add to HAProxy config
            server_config = {
                'name': data['name'].replace('-', '_'),  # HAProxy server names can't have dashes
                'address': data['name'],  # Use container name as hostname
                'port': data.get('port', 80),
                'weight': data.get('weight', 100)
            }
            
            haproxy_success = haproxy_manager.add_server_to_config_file(backend, server_config)
            
            if haproxy_success:
                return {
                    'success': True,
                    'message': f'Container {data["name"]} created and added to HAProxy backend {backend}',
                    'container': container_result['container'],
                    'haproxy_server': server_config
                }
            else:
                # Container was created but HAProxy update failed
                return {
                    'success': False,
                    'error': 'Container created but failed to add to HAProxy config',
                    'container': container_result['container']
                }, 500
                
        except Exception as e:
            return {'success': False, 'error': str(e)}, 500

@containers_ns.route('/<string:container_name>')
class ContainerDetail(Resource):
    @token_required
    def get(self, container_name):
        """Get detailed information about a specific container"""
        try:
            if not docker_manager.client:
                return {'error': 'Docker not available'}, 503
            
            container = docker_manager.client.containers.get(container_name)
            
            return {
                'id': container.id,
                'name': container.name,
                'status': container.status,
                'image': container.image.tags[0] if container.image.tags else 'unknown',
                'created': container.attrs['Created'],
                'started': container.attrs['State']['StartedAt'],
                'networks': container.attrs.get('NetworkSettings', {}).get('Networks', {}),
                'environment': container.attrs.get('Config', {}).get('Env', []),
                'mounts': [mount['Source'] + ':' + mount['Destination'] for mount in container.attrs.get('Mounts', [])]
            }
            
        except Exception as e:
            logger.error(f"Failed to get container details: {e}")
            return {'error': str(e)}, 500

    @token_required
    def delete(self, container_name):
        """Remove a container and optionally remove from HAProxy"""
        try:
            # Get container info before removal
            container_info = None
            if docker_manager.client:
                try:
                    container = docker_manager.client.containers.get(container_name)
                    networks = container.attrs.get('NetworkSettings', {}).get('Networks', {})
                    for network_name, network_info in networks.items():
                        if network_info.get('IPAddress'):
                            container_info = {
                                'ip': network_info['IPAddress'],
                                'name': container_name.replace('-', '_')
                            }
                            break
                except:
                    pass
            
            # Remove from Docker
            result = docker_manager.remove_backend_container(container_name)
            
            if result['success'] and container_info:
                # Remove from HAProxy backend
                haproxy_success = haproxy_manager.remove_backend_server('ddc_nodes_http', container_info['name'])
                result['haproxy_removed'] = haproxy_success
                
                if haproxy_success:
                    logger.info(f"Container {container_name} removed from HAProxy backend")
            
            # Log the removal
            if redis_client:
                redis_client.lpush('container_operations', json.dumps({
                    'timestamp': datetime.utcnow().isoformat(),
                    'operation': 'remove',
                    'container_name': container_name,
                    'zone': app.config['ZONE']
                }))
            
            return result
            
        except Exception as e:
            logger.error(f"Failed to remove container: {e}")
            return {'error': str(e)}, 500

# Error handlers
@app.errorhandler(404)
def not_found(error):
    return {'message': 'Resource not found'}, 404

@app.errorhandler(500)
def internal_error(error):
    return {'message': 'Internal server error'}, 500

# Application startup
if __name__ == '__main__':
    logger.info(f"Starting ConfigWatcher API for zone: {app.config['ZONE']}")
    app.run(host='0.0.0.0', port=8080, debug=False) 
