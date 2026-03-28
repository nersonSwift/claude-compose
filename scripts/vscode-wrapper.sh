#!/usr/bin/env bash
# claude-compose VS Code process wrapper.
# Set as claudeCode.claudeProcessWrapper in VS Code settings.
# See: claude-compose vscode --help
exec claude-compose wrap "$@"
