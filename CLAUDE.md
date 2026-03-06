# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

macOS Calendar MCP Server — gives AI agents (Claude Code, Goose, etc.) access to macOS calendar data via the Model Context Protocol, without requiring per-agent TCC patching.

**Architecture:**
```
AI Agent → Streamable HTTP (localhost:9876/mcp) → FastMCP Server (Python) → subprocess → cal-tools (Swift/EventKit) → macOS Calendar
```

## Key Files

- **cal-tools.swift** — Swift CLI wrapping EventKit for all calendar read/write operations. All output is JSON.
- **calendar_mcp_server.py** — FastMCP server exposing 10 MCP tools over Streamable HTTP. Calls cal-tools as a subprocess.
- **com.local.calendar-mcp.plist** — LaunchAgent template (uses `HOMEDIR` placeholder replaced at install time).
- **install.sh / uninstall.sh** — Install and cleanup scripts.

## Build & Install

```bash
# Full install (compile Swift, set up Python venv, register LaunchAgent)
./install.sh

# Uninstall everything
./uninstall.sh
```

### Compile Swift binary only
```bash
swiftc cal-tools.swift -o ~/.local/bin/cal-tools
```

### Run MCP server manually (for development)
```bash
CAL_TOOLS_PATH=~/.local/bin/cal-tools CALENDAR_MCP_PORT=9876 python3 calendar_mcp_server.py
```

### Test cal-tools CLI directly
```bash
cal-tools calendars
cal-tools events --today
cal-tools events --days 7
cal-tools search --query "standup"
cal-tools create --title "Test" --start "2025-01-15T10:00:00" --end "2025-01-15T11:00:00"
cal-tools availability --from 2026-03-09 --to 2026-03-11 --duration 30 --preferred-start 08:00 --preferred-end 17:00
```

### Check server status
```bash
macos-calendar-mcp status
```

## Installation Layout

```
~/.local/bin/cal-tools                    # Compiled Swift binary
~/.local/share/calendar-mcp/
  ├── calendar_mcp_server.py              # Server script
  ├── venv/                               # Python venv with fastmcp
  └── logs/{stdout,stderr}.log            # Server logs
~/Library/LaunchAgents/com.local.calendar-mcp.plist
```

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `CAL_TOOLS_PATH` | `~/.local/bin/cal-tools` | Path to Swift binary |
| `CALENDAR_MCP_PORT` | `9876` | Server port |

## Architecture Notes

- The Python server is a thin wrapper — all calendar logic lives in the Swift binary.
- The plist uses `HOMEDIR` as a placeholder since plist files don't expand `~`. The installer substitutes it with `sed`.
- Server binds to `127.0.0.1` only (never exposed to network).
- LaunchAgent auto-restarts the server on crash (`KeepAlive.SuccessfulExit: false`).
- The Swift binary needs its own TCC calendar permission — first run triggers the macOS prompt.
