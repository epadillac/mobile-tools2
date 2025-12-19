#!/bin/bash

# Stop Cloudflare Tunnel

PID_FILE="/tmp/cloudflared.pid"

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 $PID 2>/dev/null; then
        echo "Stopping tunnel (PID: $PID)..."
        kill $PID
        rm -f "$PID_FILE"
        echo "Tunnel stopped."
    else
        echo "Tunnel not running (stale PID file)."
        rm -f "$PID_FILE"
    fi
else
    echo "No tunnel running."
fi