#!/bin/sh

appName="$FLY_APP_NAME"
appIP="$(dig +short $appName.fly.dev 127.0.0.1)"

# Subtitute variable in xray config
cat /app/config/xray.json.var | \
    sed -e "s/\$UUID/${UUID}/g" \
        -e "s/\$ParameterSSENCYPT/${ParameterSSENCYPT}/g" \
        -e "s/\$appName/${appName}/g" \
        -e "s/\$appIP/${appIP}/g" \
    > /app/config/xray.json

# Start Tor
tor &

# Start Xray
/app/xray/xray -config /app/config/xray.json &

# Start Caddy
caddy run --config /app/config/Caddyfile --adapter caddyfile &

# Start frp server
/app/frps -c /app/config/frps.toml &

# Wait for execution to finished
wait
