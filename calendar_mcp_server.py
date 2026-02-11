"""
Calendar MCP Server

A FastMCP server that exposes macOS calendar operations via SSE/HTTP transport.
Delegates all EventKit work to the compiled `cal-tools` Swift binary.
"""

import json
import os
import subprocess
from datetime import date, timedelta

from fastmcp import FastMCP

HOST = "127.0.0.1"
PORT = int(os.environ.get("CALENDAR_MCP_PORT", "9876"))
CAL_TOOLS = os.environ.get(
    "CAL_TOOLS_PATH", os.path.expanduser("~/.local/bin/cal-tools")
)

mcp = FastMCP("Calendar", host=HOST, port=PORT)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def run_cal_tools(*args: str) -> dict:
    """Run the cal-tools binary and return parsed JSON output."""
    if not os.path.isfile(CAL_TOOLS):
        return {
            "ok": False,
            "error": (
                f"cal-tools binary not found at {CAL_TOOLS}. "
                "Run install.sh or set CAL_TOOLS_PATH."
            ),
        }

    try:
        result = subprocess.run(
            [CAL_TOOLS, *args],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "cal-tools timed out after 30 seconds."}
    except OSError as exc:
        return {"ok": False, "error": f"Failed to execute cal-tools: {exc}"}

    if result.returncode != 0:
        # cal-tools writes JSON to stderr on failure
        if result.stderr.strip():
            try:
                return json.loads(result.stderr)
            except json.JSONDecodeError:
                return {"ok": False, "error": result.stderr.strip()}
        return {"ok": False, "error": "cal-tools exited with an error."}

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return {
            "ok": False,
            "error": f"Unexpected output from cal-tools: {result.stdout[:500]}",
        }


# ---------------------------------------------------------------------------
# MCP Tools
# ---------------------------------------------------------------------------


@mcp.tool()
def list_calendars() -> dict:
    """List all available macOS calendars with their IDs, titles, types, and sources."""
    return run_cal_tools("calendars")


@mcp.tool()
def get_events(from_date: str, to_date: str, calendar: str = "") -> dict:
    """Get calendar events in a date range.

    Args:
        from_date: Start date in ISO 8601 format (YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS).
        to_date: End date in ISO 8601 format.
        calendar: Optional calendar name to filter by.
    """
    args = ["events", "--from", from_date, "--to", to_date]
    if calendar:
        args.extend(["--calendar", calendar])
    return run_cal_tools(*args)


@mcp.tool()
def get_today_events(calendar: str = "") -> dict:
    """Get all events for today.

    Args:
        calendar: Optional calendar name to filter by.
    """
    args = ["events", "--today"]
    if calendar:
        args.extend(["--calendar", calendar])
    return run_cal_tools(*args)


@mcp.tool()
def get_upcoming_events(days: int = 7, calendar: str = "") -> dict:
    """Get events for the next N days (including today).

    Args:
        days: Number of days to look ahead (default 7).
        calendar: Optional calendar name to filter by.
    """
    args = ["events", "--days", str(max(1, days))]
    if calendar:
        args.extend(["--calendar", calendar])
    return run_cal_tools(*args)


@mcp.tool()
def get_past_events(days: int = 30, calendar: str = "") -> dict:
    """Get events from the past N days (up to and including today).

    Args:
        days: Number of days to look back (default 30).
        calendar: Optional calendar name to filter by.
    """
    args = ["events", "--past-days", str(max(1, days))]
    if calendar:
        args.extend(["--calendar", calendar])
    return run_cal_tools(*args)


@mcp.tool()
def search_events(
    query: str, from_date: str = "", to_date: str = ""
) -> dict:
    """Search events by keyword in title, notes, or location.

    Args:
        query: Search keyword.
        from_date: Optional start date (defaults to 90 days ago).
        to_date: Optional end date (defaults to 90 days ahead).
    """
    args = ["search", "--query", query]
    if from_date:
        args.extend(["--from", from_date])
    if to_date:
        args.extend(["--to", to_date])
    return run_cal_tools(*args)


@mcp.tool()
def get_event(event_id: str) -> dict:
    """Get a single event by its ID.

    Args:
        event_id: The EventKit event identifier.
    """
    return run_cal_tools("event", "--id", event_id)


@mcp.tool()
def create_event(
    title: str,
    start: str,
    end: str,
    calendar: str = "",
    location: str = "",
    notes: str = "",
    all_day: bool = False,
) -> dict:
    """Create a new calendar event.

    Args:
        title: Event title.
        start: Start date/time in ISO 8601 format.
        end: End date/time in ISO 8601 format.
        calendar: Optional target calendar name (uses default if omitted).
        location: Optional event location.
        notes: Optional event notes/description.
        all_day: Whether this is an all-day event (default False).
    """
    args = ["create", "--title", title, "--start", start, "--end", end]
    if calendar:
        args.extend(["--calendar", calendar])
    if location:
        args.extend(["--location", location])
    if notes:
        args.extend(["--notes", notes])
    args.extend(["--all-day", str(all_day).lower()])
    return run_cal_tools(*args)


@mcp.tool()
def update_event(
    event_id: str,
    title: str = "",
    start: str = "",
    end: str = "",
    calendar: str = "",
    location: str = "",
    notes: str = "",
    all_day: str = "",
    span: str = "this",
) -> dict:
    """Update an existing calendar event.

    Args:
        event_id: The EventKit event identifier.
        title: New title (leave empty to keep current).
        start: New start date/time in ISO 8601 format (leave empty to keep current).
        end: New end date/time in ISO 8601 format (leave empty to keep current).
        calendar: Move to a different calendar by name (leave empty to keep current).
        location: New location (leave empty to keep current).
        notes: New notes (leave empty to keep current).
        all_day: Set to "true" or "false" (leave empty to keep current).
        span: For recurring events: "this" (default) or "future" (this and all future occurrences).
    """
    args = ["update", "--id", event_id]
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
    if notes:
        args.extend(["--notes", notes])
    if all_day:
        args.extend(["--all-day", all_day])
    if span == "future":
        args.extend(["--span", "future"])
    return run_cal_tools(*args)


@mcp.tool()
def delete_event(event_id: str, span: str = "this") -> dict:
    """Delete a calendar event.

    Args:
        event_id: The EventKit event identifier.
        span: For recurring events: "this" (default) deletes only this occurrence,
              "future" deletes this and all future occurrences.
    """
    args = ["delete", "--id", event_id]
    if span == "future":
        args.extend(["--span", "future"])
    return run_cal_tools(*args)


if __name__ == "__main__":
    mcp.run(transport="sse")
