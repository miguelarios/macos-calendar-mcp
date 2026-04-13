#!/bin/bash
# macos-calendar-mcp — CLI for the Calendar MCP Server

PLIST="$HOME/Library/LaunchAgents/com.local.calendar-mcp.plist"
LABEL="com.local.calendar-mcp"

cmd_status() {
    # Read port from plist
    local port
    if [ -f "$PLIST" ]; then
        port=$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:CALENDAR_MCP_PORT" "$PLIST" 2>/dev/null || echo "9876")
    else
        port="9876"
        echo "Warning: LaunchAgent plist not found. Using default port."
    fi

    local url="http://127.0.0.1:${port}/mcp"

    echo "Calendar MCP Server"
    echo "  Port: $port"
    echo "  URL:  $url"
    echo ""

    # Check if running
    if launchctl list "$LABEL" &>/dev/null 2>&1; then
        local pid
        pid=$(launchctl list "$LABEL" 2>/dev/null | awk 'NR==2{print $1}')
        if [ "$pid" != "-" ] && [ -n "$pid" ]; then
            echo "  Status: running (PID $pid)"
        else
            echo "  Status: loaded but not running"
        fi
    else
        echo "  Status: not loaded"
    fi
}

cmd_restart() {
    echo "Restarting Calendar MCP Server..."
    if [ ! -f "$PLIST" ]; then
        echo "Error: LaunchAgent plist not found. Run install.sh first."
        exit 1
    fi
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    echo "Done. Waiting for server..."
    sleep 4
    cmd_status
}

cmd_start() {
    echo "Starting Calendar MCP Server..."
    if [ ! -f "$PLIST" ]; then
        echo "Error: LaunchAgent plist not found. Run install.sh first."
        exit 1
    fi
    launchctl load "$PLIST" 2>/dev/null
    echo "Done. Waiting for server..."
    sleep 4
    cmd_status
}

cmd_stop() {
    echo "Stopping Calendar MCP Server..."
    launchctl unload "$PLIST" 2>/dev/null || true
    echo "Done."
}

cmd_logs() {
    local log_dir
    log_dir="$HOME/.local/share/calendar-mcp/logs"
    echo "=== stderr (last 20 lines) ==="
    tail -20 "$log_dir/stderr.log" 2>/dev/null || echo "(no stderr log)"
    echo ""
    echo "=== stdout (last 20 lines) ==="
    tail -20 "$log_dir/stdout.log" 2>/dev/null || echo "(no stdout log)"
}

case "${1:-status}" in
    status)
        cmd_status
        ;;
    restart)
        cmd_restart
        ;;
    start)
        cmd_start
        ;;
    stop)
        cmd_stop
        ;;
    logs)
        cmd_logs
        ;;
    *)
        echo "Usage: macos-calendar-mcp [status|start|stop|restart|logs]"
        exit 1
        ;;
esac
