#!/usr/bin/env bash
set -eEuo pipefail

# claude-compose — Multi-project Claude Code launcher (workspace model)
# Projects provide file access via --add-dir. All Claude configuration
# (MCP, agents, skills, permissions) lives in the workspace directory.
# Plugins contribute shared resources at build time.

VERSION="3.0.1"
