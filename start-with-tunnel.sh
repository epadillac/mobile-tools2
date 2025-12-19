#!/bin/bash

# Start Rails server with Cloudflare Tunnel
# Both stop together when you press Ctrl+C

TUNNEL_NAME="mobile-tools"
LOCAL_PORT=3000
LOG_FILE="/tmp/cloudflared.log"

# Cleanup function
cleanup() {
    echo ""
    echo "Stopping tunnel..."
    kill $TUNNEL_PID 2>/dev/null
    echo "Stopping Rails..."
    kill $RAILS_PID 2>/dev/null
    wait
    echo "Goodbye!"
    exit 0
}

trap cleanup SIGINT SIGTERM

# Start tunnel in background
echo "Starting Cloudflare Tunnel..."
cloudflared tunnel --url http://localhost:$LOCAL_PORT run $TUNNEL_NAME > "$LOG_FILE" 2>&1 &
TUNNEL_PID=$!

sleep 2
echo "Tunnel running (PID: $TUNNEL_PID)"
echo "Public URL: https://tools.bambuapps.xyz"
echo ""

# Start Rails in foreground
echo "Starting Rails server..."
bin/rails server -p $LOCAL_PORT &
RAILS_PID=$!

# Wait for either to exit
wait $RAILS_PID
cleanup