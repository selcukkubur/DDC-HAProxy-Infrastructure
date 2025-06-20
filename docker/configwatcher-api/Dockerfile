FROM python:3.11-slim

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    socat \
    netcat-openbsd \
    procps \
    net-tools \
    iputils-ping \
    dnsutils \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Create necessary directories
RUN mkdir -p /app/data /app/logs /app/scripts /app/config

# Copy application code
COPY src/ ./src/
COPY config/ ./config/
COPY scripts/ ./scripts/

# Copy startup script
COPY start-configwatcher.sh /start-configwatcher.sh
RUN chmod +x /start-configwatcher.sh

# Create non-root user
RUN useradd -m -u 1000 configwatcher && \
    chown -R configwatcher:configwatcher /app
USER configwatcher

# Expose API port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD curl -f http://localhost:8080/api/v1/health || exit 1

# Start the application
CMD ["/start-configwatcher.sh"] 
