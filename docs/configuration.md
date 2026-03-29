[← Back to README](../README.md)

# Configuration Reference

Complete reference for `claude-compose.json`.

## Top-Level Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `projects` | array | `[]` | External projects for file access |
| `resources` | object | `{}` | Local agents, skills, MCP servers, env files |
| `workspaces` | array | `[]` | Other workspaces to sync config from |
| `plugins` | array | `[]` | Marketplace or local plugins |
| `marketplaces` | object | `{}` | Custom plugin marketplace definitions |
| `workspace_path` | string | — | Override workspace directory location |

> **Deprecated fields:** `presets` and `update_interval` are no longer supported. If present, a warning is shown. Use `plugins` for reusable extensions and `workspaces` for config sharing.

## Projects

Projects provide file access to external codebases via `--add-dir`. They do **not** contribute MCP servers, agents, or permissions — only files.

```json
{
  "projects": [
    { "path": "~/Code/my-app", "name": "app" },
    { "path": "~/Code/my-lib", "name": "lib", "claude_md": false }
  ]
}
```

### Project Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `path` | string | **required** | Path to project directory. `~` is expanded at runtime. |
| `name` | string | **required** | Unique alias. Used as `name://path` file reference prefix. |
| `claude_md` | boolean | `true` | Load CLAUDE.md from this project. Omit if `true`. |

**Simplification:** A minimal project entry is `{"path": "~/path", "name": "alias"}`.

## Resources

Local resources managed directly in the workspace.

```json
{
  "resources": {
    "agents": ["agents/reviewer.md", "agents/planner.md"],
    "skills": ["skills/commit", "skills/deploy"],
    "mcp": {
      "my-server": { "command": "npx", "args": ["my-mcp-server"] },
      "another": { "command": "node", "args": ["server.js"], "env": { "API_KEY": "${MY_KEY}" } }
    },
    "env_files": [".env.json", ".env.secrets.json"],
    "append_system_prompt_files": ["context.md"],
    "settings": "compose-settings.json"
  }
}
```

### Resource Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `agents` | string[] | `[]` | Paths to agent `.md` files (relative to workspace) |
| `skills` | string[] | `[]` | Paths to skill directories |
| `mcp` | object | `{}` | MCP server definitions (`{"name": {command, args, env}}`) |
| `env_files` | string[] | `[]` | Paths to JSON env files (`{"KEY": "value"}`) |
| `append_system_prompt_files` | string[] | `[]` | Paths to text files appended to system prompt |
| `settings` | string | — | Path to settings JSON file (merged into compose settings) |

**Agents** are symlinked to `.claude/agents/`. Create your agent files anywhere in the workspace and reference them.

**Skills** are symlinked to `.claude/skills/`. Each skill is a directory with a `SKILL.md` file.

**MCP servers** are merged into `.claude/claude-compose/mcp.json`. Use `${VAR}` references in `env` blocks — values come from `env_files`.

**Env files** are JSON objects loaded as environment variables at launch. See [Environment](environment.md).

## Workspaces

Sync MCP servers, agents, skills, and plugins from other claude-compose workspaces. See [Workspaces](workspaces.md) for full documentation.

```json
{
  "workspaces": [
    { "path": "~/workspaces/shared" },
    { "path": "~/workspaces/work", "mcp": { "rename": { "cal": "work-cal" } } }
  ]
}
```

## Plugins

Install marketplace plugins or load local plugin directories. See [Plugins](plugins.md) for full documentation.

```json
{
  "plugins": [
    "ralph-loop",
    "./local-plugin",
    { "name": "my-plugin", "config": { "mode": "strict" } }
  ]
}
```

## Marketplaces

Define custom plugin marketplaces:

```json
{
  "marketplaces": {
    "team-tools": {
      "source": "github",
      "repo": "our-org/claude-plugins"
    }
  }
}
```

Each marketplace entry requires `source` and `repo` fields. Marketplace names can be referenced in plugin entries: `"my-plugin@team-tools"`.

## workspace_path

Override where the workspace directory is created. By default, the workspace is the directory containing `claude-compose.json`.

```json
{
  "workspace_path": "../my-workspace-dir",
  "projects": [...]
}
```

When set, claude-compose:
1. Creates the directory if it doesn't exist
2. Symlinks `claude-compose.json` into it
3. Changes to that directory before building

## Config Simplification Rules

When writing config, **omit any field that equals its default**:

- `claude_md: true` → omit
- Empty arrays (`[]`) → omit the field
- Empty objects (`{}`) → omit the field

A minimal valid config:

```json
{
  "projects": [
    { "path": "~/Code/app", "name": "app" }
  ]
}
```

## Validation

Run `claude-compose config --check` to validate without launching. Common errors:

| Error | Fix |
|-------|-----|
| "Each project must have a `name` field" | Add `"name"` to each project |
| "Each project must have a `path` field" | Add `"path"` to each project |
| "Duplicate project name" | Each project needs a unique `name` |
| "`resources.agents` must be an array" | Use `["path"]` format, not a string |
| "`resources.mcp` must be an object" | Use `{"name": {...}}` format |
| "Unknown config key" | Check for typos in field names |

## Full Example

```json
{
  "projects": [
    { "path": "~/Code/frontend", "name": "web" },
    { "path": "~/Code/backend", "name": "api" },
    { "path": "~/Code/shared", "name": "shared", "claude_md": false }
  ],
  "resources": {
    "agents": ["agents/reviewer.md"],
    "skills": ["skills/commit"],
    "mcp": {
      "database": {
        "command": "npx",
        "args": ["@modelcontextprotocol/server-postgres"],
        "env": { "DATABASE_URL": "${DB_URL}" }
      }
    },
    "env_files": [".env.json"]
  },
  "workspaces": [
    { "path": "~/workspaces/team-tools" }
  ],
  "plugins": ["ralph-loop"]
}
```

[← Back to README](../README.md)
