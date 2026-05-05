#!/bin/bash

# ngrok tunnel for mobile-tools
# Exposes localhost:9000 at https://sufficiently-unfanned-lanita.ngrok-free.dev
#
# The ngrok authtoken is read from .env (NGROK_AUTHTOKEN). Never hardcode it
# here — this script lives in the working tree and would be readable by anyone
# with shell access to the machine.

set -a
[ -f "$(dirname "$0")/.env" ] && . "$(dirname "$0")/.env"
set +a

if [ -z "$NGROK_AUTHTOKEN" ]; then
  echo "ERROR: NGROK_AUTHTOKEN is not set. Add it to .env." >&2
  exit 1
fi

LOG_FILE="/tmp/ngrok.log"
PID_FILE="/tmp/ngrok.pid"

# Check if tunnel is already running
if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
    echo "ngrok already running (PID: $(cat $PID_FILE))"
    echo "Public: https://sufficiently-unfanned-lanita.ngrok-free.dev"
    exit 0
fi

# Start ngrok in background
echo "Starting ngrok tunnel in background..."
nohup ./bin/ngrok http 9000 --authtoken "$NGROK_AUTHTOKEN" --domain sufficiently-unfanned-lanita.ngrok-free.dev > "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"

sleep 2

if kill -0 $(cat "$PID_FILE") 2>/dev/null; then
    echo "ngrok started successfully (PID: $(cat $PID_FILE))"
    echo "Public: https://sufficiently-unfanned-lanita.ngrok-free.dev"
    echo "Logs:   $LOG_FILE"
else
    echo "Failed to start ngrok. Check $LOG_FILE for errors."
    exit 1
fi