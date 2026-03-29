[← Back to README](../README.md)

# Global Config

Configuration that applies to all workspaces automatically.

## Location

```
~/.claude-compose/global.json
```

This file is optional. If it exists, its contents are applied to every workspace before local config.

## Schema

The global config uses the same schema as `claude-compose.json`:

```json
{
  "projects": [
    { "path": "~/Code/common-lib", "name": "common" }
  ],
  "resources": {
    "agents": ["agents/my-agent.md"],
    "skills": ["skills/my-skill"],
    "mcp": {
      "global-server": { "command": "npx", "args": ["my-global-server"] }
    },
    "env_files": [".env.json"]
  },
  "workspaces": [
    { "path": "~/workspaces/shared-tools" }
  ],
  "plugins": ["ralph-loop"]
}
```

Resource paths are relative to `~/.claude-compose/`.

## Processing Order

Resources are processed in this order during build:

| Priority | Source | Description |
|----------|--------|-------------|
| 1 | Built-in skills | From `~/.claude-compose/skills/` |
| 2 | **Global config** | `~/.claude-compose/global.json` |
| 3 | Workspace workspaces | Synced from other workspaces |
| 4 | Local resources | From workspace `claude-compose.json` |

Later sources override earlier ones on name conflicts (e.g., a local agent with the same name as a global agent replaces it).

## Environment Variables

Global env files are loaded **before** local env files. If both define the same key, the local value wins.

Global resources' env vars are **not prefixed** — they are exported directly, same as local env vars.

## What Global Config is Good For

- MCP servers you want everywhere (calendar, Slack, database)
- Agents and skills you use across all projects
- Plugins that should always be available
- Shared projects (utility libraries, documentation repos)

## Example

`~/.claude-compose/global.json`:
```json
{
  "resources": {
    "mcp": {
      "calendar": {
        "command": "npx",
        "args": ["@anthropic/mcp-google-calendar"],
        "env": { "GOOGLE_TOKEN": "${GOOGLE_OAUTH_TOKEN}" }
      }
    },
    "env_files": [".env.json"],
    "agents": ["agents/universal-reviewer.md"]
  },
  "plugins": ["ralph-loop"]
}
```

`~/.claude-compose/.env.json`:
```json
{
  "GOOGLE_OAUTH_TOKEN": "ya29.xxx"
}
```

This gives every workspace access to the Google Calendar MCP server and the universal-reviewer agent without any per-workspace configuration.

[← Back to README](../README.md)
