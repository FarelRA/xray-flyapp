# Xray build stage
FROM alpine:latest AS xray-builder

# Install dependencies
RUN apk add --no-cache curl busybox unzip

# Set working directory
WORKDIR /app

# Download and install Xray
RUN curl -sSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip | \
    busybox unzip -d xray - && \
    chmod +x xray/xray && \
    rm -f Xray-linux-64.zip

# Copy configuration files
COPY xray/xray.json config/xray.json.var
COPY nginx/nginx.conf config/nginx.conf.var
COPY tor/torrc config/
COPY nginx/mikutap/ index/




# FRP build stage
FROM golang:alpine AS frp-builder

# Install build dependencies
RUN apk add --no-cache curl patch make

# Set working directory
WORKDIR /frp

# Copy 'get_frp.sh' script and download FRP source code
COPY scripts/get_frp.sh get_frp.sh
RUN sh get_frp.sh

# Copy patch files and apply them
COPY frp/patches/ patches/
RUN patch -p1 < patches/udp-proxy-fly-global-services.patch && \
    patch -p1 < patches/kcp-quic-fly-global-services.patch

# Build frps binary
RUN make frps

# Copy the built binary
WORKDIR /app
RUN cp /frp/bin/frps .

# Copy configuration file
COPY frp/frps.toml config/




# SSH build stage
FROM alpine:latest AS ssh-builder

# Install OpenSSH
RUN apk add --no-cache openssh

# Configure OpenSSH
RUN echo "PasswordAuthentication no" >> /etc/ssh/sshd_config && \
    echo "Port 7012" >> /etc/ssh/sshd_config




# Runtime stage
FROM nginx:alpine AS main

# Install runtime dependencies
RUN apk add --no-cache ca-certificates tor bind-tools openssh bash tzdata

# Copy app directory from build stages
COPY --from=xray-builder /app/ /app/
COPY --from=frp-builder /app/ /app/
COPY --from=ssh-builder /etc/ssh/ /etc/ssh/

# Set working directory
WORKDIR /app

# Copy and set up the start script
COPY scripts/start.sh .
RUN chmod +x start.sh

# Define the entry point
ENTRYPOINT ["/app/start.sh"]
