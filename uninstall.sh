#!/bin/bash
set -euo pipefail

# Calendar MCP Server — Uninstaller
# Stops the service and removes all installed files.

HOME_DIR="$HOME"
PLIST_NAME="com.local.calendar-mcp"
LAUNCH_AGENTS_DIR="$HOME_DIR/Library/LaunchAgents"

echo "==> Calendar MCP Server Uninstaller"
echo ""

# --- 1. Stop and unload LaunchAgent ---
echo "[1/4] Stopping LaunchAgent..."
if launchctl list "$PLIST_NAME" &>/dev/null 2>&1; then
    launchctl unload "$LAUNCH_AGENTS_DIR/$PLIST_NAME.plist" 2>/dev/null || true
    echo "  Service stopped."
else
    echo "  Service not running."
fi

# --- 2. Remove LaunchAgent plist ---
echo "[2/4] Removing LaunchAgent plist..."
if [ -f "$LAUNCH_AGENTS_DIR/$PLIST_NAME.plist" ]; then
    rm "$LAUNCH_AGENTS_DIR/$PLIST_NAME.plist"
    echo "  Removed: $LAUNCH_AGENTS_DIR/$PLIST_NAME.plist"
else
    echo "  Not found (already removed)."
fi

# --- 3. Remove cal-tools binary ---
echo "[3/4] Removing cal-tools binary..."
if [ -f "$HOME_DIR/.local/bin/cal-tools" ]; then
    rm "$HOME_DIR/.local/bin/cal-tools"
    echo "  Removed: $HOME_DIR/.local/bin/cal-tools"
else
    echo "  Not found (already removed)."
fi

# --- 4. Remove MCP server and data ---
echo "[4/4] Removing MCP server files..."
DATA_DIR="$HOME_DIR/.local/share/calendar-mcp"
if [ -d "$DATA_DIR" ]; then
    rm -rf "$DATA_DIR"
    echo "  Removed: $DATA_DIR"
else
    echo "  Not found (already removed)."
fi

echo ""
echo "==> Uninstall complete."
echo ""
echo "Note: The fastmcp Python package was not removed."
echo "  To remove it: pip3 uninstall fastmcp"
echo ""
