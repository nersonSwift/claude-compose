# claude-compose workspace guide

claude-compose is a multi-project workspace launcher (like Docker Compose for Claude Code). It creates a unified working environment where you can work across multiple codebases simultaneously.

## Key concepts

**Workspace directory** — the current working directory. It may contain its own code, or serve purely as a launch point for working with external projects. All Claude configuration (.claude/, .mcp.json, agents, skills, permissions) lives here and is managed by claude-compose.

**Projects** — external codebases added via `--add-dir`. They provide file access (read/write) and optionally their CLAUDE.md instructions. Projects are listed in `claude-compose.json` and referenced by aliases (e.g., `myapp://src/main.ts`).

**Presets** — reusable sets of resources (MCP servers, agents, skills) stored globally at `~/.claude-compose/presets/<name>/` or referenced by filesystem path. Each preset has a `claude-compose-preset.json` with explicit `resources` declarations (same format as workspace). Activated by name or path in config.

**Workspaces** — other claude-compose workspaces that can share their configuration (MCP servers, agents, skills) into this one at build time.

**Build** — the process of syncing resources from presets/workspaces/local config into the workspace's `.claude/` directory and `.mcp.json`. Runs automatically at launch when changes are detected.

**Global config** — `~/.claude-compose/global.json` is an optional file with the same schema as `claude-compose.json`. It is auto-applied to **all** workspaces. Useful for presets, MCP servers, agents, or skills you always want available. Paths in `resources` resolve relative to `~/.claude-compose/`. Build priority: built-in → **global** → workspace presets → workspace workspaces → local resources. Global env files are loaded without prefix; local env files with the same keys override them.

## Working with a compose workspace

### Do NOT edit directly
- `.claude/agents/` and `.claude/skills/` contain **symlinks** managed by build — do not create or modify files there directly
- `.mcp.json` is **generated** at build time — manual edits will be overwritten
- `.compose-manifest.json` and `.compose-hash` are internal state files

### How to add resources

**Agents:** Create agent `.md` files in the workspace (e.g., `agents/my-agent.md`), then add the path to `resources.agents` in `claude-compose.json`:
```json
"resources": { "agents": ["agents/my-agent.md"] }
```

**Skills:** Create skill directories in the workspace (e.g., `skills/my-skill/`), then add the path to `resources.skills`:
```json
"resources": { "skills": ["skills/my-skill"] }
```

**MCP Servers:** Add server config to `resources.mcp`:
```json
"resources": { "mcp": { "my-server": { "command": "npx", "args": ["..."] } } }
```
For secrets, use `${VAR}` references and add values to env files.

**Environment variables / Secrets:** Create a JSON env file (e.g., `.env.secrets.json`) and add to `resources.env_files`:
```json
"resources": { "env_files": [".env.json", ".env.secrets.json"] }
```
Format: `{"KEY": "value"}`. Variables are loaded at launch. Add secret files to `.gitignore`.

After any change, run `claude-compose build` to apply (or relaunch — build runs automatically).

### Global config (`~/.claude-compose/global.json`)

Same schema as `claude-compose.json`. Applied automatically to all workspaces, no opt-out.

```json
{
  "presets": ["my-tools"],
  "resources": {
    "agents": ["agents/my-agent.md"],
    "skills": ["skills/my-skill"],
    "mcp": { "server-name": { "command": "..." } },
    "env_files": [".env.json"]
  },
  "workspaces": [{ "path": "~/shared-workspace" }],
  "projects": [{ "path": "~/common-lib", "name": "common" }]
}
```

### Config schema (claude-compose.json)

```json
{
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
  "presets": ["my-tools", "common-agents"]
}
```

- `projects[].path` — path to external project (required)
- `projects[].name` — alias for file references (required)
- `projects[].claude_md` — load CLAUDE.md from project (default: `true`)
- Omit fields that equal their defaults

### Best practices

1. **Workspace CLAUDE.md** — put cross-project instructions here, not in individual project CLAUDE.md files. This is the right place for workflow rules, conventions, and context that spans multiple projects.

2. **Keep config minimal** — omit default values (`claude_md: true`), use short aliases. A minimal project entry is `{"path": "~/path", "name": "alias"}`.

3. **Use env files for secrets** — never hardcode API keys in `claude-compose.json` or `.mcp.json`. Use `${VAR}` references in MCP configs and provide values in `.env.secrets.json` (gitignored).

4. **Presets for reuse** — if you use the same MCP servers or agents across multiple workspaces, create a preset instead of duplicating config.

5. **Build is idempotent** — running `claude-compose build` multiple times is safe. It uses content hashing to detect changes and only rebuilds when needed.

6. **Validate before launch** — use `claude-compose config --check` or `claude-compose --dry-run` to verify config without launching.

### CLI reference

```
claude-compose                        # launch workspace
claude-compose build [--force]        # build/rebuild resources
claude-compose config                 # create or edit config interactively
claude-compose config -y ~/path       # quick-create config with one project
claude-compose config --check         # validate config
claude-compose migrate ~/project      # import config from existing project
claude-compose copy ~/ws/src ~/ws/dst # clone workspace
claude-compose update [source]        # update GitHub registry presets
claude-compose registries             # list GitHub presets and status
claude-compose doctor                 # diagnose and fix config problems
claude-compose start ~/path           # onboarding wizard
claude-compose instructions           # show this guide
claude-compose --dry-run              # preview without mutations
claude-compose -- -p "prompt"         # pass args through to claude
```

__WORKSPACE_SUMMARY__
