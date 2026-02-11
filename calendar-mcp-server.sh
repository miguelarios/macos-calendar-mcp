#!/bin/bash
# Wrapper script for Calendar MCP Server
# This gives the background activity a recognizable name in macOS.
exec "$(dirname "$0")/venv/bin/python3" "$(dirname "$0")/calendar_mcp_server.py" "$@"
