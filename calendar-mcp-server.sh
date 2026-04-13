#!/bin/bash
# Wrapper script for Calendar MCP Server
# This gives the background activity a recognizable name in macOS.
# Includes a short startup delay to avoid race conditions with clients
# that launch at login (e.g., Claude Desktop).

SCRIPT_DIR="$(dirname "$0")"
PYTHON="$SCRIPT_DIR/venv/bin/python3"
SERVER="$SCRIPT_DIR/calendar_mcp_server.py"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] calendar-mcp-server starting..." >&2

# Brief delay on cold boot so the server is ready before fast-launching clients
sleep 3

if [ ! -x "$PYTHON" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Python not found at $PYTHON" >&2
    exit 1
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Launching server: $PYTHON $SERVER" >&2
exec "$PYTHON" "$SERVER" "$@"
