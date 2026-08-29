"""Tests for the Calendar MCP server's protocol surface.

These run on any platform: nothing here needs macOS, EventKit, or the compiled binary.
The Swift side is compile-checked by the macOS job in .github/workflows/ci.yml.
"""

import asyncio
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import calendar_mcp_server as srv  # noqa: E402

EXPECTED_TOOLS = {
    # read-only
    "get_calendar_change_token": True,
    "list_calendars": True,
    "list_events": True,
    "get_today_events": True,
    "search_events": True,
    "get_event": True,
    "find_free_slots": True,
    "get_upcoming_events": True,
    "get_past_events": True,
    # mutating
    "import_ics": False,
    "create_event": False,
    "create_events_batch": False,
    "update_event": False,
    "delete_event": False,
}

DESTRUCTIVE_TOOLS = {"update_event", "delete_event"}


@pytest.fixture(scope="module")
def tools():
    return {t.name: t for t in asyncio.run(srv.mcp.list_tools())}


def test_tool_surface_is_exactly_what_we_expect(tools):
    """Guards the advertised tool list — a rename or accidental drop is a breaking change."""
    assert set(tools) == set(EXPECTED_TOOLS)


def test_every_tool_carries_annotations(tools):
    """Clients rely on these to decide whether a call needs user confirmation."""
    for name, tool in tools.items():
        assert tool.annotations is not None, f"{name} has no annotations"


def test_read_only_hints_match_intent(tools):
    for name, expected_read_only in EXPECTED_TOOLS.items():
        assert tools[name].annotations.readOnlyHint is expected_read_only, name


def test_mutating_tools_are_flagged_destructive_correctly(tools):
    """delete_event defaults to span='all', so mismarking it as safe is dangerous."""
    for name, expected_read_only in EXPECTED_TOOLS.items():
        if expected_read_only:
            continue
        assert tools[name].annotations.destructiveHint is (
            name in DESTRUCTIVE_TOOLS
        ), name


def test_changes_resource_is_registered_and_readable():
    resources = asyncio.run(srv.mcp.list_resources())
    uris = {str(r.uri) for r in resources}
    assert "calendar://changes" in uris

    result = asyncio.run(srv.mcp.read_resource("calendar://changes"))
    payload = json.loads(result.contents[0].content)
    assert set(payload) == {"watching", "revision", "last_changed_at", "error"}


def test_change_token_shape():
    token = srv._change_token()
    assert set(token) == {"watching", "revision", "last_changed_at", "error"}


def test_change_token_is_a_copy_not_the_live_dict():
    """Callers must not be able to mutate watcher state through a returned token."""
    srv._change_token()["revision"] = 999
    assert srv._change_state["revision"] != 999


@pytest.mark.parametrize(
    "stderr,expected",
    [
        ("", "cal-tools watch exited unexpectedly."),
        (
            json.dumps({"error": "permission_denied", "message": "Calendar access denied"}),
            "permission_denied: Calendar access denied",
        ),
        ("segfault", "cal-tools watch exited: segfault"),
    ],
)
def test_watch_failure_descriptions(stderr, expected):
    assert srv._describe_watch_failure(stderr) == expected


def _fake_binary(tmp_path, body: str):
    script = tmp_path / "cal-tools"
    script.write_text("#!/bin/sh\n" + body)
    script.chmod(0o755)
    return str(script)


def _run_watcher(monkeypatch, path, seconds=0.4):
    """Run the watcher against a fake binary for a moment, then cancel and report state."""
    monkeypatch.setattr(srv, "CAL_TOOLS", path)
    srv._change_state.update(
        watching=False, revision=0, last_changed_at=None, error=None
    )

    async def drive():
        task = asyncio.create_task(srv._watch_calendar())
        await asyncio.sleep(seconds)
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        return srv._change_token()

    return asyncio.run(drive())


def test_watcher_folds_ndjson_into_change_token(monkeypatch, tmp_path):
    """A 'changed' record must bump revision and record when it happened."""
    path = _fake_binary(
        tmp_path,
        'echo \'{"type":"watching","revision":0,"at":"2026-07-29T10:00:00-07:00"}\'\n'
        "sleep 0.1\n"
        'echo \'{"type":"changed","revision":1,"at":"2026-07-29T10:00:01-07:00"}\'\n'
        "sleep 5\n",
    )
    state = _run_watcher(monkeypatch, path)
    assert state["watching"] is True
    assert state["revision"] == 1
    assert state["last_changed_at"] == "2026-07-29T10:00:01-07:00"
    assert state["error"] is None


def test_watcher_reports_permission_denial(monkeypatch, tmp_path):
    path = _fake_binary(
        tmp_path,
        'echo \'{"error":"permission_denied","message":"Calendar access denied"}\' >&2\n'
        "exit 1\n",
    )
    state = _run_watcher(monkeypatch, path)
    assert state["watching"] is False
    assert "permission_denied" in state["error"]


def test_watcher_survives_a_missing_binary(monkeypatch):
    """A missing binary must degrade the token, not crash the server."""
    state = _run_watcher(monkeypatch, "/nonexistent/cal-tools", seconds=0.2)
    assert state["watching"] is False
    assert "Failed to start cal-tools watch" in state["error"]


def test_permission_denied_propagates_from_cal_tools(monkeypatch, tmp_path):
    """A TCC denial must surface as permission_denied, not a generic backend_error.

    This is the most common first-run failure, and agents need to branch on the code
    rather than pattern-match the message.
    """
    fake = tmp_path / "cal-tools"
    fake.write_text(
        '#!/bin/sh\n'
        'echo \'{"error":"permission_denied","message":"Calendar access denied"}\' >&2\n'
        'exit 1\n'
    )
    fake.chmod(0o755)
    monkeypatch.setattr(srv, "CAL_TOOLS", str(fake))

    with pytest.raises(srv.ToolError) as excinfo:
        srv.run_cal_tools("calendars")

    assert json.loads(str(excinfo.value))["error"] == "permission_denied"
