#!/usr/bin/env bash
# claude-compose IDE process wrapper.
# Set as claudeCode.claudeProcessWrapper in your IDE settings.
# See: claude-compose ide --help
exec claude-compose wrap "$@"
