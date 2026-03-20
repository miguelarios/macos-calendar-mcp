"""
Calendar MCP Server

A FastMCP server that exposes macOS calendar operations via Streamable HTTP transport.
Delegates all EventKit work to the compiled `cal-tools` Swift binary.
"""

import json
import os
import subprocess

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError

HOST = "127.0.0.1"
PORT = int(os.environ.get("CALENDAR_MCP_PORT", "9876"))
CAL_TOOLS = os.environ.get(
    "CAL_TOOLS_PATH", os.path.expanduser("~/.local/bin/cal-tools")
)

mcp = FastMCP("Calendar")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def run_cal_tools(*args: str) -> dict:
    """Run the cal-tools binary and return parsed JSON output."""
    if not os.path.isfile(CAL_TOOLS):
        raise ToolError(
            json.dumps({"error": "backend_error", "message": f"cal-tools binary not found at {CAL_TOOLS}. Run install.sh or set CAL_TOOLS_PATH."})
        )

    try:
        result = subprocess.run(
            [CAL_TOOLS, *args],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except subprocess.TimeoutExpired:
        raise ToolError(
            json.dumps({"error": "backend_error", "message": "cal-tools timed out after 30 seconds."})
        )
    except OSError as exc:
        raise ToolError(
            json.dumps({"error": "backend_error", "message": f"Failed to execute cal-tools: {exc}"})
        )

    if result.returncode != 0:
        # cal-tools writes structured JSON error to stderr
        if result.stderr.strip():
            try:
                err = json.loads(result.stderr)
                raise ToolError(json.dumps(err))
            except json.JSONDecodeError:
                raise ToolError(
                    json.dumps({"error": "backend_error", "message": result.stderr.strip()})
                )
        raise ToolError(
            json.dumps({"error": "backend_error", "message": "cal-tools exited with an error."})
        )

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        raise ToolError(
            json.dumps({"error": "backend_error", "message": f"Unexpected output from cal-tools: {result.stdout[:500]}"})
        )


# ---------------------------------------------------------------------------
# MCP Tools
# ---------------------------------------------------------------------------


@mcp.tool()
def list_calendars() -> dict:
    """List all calendars across all configured providers. Returns provider-prefixed IDs (e.g., Google/Personal)."""
    return run_cal_tools("calendars")


@mcp.tool()
def list_events(
    start: str, end: str, calendar: str = "", detail_level: str = "summary"
) -> dict:
    """Query events in a date range. Recurring events are expanded into individual instances.

    Args:
        start: Start of date range (ISO 8601).
        end: End of date range (ISO 8601).
        calendar: Provider-prefixed calendar ID (e.g., Google/Personal). If omitted, queries all calendars.
        detail_level: Response verbosity (default: summary).
    """
    args = ["events", "--from", start, "--to", end]
    if calendar:
        args.extend(["--calendar", calendar])
    if detail_level == "full":
        args.extend(["--detail", "full"])
    else:
        args.extend(["--detail", "summary"])
    return run_cal_tools(*args)


@mcp.tool()
def get_today_events(calendar: str = "", detail_level: str = "summary") -> dict:
    """Get all events for today. Convenience wrapper over list_events.

    Args:
        calendar: Provider-prefixed calendar ID. If omitted, queries all calendars.
        detail_level: Response verbosity (default: summary).
    """
    args = ["events", "--today"]
    if calendar:
        args.extend(["--calendar", calendar])
    if detail_level == "full":
        args.extend(["--detail", "full"])
    else:
        args.extend(["--detail", "summary"])
    return run_cal_tools(*args)


@mcp.tool()
def search_events(
    query: str,
    calendar: str = "",
    start: str = "",
    end: str = "",
    detail_level: str = "summary",
) -> dict:
    """Keyword search across event title, description, and location.

    Args:
        query: Search term.
        calendar: Provider-prefixed calendar ID. If omitted, searches all calendars.
        start: Range start (ISO 8601). Defaults to 90 days ago.
        end: Range end (ISO 8601). Defaults to 90 days ahead.
        detail_level: Response verbosity (default: summary).
    """
    args = ["search", "--query", query]
    if calendar:
        args.extend(["--calendar", calendar])
    if start:
        args.extend(["--from", start])
    if end:
        args.extend(["--to", end])
    if detail_level == "full":
        args.extend(["--detail", "full"])
    else:
        args.extend(["--detail", "summary"])
    return run_cal_tools(*args)


@mcp.tool()
def get_event(calendar: str, uid: str) -> dict:
    """Get full details of a single event by calendar and UID.

    Args:
        calendar: Provider-prefixed calendar ID.
        uid: Event UID.
    """
    return run_cal_tools("event", "--id", uid)


@mcp.tool()
def create_event(
    calendar: str,
    title: str,
    start: str,
    end: str,
    all_day: bool = False,
    location: str = "",
    description: str = "",
    attendees: list[dict] | None = None,
) -> dict:
    """Create a new calendar event.

    Args:
        calendar: Provider-prefixed calendar ID.
        title: Event title.
        start: Start time (ISO 8601).
        end: End time (ISO 8601).
        all_day: All-day event flag (default: false).
        location: Event location.
        description: Event description.
        attendees: List of attendees (not yet supported — raises error if provided).
    """
    if attendees:
        raise ToolError(
            json.dumps({"error": "not_implemented", "message": "attendees is not yet supported by this backend."})
        )
    args = ["create", "--title", title, "--start", start, "--end", end]
    if calendar:
        args.extend(["--calendar", calendar])
    if location:
        args.extend(["--location", location])
    if description:
        args.extend(["--description", description])
    args.extend(["--all-day", str(all_day).lower()])
    return run_cal_tools(*args)


@mcp.tool()
def update_event(
    calendar: str,
    uid: str,
    title: str = "",
    start: str = "",
    end: str = "",
    all_day: bool | None = None,
    location: str = "",
    description: str = "",
    attendees: list[dict] | None = None,
    span: str = "this",
) -> dict:
    """Update an existing event. Only provided fields are changed.

    Args:
        calendar: Provider-prefixed calendar ID.
        uid: Event UID to update.
        title: New event title.
        start: New start time (ISO 8601).
        end: New end time (ISO 8601).
        all_day: All-day event flag.
        location: New location.
        description: New description.
        attendees: New attendee list (replaces existing; not yet supported — raises error if provided).
        span: Recurring event scope (default: this).
    """
    if attendees:
        raise ToolError(
            json.dumps({"error": "not_implemented", "message": "attendees is not yet supported by this backend."})
        )
    args = ["update", "--id", uid]
    if title:
        args.extend(["--title", title])
    if start:
        args.extend(["--start", start])
    if end:
        args.extend(["--end", end])
    if calendar:
        args.extend(["--calendar", calendar])
    if location:
        args.extend(["--location", location])
    if description:
        args.extend(["--description", description])
    if all_day is not None:
        args.extend(["--all-day", str(all_day).lower()])
    if span in ("future", "all"):
        args.extend(["--span", span])
    return run_cal_tools(*args)


@mcp.tool()
def delete_event(calendar: str, uid: str, span: str = "all") -> dict:
    """Delete a calendar event by UID.

    Args:
        calendar: Provider-prefixed calendar ID.
        uid: Event UID to delete.
        span: Recurring event scope (default: all).
    """
    args = ["delete", "--id", uid]
    if span in ("this", "future"):
        args.extend(["--span", span])
    else:
        args.extend(["--span", "all"])
    return run_cal_tools(*args)


@mcp.tool()
def find_free_slots(
    start: str,
    end: str,
    duration: int,
    calendars: list[str] | None = None,
    preferred_start: str = "08:00",
    preferred_end: str = "17:00",
    exclude_calendars: list[str] | None = None,
    include_all_day_as_busy: bool = False,
    ignore_tentative: bool = False,
) -> dict:
    """Find available time slots across specified calendars. Returns free windows matching the requested duration.

    Args:
        start: Start of search range (ISO 8601).
        end: End of search range (ISO 8601).
        duration: Minimum slot duration in minutes.
        calendars: Provider-prefixed calendar IDs to check availability against. If omitted, uses all calendars.
        preferred_start: Preferred earliest time (HH:MM, e.g., 08:00).
        preferred_end: Preferred latest time (HH:MM, e.g., 17:00).
        exclude_calendars: Calendar IDs to exclude from busy time calculation.
        include_all_day_as_busy: Treat all-day events as busy (default: false).
        ignore_tentative: If true, tentative events don't block slots (default: false).
    """
    args = ["availability", "--from", start, "--to", end, "--duration", str(duration)]
    if calendars:
        args.extend(["--calendars", ",".join(calendars)])
    elif exclude_calendars:
        args.extend(["--exclude-calendars", ",".join(exclude_calendars)])
    args.extend(["--preferred-start", preferred_start])
    args.extend(["--preferred-end", preferred_end])
    if include_all_day_as_busy:
        args.append("--include-all-day-as-busy")
    if ignore_tentative:
        args.append("--ignore-tentative")
    return run_cal_tools(*args)


@mcp.tool()
def create_events_batch(
    calendar: str,
    events: list[dict],
) -> dict:
    """Create multiple events at once. Returns created event count.

    Args:
        calendar: Provider-prefixed calendar ID.
        events: Array of events to create.
    """
    created = []
    errors = []
    for i, ev in enumerate(events):
        title = ev.get("title")
        ev_start = ev.get("start")
        ev_end = ev.get("end")
        if not title or not ev_start or not ev_end:
            errors.append({"index": i, "error": "validation_error", "message": "Event must have 'title', 'start', and 'end'."})
            continue
        args = ["create", "--title", title, "--start", ev_start, "--end", ev_end]
        args.extend(["--calendar", calendar])
        if ev.get("location"):
            args.extend(["--location", ev["location"]])
        if ev.get("description"):
            args.extend(["--description", ev["description"]])
        args.extend(["--all-day", str(ev.get("all_day", False)).lower()])
        try:
            result = run_cal_tools(*args)
            created.append(result.get("event", result))
        except ToolError as e:
            try:
                err = json.loads(str(e))
                err["index"] = i
                errors.append(err)
            except json.JSONDecodeError:
                errors.append({"index": i, "error": "backend_error", "message": str(e)})
    result = {"created": len(created), "events": created}
    if errors:
        result["errors"] = errors
    return result


@mcp.tool()
def import_ics(calendar: str, ics_content: str) -> dict:
    """Import events from iCalendar (.ics) content into a calendar.

    Args:
        calendar: Provider-prefixed calendar ID.
        ics_content: Raw iCalendar content string.
    """
    raise ToolError(
        json.dumps({"error": "not_implemented", "message": "import_ics is not yet supported by this backend."})
    )


# ---------------------------------------------------------------------------
# Non-standard convenience tools (not part of unified spec)
# ---------------------------------------------------------------------------


@mcp.tool()
def get_upcoming_events(
    days: int = 7, calendar: str = "", detail_level: str = "summary"
) -> dict:
    """Get events for the next N days (including today). Non-standard convenience tool.

    Args:
        days: Number of days to look ahead (default 7).
        calendar: Provider-prefixed calendar ID. If omitted, queries all calendars.
        detail_level: Response verbosity (default: summary).
    """
    args = ["events", "--days", str(max(1, days))]
    if calendar:
        args.extend(["--calendar", calendar])
    if detail_level == "full":
        args.extend(["--detail", "full"])
    else:
        args.extend(["--detail", "summary"])
    return run_cal_tools(*args)


@mcp.tool()
def get_past_events(
    days: int = 30, calendar: str = "", detail_level: str = "summary"
) -> dict:
    """Get events from the past N days (up to and including today). Non-standard convenience tool.

    Args:
        days: Number of days to look back (default 30).
        calendar: Provider-prefixed calendar ID. If omitted, queries all calendars.
        detail_level: Response verbosity (default: summary).
    """
    args = ["events", "--past-days", str(max(1, days))]
    if calendar:
        args.extend(["--calendar", calendar])
    if detail_level == "full":
        args.extend(["--detail", "full"])
    else:
        args.extend(["--detail", "summary"])
    return run_cal_tools(*args)


if __name__ == "__main__":
    mcp.run(transport="streamable-http", host=HOST, port=PORT)
