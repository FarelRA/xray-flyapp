# Build stage
FROM alpine:edge AS xray-builder

# Install build dependencies
RUN apk add --no-cache wget busybox unzip

# Create app directories
RUN mkdir -p /app/config /app/xray /app/index /app/sockets

# Set working directory
WORKDIR /app

# Download and install Xray
RUN wget -qO- https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip | \
    busybox unzip -d xray/ - && \
    chmod +x xray/xray

# Configure Xray
COPY xray/xray.json config/xray.json.var

# Configure Caddy
COPY caddy/Caddyfile config/Caddyfile.var

# Configure torrc
COPY tor/torrc config/

# Copy mikutap to Caddy index page
COPY caddy/mikutap/. index/

# Create robots.txt
RUN echo -e "User-agent: *\nDisallow: /" > index/robots.txt




# Build stage for frps
FROM golang:alpine AS frp-builder

# Install patch utility
RUN apk add --no-cache patch

# Set working directory to frp
WORKDIR /frp

# Set version argument for frp
ARG VERSION=0.61.0

# Download and extract frp source code
RUN wget -qO- https://github.com/fatedier/frp/archive/refs/tags/v${VERSION}.tar.gz | tar -xz --strip-components 1

# Copy patch files to the container
ADD patches patches

# Apply patch for UDP proxy with fly-global-services
RUN patch -p1 < patches/udp-proxy-fly-global-services.patch

# Apply patch for KCP and QUIC with fly-global-services
RUN patch -p1 < patches/kcp-quic-fly-global-services.patch

# Build frps binary
RUN CGO_ENABLED=0 go install ./cmd/frps




# Build stage for openssh
FROM alpine:edge AS ssh-builder

# Install openssh
RUN apk add --no-cache openssh

# Crate `.ssh` directory
RUN mkdir -p /root/.ssh

# Set permission
RUN chmod 0700 /root/.ssh

# Disallow password authentication
RUN echo -e "PasswordAuthentication no" >> /etc/ssh/sshd_config

# Set sshd port
RUN echo -e "Port 7022" >> /etc/ssh/sshd_config

# Generate ssh keys
RUN ssh-keygen -A




# Runtime stage
FROM alpine:edge AS main

# Install runtime dependencies
RUN apk add --no-cache ca-certificates caddy tor bind-tools openssh bash

# Copy config from build stage
COPY --from=ssh-builder /etc/ssh /etc/ssh
COPY --from=ssh-builder /root/.ssh /root/.ssh

# Copy the entire app directory from build stage
COPY --from=xray-builder /app /app

# Copy frps binary from build stage
COPY --from=frp-builder /go/bin/frps /app

# Set working directory
WORKDIR /app

# Copy frps configuration file
COPY frps.toml config/

# Copy start script file
COPY start.sh .

# Make start.sh executable
RUN chmod +x start.sh

# Define entrypoint
ENTRYPOINT ["/app/start.sh"]
