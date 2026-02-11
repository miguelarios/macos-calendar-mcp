#!/bin/bash
set -euo pipefail

# Calendar MCP Server — Installer
# Compiles the Swift CLI, installs the MCP server, and sets up the LaunchAgent.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="$HOME"

BIN_DIR="$HOME_DIR/.local/bin"
DATA_DIR="$HOME_DIR/.local/share/calendar-mcp"
LOG_DIR="$DATA_DIR/logs"
LAUNCH_AGENTS_DIR="$HOME_DIR/Library/LaunchAgents"
PLIST_NAME="com.local.calendar-mcp"

echo "==> Calendar MCP Server Installer"
echo ""

# --- 1. Create directories ---
echo "[1/7] Creating directories..."
mkdir -p "$BIN_DIR"
mkdir -p "$DATA_DIR"
mkdir -p "$LOG_DIR"
mkdir -p "$LAUNCH_AGENTS_DIR"

# --- 2. Compile Swift binary ---
echo "[2/7] Compiling cal-tools.swift..."
if ! command -v swiftc &>/dev/null; then
    echo "ERROR: swiftc not found. Install Xcode or Xcode Command Line Tools."
    echo "  xcode-select --install"
    exit 1
fi
swiftc "$SCRIPT_DIR/cal-tools.swift" -o "$BIN_DIR/cal-tools"
echo "  Installed: $BIN_DIR/cal-tools"

# --- 3. Copy MCP server ---
echo "[3/7] Installing MCP server..."
cp "$SCRIPT_DIR/calendar_mcp_server.py" "$DATA_DIR/calendar_mcp_server.py"
echo "  Installed: $DATA_DIR/calendar_mcp_server.py"

# --- 4. Install Python dependency ---
echo "[4/7] Installing Python dependencies..."
if command -v pip3 &>/dev/null; then
    pip3 install --quiet fastmcp
elif command -v pip &>/dev/null; then
    pip install --quiet fastmcp
else
    echo "WARNING: pip not found. Install fastmcp manually: pip install fastmcp"
fi

# --- 5. Install LaunchAgent plist (expand HOMEDIR placeholder) ---
echo "[5/7] Installing LaunchAgent..."
# Unload existing agent if present
if launchctl list "$PLIST_NAME" &>/dev/null 2>&1; then
    launchctl unload "$LAUNCH_AGENTS_DIR/$PLIST_NAME.plist" 2>/dev/null || true
fi
# Substitute HOMEDIR with actual home path and install
sed "s|HOMEDIR|$HOME_DIR|g" "$SCRIPT_DIR/$PLIST_NAME.plist" \
    > "$LAUNCH_AGENTS_DIR/$PLIST_NAME.plist"
echo "  Installed: $LAUNCH_AGENTS_DIR/$PLIST_NAME.plist"

# --- 6. Load LaunchAgent ---
echo "[6/7] Loading LaunchAgent..."
launchctl load "$LAUNCH_AGENTS_DIR/$PLIST_NAME.plist"
echo "  Service loaded: $PLIST_NAME"

# --- 7. Trigger TCC prompt and verify ---
echo "[7/7] Verifying installation..."
echo ""

# Run cal-tools once to trigger the TCC calendar access prompt
echo "  Running 'cal-tools calendars' to trigger calendar permission prompt..."
echo "  (If this is the first run, macOS will ask you to grant calendar access.)"
echo ""
if "$BIN_DIR/cal-tools" calendars >/dev/null 2>&1; then
    echo "  cal-tools: OK"
else
    echo "  cal-tools: Calendar access may have been denied."
    echo "  Grant access in: System Settings > Privacy & Security > Calendars"
fi

# Check if MCP server is responding
sleep 2
if curl -s --max-time 5 "http://127.0.0.1:9876/sse" >/dev/null 2>&1; then
    echo "  MCP server: OK (http://127.0.0.1:9876/sse)"
else
    echo "  MCP server: Not responding yet. Check logs at:"
    echo "    $LOG_DIR/stdout.log"
    echo "    $LOG_DIR/stderr.log"
fi

echo ""
echo "==> Installation complete!"
echo ""
echo "Add to your MCP client config:"
echo ""
echo "  Goose (~/.config/goose/config.yaml):"
echo "    extensions:"
echo "      calendar:"
echo "        type: sse"
echo "        uri: http://localhost:9876/sse"
echo ""
echo "  Claude Code (MCP settings):"
echo '    {"mcpServers": {"calendar": {"type": "sse", "url": "http://localhost:9876/sse"}}}'
echo ""
