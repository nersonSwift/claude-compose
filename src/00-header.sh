#!/usr/bin/env bash
set -euo pipefail

# claude-compose — Multi-project Claude Code launcher (workspace model)
# Projects provide file access via --add-dir. All Claude configuration
# (MCP, agents, skills, permissions) lives in the workspace directory.
# Presets contribute shared resources at build time.

VERSION="2.1.0"
