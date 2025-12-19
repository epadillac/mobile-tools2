#!/bin/bash

# Cloudflare Tunnel for mobile-tools
# Exposes localhost:3000 at https://tools.bambuapps.xyz

TUNNEL_NAME="mobile-tools"
LOCAL_PORT=3000
LOG_FILE="/tmp/cloudflared.log"
PID_FILE="/tmp/cloudflared.pid"

# Check if tunnel is already running
if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
    echo "Tunnel already running (PID: $(cat $PID_FILE))"
    echo "Public: https://tools.bambuapps.xyz"
    exit 0
fi

# Start tunnel in background
echo "Starting Cloudflare Tunnel in background..."
nohup cloudflared tunnel --url http://localhost:$LOCAL_PORT run $TUNNEL_NAME > "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"

sleep 2

if kill -0 $(cat "$PID_FILE") 2>/dev/null; then
    echo "Tunnel started successfully (PID: $(cat $PID_FILE))"
    echo "Local:  http://localhost:$LOCAL_PORT"
    echo "Public: https://tools.bambuapps.xyz"
    echo "Logs:   $LOG_FILE"
else
    echo "Failed to start tunnel. Check $LOG_FILE for errors."
    exit 1
fi