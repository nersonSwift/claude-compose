claude-compose is a multi-project workspace launcher (like Docker Compose for Claude Code). It creates a unified working environment where you can work across multiple codebases simultaneously.

### Key concepts

**Workspace directory** — the current working directory. It may contain its own code, or serve purely as a launch point for working with external projects. All Claude configuration (.claude/, .claude/claude-compose/mcp.json, agents, skills, permissions) lives here and is managed by claude-compose.

**Projects** — external codebases added via `--add-dir`. They provide file access (read/write) and optionally their CLAUDE.md instructions. Projects are listed in `claude-compose.json` and referenced by aliases (e.g., `myapp://src/main.ts`).

**Plugins** — reusable Claude Code extensions from marketplaces or local paths. Marketplace plugins are auto-installed via `claude plugins install` and enabled in settings. Local plugins are loaded via `--plugin-dir`.

**Workspaces** — other claude-compose workspaces that can share their configuration (MCP servers, agents, skills) into this one at build time.

**Build** — the process of syncing resources from workspaces/local config and installing marketplace plugins into the workspace's `.claude/` directory and `.claude/claude-compose/mcp.json`. Runs automatically at launch when changes are detected.

**Global config** — `~/.claude-compose/global.json` is an optional file with the same schema as `claude-compose.json`. It is auto-applied to all workspaces. Useful for plugins, MCP servers, agents, or skills you always want available. **Important: global and local configs are processed independently — their arrays (plugins, projects, etc.) are NOT merged. Each is iterated separately at build time.**

### Config schema (claude-compose.json)

```json
{
  "name": "my-workspace",
  "resources": {
    "agents": ["agents/reviewer.md"],
    "skills": ["skills/commit"],
    "mcp": { "server-name": { "command": "...", "args": ["..."] } },
    "env_files": [".env.json"]
  },
  "projects": [
    { "path": "~/Code/my-app", "name": "myapp" },
    { "path": "~/Code/my-lib", "name": "mylib", "claude_md": false }
  ],
  "workspaces": [
    { "path": "~/workspaces/shared", "mcp": { "rename": { "cal": "shared-cal" } } }
  ],
  "plugins": ["ralph-loop", "./local/plugin"]
}
```

Field rules:
- `name` — workspace name (required, filesystem-safe: letters, digits, dots, hyphens, underscores)
- `projects[].path` — path to external project (required)
- `projects[].name` — alias for file references (required)
- `projects[].claude_md` — load CLAUDE.md from project (default: `true`, omit if true)
- `plugins[]` — string (marketplace name or local path) or object {"name": "...", "config": {...}} or {"path": "..."}
- `resources.agents` — array of string paths to agent .md files
- `resources.skills` — array of string paths to skill directories
- `resources.mcp` — object of MCP server configs
- `resources.env_files` — array of string paths to JSON env files
- `marketplaces` — object of marketplace configs, each with "source" and "repo" fields
- `workspaces[].path` — path to source workspace (required)
- `workspaces[].mcp.include/exclude/rename` — MCP server filters
- `workspaces[].agents.include/exclude/rename` — agent filters
- `workspaces[].skills.include/exclude` — skill filters
- `workspace_path` — alternative workspace directory (config and workspace can be in different dirs)
- `resources.append_system_prompt_files` — array of markdown files to append to system prompt
- `resources.settings` — path to settings JSON file to merge into Claude settings

### CLI reference

```
claude-compose                        # launch workspace
claude-compose build [--force]        # build/rebuild resources
claude-compose config                 # create or edit config interactively
claude-compose config -y ~/path       # quick-create config with one project
claude-compose config --check         # validate config
claude-compose migrate ~/project      # import config from existing project
claude-compose copy ~/ws/src ~/ws/dst # clone workspace
claude-compose doctor                 # diagnose and fix problems
claude-compose start [root-path]      # onboarding wizard
claude-compose ide [variant]         # set up VS Code/Cursor integration
claude-compose wrap                  # VS Code process wrapper (internal)
claude-compose --dry-run             # preview without mutations
claude-compose -- -p "prompt"        # pass args through to claude
```
