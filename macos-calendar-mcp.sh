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

case "${1:-status}" in
    status)
        cmd_status
        ;;
    *)
        echo "Usage: macos-calendar-mcp [status]"
        exit 1
        ;;
esac
