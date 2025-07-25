# Stage 1: Build FRP with custom patches
FROM golang:1.22-alpine AS frp-builder
RUN apk add --no-cache curl patch make git
WORKDIR /frp
RUN curl -Ls https://api.github.com/repos/fatedier/frp/releases/latest | grep '"tarball_url":' | sed -E 's/.*"([^"]+)".*/\1/' | xargs curl -Ls | tar -xz --strip-components 1
COPY frp_patches/ /frp/patches/
RUN patch -p1 < patches/udp-proxy-fly-global-services.patch && \
    patch -p1 < patches/kcp-quic-fly-global-services.patch
RUN make frps

# Stage 2: Get Xray binary
FROM alpine:latest AS xray-builder
RUN apk add --no-cache curl unzip
WORKDIR /app
RUN curl -Ls https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && \
    unzip xray.zip xray && \
    rm xray.zip

# Stage 3: Build Admin Dashboard
FROM golang:1.22-alpine AS dashboard-builder
WORKDIR /app
COPY dashboard/ .
RUN CGO_ENABLED=0 go build -v -ldflags="-s -w" -o dashboard main.go

# Final Stage: Assemble the application
FROM alpine:3.19
LABEL maintainer="Your Name"

# Install runtime dependencies and s6-overlay
RUN apk add --no-cache \
    bash \
    ca-certificates \
    openssh \
    openssl \
    shadow \
    tor \
    traefik \
    tzdata && \
    addgroup -S app && adduser -S -G app -h /app app
# Install s6-overlay for process management
ADD https://github.com/just-containers/s6-overlay/releases/download/v3.1.6.2/s6-overlay-noarch.tar.xz /tmp
ADD https://github.com/just-containers/s6-overlay/releases/download/v3.1.6.2/s6-overlay-x86_64.tar.xz /tmp
RUN tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz && \
    tar -C / -Jxpf /tmp/s6-overlay-x86_64.tar.xz && \
    rm -rf /tmp/*

# Copy built binaries from builder stages
COPY --from=frp-builder /frp/bin/frps /usr/bin/
COPY --from=xray-builder /app/xray /usr/bin/
COPY --from=dashboard-builder /app/dashboard /usr/bin/

# Copy application structure (configs, service definitions)
COPY rootfs/ /

# Set up persistent data volume
RUN mkdir -p /data/config /data/logs && \
    chown -R app:app /data
VOLUME /data

# Expose ports (for documentation, fly.toml handles actual exposure)
EXPOSE 80 443 22 7000 7001 7002

# Set s6-overlay as the entrypoint
ENTRYPOINT [ "/init" ]
