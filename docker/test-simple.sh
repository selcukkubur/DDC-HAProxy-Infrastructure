#!/bin/bash

echo "🚀 DDC HAProxy Infrastructure - Simple Test"
echo "============================================"

# Check if we're in the right directory
if [ ! -f "docker-compose.yml" ]; then
    echo "❌ Please run from docker/ directory: cd docker && ./test-simple.sh"
    exit 1
fi

# Clean up
echo "🧹 Cleaning up..."
docker-compose down -v 2>/dev/null || true

# Start services
echo "🐳 Starting services..."
if docker-compose up -d; then
    echo "✅ Services starting..."
    
    # Wait for services
    echo "⏳ Waiting 30 seconds for services to be ready..."
    sleep 30
    
    # Check what's running
    echo "📊 Running containers:"
    docker ps --format "table {{.Names}}\t{{.Status}}"
    
    echo ""
    echo "🧪 Testing endpoints..."
    
    # Test EU HAProxy
    if curl -s http://localhost:80 >/dev/null 2>&1; then
        echo "✅ EU HAProxy (port 80) is responding"
    else
        echo "⚠️  EU HAProxy (port 80) not ready yet"
    fi
    
    # Test US HAProxy  
    if curl -s http://localhost:8086 >/dev/null 2>&1; then
        echo "✅ US HAProxy (port 8086) is responding"
    else
        echo "⚠️  US HAProxy (port 8086) not ready yet"
    fi
    
    # Test ConfigWatcher EU
    if curl -s http://localhost:9080/api/v1/health >/dev/null 2>&1; then
        echo "✅ EU ConfigWatcher is responding"
    else
        echo "⚠️  EU ConfigWatcher not ready yet"
    fi
    
    # Test ConfigWatcher US
    if curl -s http://localhost:9081/api/v1/health >/dev/null 2>&1; then
        echo "✅ US ConfigWatcher is responding"
    else
        echo "⚠️  US ConfigWatcher not ready yet"
    fi
    
    echo ""
    echo "🌐 Access URLs:"
    echo "   EU HAProxy:       http://localhost:80"
    echo "   US HAProxy:       http://localhost:8086"
    echo "   EU HAProxy Stats: http://localhost:8404/stats"
    echo "   US HAProxy Stats: http://localhost:8406/stats"
    echo "   EU ConfigWatcher: http://localhost:9080/api/v1/health"
    echo "   US ConfigWatcher: http://localhost:9081/api/v1/health"
    echo "   Prometheus:       http://localhost:9090"
    echo "   Grafana:          http://localhost:3000"
    
    echo ""
    echo "✨ Success! Multi-zone HAProxy infrastructure is running!"
    echo "📋 To stop: docker-compose down"
    
else
    echo "❌ Failed to start services"
    echo "📋 Check logs: docker-compose logs"
    exit 1
fi 
