#!/bin/sh

appName="$FLY_APP_NAME"
appIP="$(dig +short $appName.fly.dev 127.0.0.1)"
udpBindAddr="$(grep 'fly-global-services' /etc/hosts | awk '{print $1}')"

# Subtitute variable in xray config
cat /app/config/xray.json.var | \
    sed -e "s/\$UUID/${UUID}/g" \
        -e "s/\$ParameterSSENCYPT/${ParameterSSENCYPT}/g" \
        -e "s/\$appName/${appName}/g" \
        -e "s/\$appIP/${appIP}/g" \
        -e "s/\$udpBindAddr/${udpBindAddr}/g" \
    > /app/config/xray.json

# Start Tor
tor -f /app/config/torrc &

# Start Xray
/app/xray/xray -config /app/config/xray.json &

# Start Nginx
nginx -c /app/config/nginx.conf &

# Start frp server
/app/frps -c /app/config/frps.toml &

# Wait for execution to finished
wait
