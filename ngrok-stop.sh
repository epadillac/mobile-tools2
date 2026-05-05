#!/bin/bash

# Stop ngrok tunnel

PID_FILE="/tmp/ngrok.pid"

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 $PID 2>/dev/null; then
        echo "Stopping ngrok (PID: $PID)..."
        kill $PID
        rm -f "$PID_FILE"
        echo "ngrok stopped."
    else
        echo "ngrok not running (stale PID file)."
        rm -f "$PID_FILE"
    fi
else
    echo "No ngrok running."
fi