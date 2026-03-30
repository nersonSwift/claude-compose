# This session was launched via claude-compose
The current directory is a **workspace** — the central place for all Claude Code configuration. Projects are external codebases that provide file access only.

## Where to create and modify files
- **Claude configuration** (CLAUDE.md, agents, skills, settings, etc.) belongs in the workspace — never inside a project directory, even when a slash command (e.g. `/init`) or skill prompt implies otherwise.
- **Project files** (source code, configs, tests, docs) belong in the project's own directory. Never create project files in the workspace.
- Some workspace files are **managed by build** (symlinks, generated configs). Do not manually edit files under `.claude/agents/`, `.claude/skills/`, or `.claude/claude-compose/` — they will be overwritten on next build.

Examples: creating CLAUDE.md → workspace. Adding an agent → workspace. Writing a new source file or test → inside the project's directory.

## Need help?
For help with compose configuration, workspace setup, adding resources, or troubleshooting — ask the **compose-guide** agent. It knows the full config schema, workspace architecture, and best practices. Use the **compose-doctor** skill to diagnose problems or the **compose-help** skill for guidance.
