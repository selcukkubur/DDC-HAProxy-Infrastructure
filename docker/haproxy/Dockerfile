# DDC HAProxy Infrastructure - HAProxy + Keepalived Docker Image
FROM haproxy:2.8-alpine

# Switch to root to install packages
USER root

# Update package index and install packages
RUN apk update && apk add --no-cache \
    keepalived \
    curl \
    openssl \
    socat \
    bash \
    iproute2 \
    iputils \
    tcpdump \
    net-tools \
    procps \
    && rm -rf /var/cache/apk/*

# Create necessary directories
RUN mkdir -p /etc/haproxy/errors \
    /etc/keepalived \
    /etc/ssl/certs \
    /etc/ssl/private \
    /var/run \
    /var/log

# Copy HAProxy error pages
COPY errors/* /etc/haproxy/errors/

# Copy startup script
COPY start-haproxy.sh /start-haproxy.sh
RUN chmod +x /start-haproxy.sh

# Generate self-signed certificate for testing
RUN openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/ssl/private/haproxy.key \
    -out /etc/ssl/certs/haproxy.crt \
    -subj "/C=US/ST=Test/L=Test/O=DDC/OU=Testing/CN=*.ddc.local" && \
    cat /etc/ssl/certs/haproxy.crt /etc/ssl/private/haproxy.key > /etc/ssl/certs/haproxy.pem

# Create HAProxy user if it doesn't exist
RUN addgroup -g 99 haproxy 2>/dev/null || true && \
    adduser -D -u 99 -G haproxy haproxy 2>/dev/null || true

# Fix permissions
RUN chown -R haproxy:haproxy /var/run /var/log /etc/haproxy /etc/keepalived

# Expose ports
EXPOSE 80 443 8080 8404 8443

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD curl -f http://localhost:8404/health || exit 1

# Start both HAProxy and Keepalived
CMD ["/start-haproxy.sh"] 
