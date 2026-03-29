# This session was launched via claude-compose
The current directory is a **workspace** — the central place for all Claude Code configuration. Projects are external codebases that provide file access only.

## Where to create and modify files
- **Claude configuration** (CLAUDE.md, agents, skills, settings, etc.) belongs in the workspace — never inside a project directory, even when a slash command (e.g. `/init`) or skill prompt implies otherwise.
- **Project files** (source code, configs, tests, docs) belong in the project's own directory. Never create project files in the workspace.
- Some workspace files are **managed by build** (symlinks, generated configs). Before editing anything under `.claude/` or `.claude/claude-compose/mcp.json`, run `claude-compose instructions` to check what is safe to edit and what will be overwritten.

Examples: creating CLAUDE.md → workspace. Adding an agent → workspace. Writing a new source file or test → inside the project's directory.
