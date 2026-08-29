# Calendar MCP Server

A standalone MCP (Model Context Protocol) server that gives AI coding agents access to macOS Calendar data — without per-agent TCC patching.

## The Problem

macOS TCC (Transparency, Consent, and Control) prevents GUI-based coding agents (Goose, Claude Code, Codex, VS Code extensions) from accessing calendar data. The GUI app's process lacks the `com.apple.security.personal-information.calendars` entitlement, so EventKit calls silently fail. Every agent has this problem, and fixing it means patching each one individually.

## The Solution

Run the calendar service as its own process — a macOS LaunchAgent with its own TCC context. Any MCP-compatible agent connects over `localhost:9876` via Streamable HTTP. No per-agent patches needed.

```
Agent (Goose, Claude Code, etc.)
  │
  │ Streamable HTTP (localhost:9876)
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

### Homebrew (recommended)

```bash
brew install --HEAD miguelarios/tap/macos-calendar-mcp
brew services start macos-calendar-mcp
cal-tools calendars  # triggers macOS calendar permission prompt
```

Check status anytime:

```bash
macos-calendar-mcp status
```

### Manual Install

```bash
git clone https://github.com/miguelarios/macos-calendar-mcp.git
cd macos-calendar-mcp
./install.sh
```

The manual installer will:
1. Compile the Swift CLI binary (`cal-tools`)
2. Install the FastMCP server
3. Set up a LaunchAgent (auto-starts on login, restarts on crash)
4. Install the `fastmcp` Python package
5. Trigger the macOS calendar permission prompt

## MCP Protocol

Transport is **Streamable HTTP** on `127.0.0.1:9876/mcp`. The server is never exposed to the
network, and there is no authorization layer — access control is the loopback bind plus macOS
TCC on the `cal-tools` binary.

`install.sh` pins **`fastmcp>=3.4.5,<4`**. The upper bound is deliberate. FastMCP 4 is the
first release to serve MCP revision `2026-07-28` (the sessionless protocol), and it carries
breaking changes — server-side sampling and roots removed, 3.x compatibility shims dropped,
SDK field names renamed from camelCase to snake_case. Because this server runs as an
unattended LaunchAgent, an unpinned dependency would land a major version on users during a
routine reinstall. The pin will be lifted deliberately once FastMCP 4 is stable.

Nothing here uses a feature deprecated by `2026-07-28`: no Roots, no Sampling, no MCP Logging
(the LaunchAgent logs to stderr), and no HTTP+SSE transport.

## Agent Configuration

Once running, add to your agent's MCP config:

**Goose** (`~/.config/goose/config.yaml`):

```yaml
extensions:
  calendar:
    type: streamable_http
    uri: http://localhost:9876/mcp
```

**Claude Code** (MCP settings):

```json
{
  "mcpServers": {
    "calendar": {
      "type": "streamable-http",
      "url": "http://localhost:9876/mcp"
    }
  }
}
```

**Claude Desktop** (MCP settings):

```json
{
  "mcpServers": {
    "calendar": {
      "command": "npx",
      "args": [
        "mcp-remote",
        "http://localhost:9876/mcp"
      ]
    }
  }
}
```

## Available Tools

Every tool carries MCP annotations. The eleven read-only tools are marked `readOnlyHint`, so
clients can skip confirmation prompts on them; `update_event` and `delete_event` are marked
`destructiveHint`. Note that `delete_event` defaults to `span="all"`, which removes *every*
occurrence of a recurring event.

### `get_calendar_change_token`

Check whether the calendar has changed without refetching events.

A background watcher observes macOS for calendar changes — a remote account syncing, an edit
in Calendar.app, another process writing — and increments a `revision` counter. Cache that
counter alongside event results and re-read it before trusting them: if `revision` hasn't
moved, previously fetched events are still current.

```json
{"watching": true, "revision": 3, "last_changed_at": "2026-07-29T10:14:02-07:00", "error": null}
```

If `watching` is `false`, the watcher isn't running, `revision` is not a reliable staleness
signal, and `error` explains why. Set `CALENDAR_MCP_WATCH=0` to disable the watcher entirely.

The same state is exposed as the `calendar://changes` resource.

> **Why polling?** MCP `2026-07-28` replaces `resources/subscribe` with `subscriptions/listen`
> for server-pushed change notifications, which is the natural fit here. It needs FastMCP 4 —
> and the MCP Python SDK currently hardcodes `subscribe=False` in its resource capabilities, so
> FastMCP 3.x cannot serve resource subscriptions at all. The watcher and its state are already
> in place; converting this to a push is a small change once the pin lifts.

*No parameters.*

---

### `list_calendars`

List all calendars across all configured providers. Returns provider-prefixed IDs (e.g., `Google/Personal`).

*No parameters.*

---

### `list_events`

Query events in a date range. Recurring events are expanded into individual instances.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `start` | string | yes | | Start of date range (ISO 8601) |
| `end` | string | yes | | End of date range (ISO 8601) |
| `calendar` | string | no | all | Provider-prefixed calendar ID (e.g., `Google/Personal`) |
| `detail_level` | string | no | `summary` | Response verbosity: `summary` or `full` |

---

### `get_today_events`

Get all events for today. Convenience wrapper over `list_events`.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `calendar` | string | no | all | Provider-prefixed calendar ID |
| `detail_level` | string | no | `summary` | Response verbosity: `summary` or `full` |

---

### `get_upcoming_events`

Get events for the next N days (including today).

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `days` | int | no | `7` | Number of days to look ahead |
| `calendar` | string | no | all | Provider-prefixed calendar ID |
| `detail_level` | string | no | `summary` | Response verbosity: `summary` or `full` |

---

### `get_past_events`

Get events from the past N days (up to and including today).

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `days` | int | no | `30` | Number of days to look back |
| `calendar` | string | no | all | Provider-prefixed calendar ID |
| `detail_level` | string | no | `summary` | Response verbosity: `summary` or `full` |

---

### `search_events`

Keyword search across event title, description, and location.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `query` | string | yes | | Search term |
| `calendar` | string | no | all | Provider-prefixed calendar ID |
| `start` | string | no | 90 days ago | Range start (ISO 8601) |
| `end` | string | no | 90 days ahead | Range end (ISO 8601) |
| `detail_level` | string | no | `summary` | Response verbosity: `summary` or `full` |

---

### `get_event`

Get full details of a single event by calendar and UID.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `calendar` | string | yes | Provider-prefixed calendar ID |
| `uid` | string | yes | Event UID |

---

### `create_event`

Create a new calendar event.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `calendar` | string | yes | | Provider-prefixed calendar ID |
| `title` | string | yes | | Event title |
| `start` | string | yes | | Start time (ISO 8601) |
| `end` | string | yes | | End time (ISO 8601) |
| `all_day` | bool | no | `false` | All-day event flag |
| `location` | string | no | | Event location |
| `description` | string | no | | Event description |

---

### `update_event`

Update an existing event. Only provided fields are changed.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `calendar` | string | yes | | Provider-prefixed calendar ID |
| `uid` | string | yes | | Event UID to update |
| `title` | string | no | | New event title |
| `start` | string | no | | New start time (ISO 8601) |
| `end` | string | no | | New end time (ISO 8601) |
| `all_day` | bool | no | | All-day event flag |
| `location` | string | no | | New location |
| `description` | string | no | | New description |
| `span` | string | no | `this` | Recurring event scope: `this`, `future`, or `all` |

---

### `delete_event`

Delete a calendar event by UID.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `calendar` | string | yes | | Provider-prefixed calendar ID |
| `uid` | string | yes | | Event UID to delete |
| `span` | string | no | `all` | Recurring event scope: `this`, `future`, or `all` |

---

### `find_free_slots`

Find available time slots across specified calendars. Returns free windows matching the requested duration.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `start` | string | yes | | Start of search range (ISO 8601) |
| `end` | string | yes | | End of search range (ISO 8601) |
| `duration` | int | yes | | Minimum slot duration in minutes |
| `calendars` | list[string] | no | all | Calendar IDs to check availability against |
| `preferred_start` | string | no | `08:00` | Preferred earliest time (HH:MM) |
| `preferred_end` | string | no | `17:00` | Preferred latest time (HH:MM) |
| `exclude_calendars` | list[string] | no | | Calendar IDs to exclude from busy time |
| `include_all_day_as_busy` | bool | no | `false` | Treat all-day events as busy |
| `ignore_tentative` | bool | no | `false` | Tentative events don't block slots |

---

### `create_events_batch`

Create multiple events at once. Returns created event count and any errors.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `calendar` | string | yes | Provider-prefixed calendar ID |
| `events` | list[object] | yes | Array of event objects (each with `title`, `start`, `end`, and optional `location`, `description`, `all_day`) |

---

### `import_ics`

Import events from iCalendar (.ics) content into a calendar. **Not yet implemented.**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `calendar` | string | yes | Provider-prefixed calendar ID |
| `ics_content` | string | yes | Raw iCalendar content string |

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
  --location "Room 4" \
  --description "Quarterly sync"

# Update an event
cal-tools update --id "EVENT_ID" --title "New Title"

# Delete an event (default: all occurrences if recurring)
cal-tools delete --id "EVENT_ID"

# Delete only this occurrence of a recurring event
cal-tools delete --id "EVENT_ID" --span this

# Delete this and all future occurrences
cal-tools delete --id "EVENT_ID" --span future

# Find free 30-minute slots
cal-tools availability --from 2026-03-09 --to 2026-03-11 --duration 30 \
  --preferred-start 08:00 --preferred-end 17:00
```

All output is JSON. Errors go to stderr with a non-zero exit code.

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `CAL_TOOLS_PATH` | `~/.local/bin/cal-tools` | Path to the compiled Swift binary |
| `CALENDAR_MCP_PORT` | `9876` | Port for the MCP server |

## Managing the Server

```bash
macos-calendar-mcp status    # Check if server is running
macos-calendar-mcp start     # Start (load) the LaunchAgent
macos-calendar-mcp stop      # Stop (unload) the LaunchAgent
macos-calendar-mcp restart   # Restart the LaunchAgent
macos-calendar-mcp logs      # Tail recent stdout/stderr logs
```

## File Layout

```
macos-calendar-mcp/
├── cal-tools.swift              # Swift CLI — all EventKit operations
├── calendar_mcp_server.py       # FastMCP server — MCP protocol layer
├── calendar-mcp-server.sh       # LaunchAgent wrapper script
├── macos-calendar-mcp.sh        # CLI for status/start/stop/restart/logs
├── com.local.calendar-mcp.plist # LaunchAgent template
├── install.sh                   # Compile, install, and start
├── uninstall.sh                 # Stop and remove everything
└── README.md
```

After installation:

```
~/.local/bin/cal-tools                              # Compiled binary
~/.local/share/calendar-mcp/calendar_mcp_server.py  # Server script
~/.local/share/calendar-mcp/logs/                    # stdout/stderr logs
~/Library/LaunchAgents/com.local.calendar-mcp.plist  # LaunchAgent
```

## Uninstalling

**Homebrew:**

```bash
brew services stop macos-calendar-mcp
brew uninstall macos-calendar-mcp
```

**Manual install:**

```bash
./uninstall.sh
```

Stops the service and removes all installed files.

## macOS Permissions

After installation, you'll see two entries in System Settings:

- **General > Login Items & Extensions > Background Activity** — shows **`calendar-mcp-server`** (the LaunchAgent wrapper script).
- **Privacy & Security > Calendars** — shows **`python3`** (e.g. `python3.14`). This is the Python binary from the virtual environment. macOS attributes calendar access to the parent process that spawns `cal-tools`, even though `cal-tools` (Swift) is the one using EventKit. Both entries are expected and required.

## Notes

- The Swift binary must be compiled on the Mac where it will run (architecture-specific).
- If recompiled to a different path, macOS will re-prompt for calendar access.
- The server binds to `127.0.0.1` only — never exposed to the network.
- LaunchAgent plists don't expand `~` — the install script handles this.
- For recurring events, `update` and `delete` accept `--span` with values `this` (single occurrence), `future` (this and all future), or `all` (every occurrence). `update` defaults to `this`; `delete` defaults to `all`.
