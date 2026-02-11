# Calendar MCP Server

A standalone MCP (Model Context Protocol) server that gives AI coding agents access to macOS Calendar data — without per-agent TCC patching.

## The Problem

macOS TCC (Transparency, Consent, and Control) prevents GUI-based coding agents (Goose, Claude Code, Codex, VS Code extensions) from accessing calendar data. The GUI app's process lacks the `com.apple.security.personal-information.calendars` entitlement, so EventKit calls silently fail. Every agent has this problem, and fixing it means patching each one individually.

## The Solution

Run the calendar service as its own process — a macOS LaunchAgent with its own TCC context. Any MCP-compatible agent connects over `localhost:9876` via SSE. No per-agent patches needed.

```
Agent (Goose, Claude Code, etc.)
  │
  │ SSE (localhost:9876)
  ▼
FastMCP Server (Python)
  │
  │ subprocess
  ▼
cal-tools (Swift/EventKit)
  │
  ▼
macOS Calendar database
```

## Quick Start

```bash
git clone https://github.com/miguelarios/macos-calendar-mcp.git
cd macos-calendar-mcp
./install.sh
```

The installer will:
1. Compile the Swift CLI binary (`cal-tools`)
2. Install the FastMCP server
3. Set up a LaunchAgent (auto-starts on login, restarts on crash)
4. Install the `fastmcp` Python package
5. Trigger the macOS calendar permission prompt

## Agent Configuration

Once running, add to your agent's MCP config:

**Goose** (`~/.config/goose/config.yaml`):

```yaml
extensions:
  calendar:
    type: sse
    uri: http://localhost:9876/sse
```

**Claude Code** (MCP settings):

```json
{
  "mcpServers": {
    "calendar": {
      "type": "sse",
      "url": "http://localhost:9876/sse"
    }
  }
}
```

## Available Tools

| Tool | Description |
|------|-------------|
| `list_calendars` | List all macOS calendars |
| `get_events` | Get events in a date range |
| `get_today_events` | Today's events |
| `get_upcoming_events` | Events for next N days |
| `get_past_events` | Events from past N days |
| `search_events` | Search by keyword in title/notes/location |
| `get_event` | Get a single event by ID |
| `create_event` | Create a new event |
| `update_event` | Update an existing event |
| `delete_event` | Delete an event |

## Using cal-tools Directly

The Swift binary can be used standalone from Terminal:

```bash
# List calendars
cal-tools calendars

# Today's events
cal-tools events --today

# Next 7 days
cal-tools events --days 7

# Date range
cal-tools events --from 2026-01-01 --to 2026-03-01

# Past 30 days
cal-tools events --past-days 30

# Search
cal-tools search --query "standup"

# Create an event
cal-tools create \
  --title "Meeting" \
  --start "2026-02-15T10:00:00" \
  --end "2026-02-15T11:00:00" \
  --calendar "Work" \
  --location "Room 4"

# Update an event
cal-tools update --id "EVENT_ID" --title "New Title"

# Delete an event
cal-tools delete --id "EVENT_ID"

# Delete this and all future occurrences of a recurring event
cal-tools delete --id "EVENT_ID" --span future
```

All output is JSON. Errors go to stderr with a non-zero exit code.

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `CAL_TOOLS_PATH` | `~/.local/bin/cal-tools` | Path to the compiled Swift binary |
| `CALENDAR_MCP_PORT` | `9876` | Port for the MCP SSE server |

## File Layout

```
macos-calendar-mcp/
├── cal-tools.swift              # Swift CLI — all EventKit operations
├── calendar_mcp_server.py       # FastMCP server — MCP protocol layer
├── com.miguel.calendar-mcp.plist # LaunchAgent template
├── install.sh                   # Compile, install, and start
├── uninstall.sh                 # Stop and remove everything
└── README.md
```

After installation:

```
~/.local/bin/cal-tools                              # Compiled binary
~/.local/share/calendar-mcp/calendar_mcp_server.py  # Server script
~/.local/share/calendar-mcp/logs/                    # stdout/stderr logs
~/Library/LaunchAgents/com.miguel.calendar-mcp.plist # LaunchAgent
```

## Uninstalling

```bash
./uninstall.sh
```

Stops the service and removes all installed files. The `fastmcp` Python package is left in place (remove manually with `pip3 uninstall fastmcp` if desired).

## Notes

- The Swift binary must be compiled on the Mac where it will run (architecture-specific).
- If recompiled to a different path, macOS will re-prompt for calendar access.
- The server binds to `127.0.0.1` only — never exposed to the network.
- LaunchAgent plists don't expand `~` — the install script handles this.
- For recurring events, `update` and `delete` accept `--span future` to affect all future occurrences (default is only the current occurrence).
