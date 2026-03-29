[← Back to README](../README.md)

# Cross-Workspace Sync

Share MCP servers, agents, skills, and plugins between workspaces.

## Concept

A workspace can reference other claude-compose workspaces to sync their resources at build time. When the source workspace changes, the target auto-rebuilds on next launch.

This is useful for:
- Sharing a common set of tools across multiple workspaces
- Inheriting team-wide configuration
- Composing specialized workspaces from building blocks

## Configuration

```json
{
  "workspaces": [
    { "path": "~/workspaces/team-tools" },
    {
      "path": "~/workspaces/work",
      "mcp": {
        "include": ["*"],
        "exclude": ["internal-*"],
        "rename": { "cal": "work-cal" }
      },
      "agents": {
        "include": ["reviewer", "planner"],
        "rename": { "planner": "architect" }
      },
      "skills": {
        "exclude": ["test-*"]
      },
      "plugins": {
        "include": ["*"],
        "exclude": ["debug-*"]
      },
      "claude_md": false,
      "claude_md_overrides": {
        "important-project": true
      }
    }
  ]
}
```

### Workspace Entry Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `path` | string | **required** | Path to source workspace directory |
| `mcp.include` | string[] | `["*"]` | MCP server names to include (glob patterns) |
| `mcp.exclude` | string[] | `[]` | MCP server names to exclude |
| `mcp.rename` | object | `{}` | Rename servers: `{"old-name": "new-name"}` |
| `agents.include` | string[] | `["*"]` | Agent names to include |
| `agents.exclude` | string[] | `[]` | Agent names to exclude |
| `agents.rename` | object | `{}` | Rename agents: `{"old": "new"}` |
| `skills.include` | string[] | `["*"]` | Skill names to include |
| `skills.exclude` | string[] | `[]` | Skill names to exclude |
| `plugins.include` | string[] | `["*"]` | Plugin names to include (glob patterns) |
| `plugins.exclude` | string[] | `[]` | Plugin names to exclude |
| `claude_md` | boolean | `true` | Load CLAUDE.md from source workspace. When `false`, cascades to all child projects. |
| `claude_md_overrides` | object | `{}` | Per-project claude_md overrides: `{"project-name": true}` |

## What Gets Synced

| Resource | How It's Synced |
|----------|----------------|
| Agents (`.claude/agents/*.md`) | Symlinked. Renamed agents get frontmatter `name:` rewritten. |
| Skills (`.claude/skills/*/`) | Symlinked to target workspace. |
| MCP servers (`.claude/claude-compose/mcp.json`) | Merged into target's MCP config. |
| Plugins (from source's `claude-compose.json`) | Collected and deduplicated (last wins). Local paths resolved relative to source. |
| Projects (from source's `claude-compose.json`) | Added transitively via `--add-dir`. |
| CLAUDE.md | Loaded via `--add-dir` if `claude_md: true`. |

Permissions (`.claude/settings.local.json`) are **not** synced.

## Include/Exclude Patterns

Patterns use shell glob matching:

| Pattern | Matches |
|---------|---------|
| `*` | Everything |
| `review*` | `reviewer`, `review-bot`, `review` |
| `*-internal` | `api-internal`, `db-internal` |

**Logic:** A resource is included if it matches any include pattern AND does not match any exclude pattern.

If `include` is empty (`[]`), nothing is synced from that category.

## Rename

Renaming avoids name collisions when syncing from multiple sources:

```json
{
  "mcp": { "rename": { "calendar": "work-calendar" } },
  "agents": { "rename": { "reviewer": "team-reviewer" } }
}
```

When an agent is renamed, its YAML frontmatter `name:` field is rewritten to match.

## Env Var Prefixing

MCP servers synced from external workspaces get their environment variables prefixed to prevent conflicts:

```
{source_name}_{hash4}_VARNAME
```

For example, a workspace named `team-tools` with hash `a1b2`:
- `API_KEY` becomes `team_tools_a1b2_API_KEY`

Only variables defined in the source workspace's `resources.env_files` are prefixed. System variables like `HOME` are left unchanged.

See [Environment](environment.md) for details.

## Transitive Projects

If the source workspace has projects in its `claude-compose.json`, they are transitively added to the target workspace via `--add-dir`. This means you get file access to the source workspace's projects without explicitly listing them.

### claude_md Cascading

When `claude_md: false` is set on a workspace entry, it cascades down to all child projects — their CLAUDE.md files are excluded regardless of the source workspace's own settings.

Use `claude_md_overrides` to selectively re-enable specific projects:

```json
{
  "workspaces": [{
    "path": "~/workspaces/team-tools",
    "claude_md": false,
    "claude_md_overrides": { "important-lib": true }
  }]
}
```

Result: team-tools CLAUDE.md is excluded, `important-lib` project's CLAUDE.md is included, all other projects' CLAUDE.md files are excluded.

### Direct Wins

If the same project appears both directly in your `projects[]` and indirectly through a workspace, the direct configuration takes priority. The workspace's copy is skipped to avoid duplicates.

## Plugin Sync

Plugins defined in a source workspace's `claude-compose.json` are collected and added to the target workspace. Both marketplace and local path plugins are supported.

Plugin filtering works the same as other resources:

```json
{
  "workspaces": [{
    "path": "~/workspaces/team-tools",
    "plugins": {
      "include": ["code-*"],
      "exclude": ["code-debug"]
    }
  }]
}
```

**Deduplication:** If the same plugin appears from multiple sources, the last one processed wins. For local path plugins, dedup is by resolved absolute path. For marketplace plugins, by name.

## Cycle Prevention

claude-compose detects and prevents:
- **Self-references** — a workspace cannot reference itself
- **Duplicates** — the same workspace path is only processed once
- **Circular dependencies** — detected via absolute path deduplication

## Example: Multi-Workspace Setup

```
~/.claude-compose/global.json      → shared everywhere
~/workspaces/team-tools/           → team MCP servers, agents, skills
~/workspaces/frontend/             → frontend projects + team-tools
~/workspaces/backend/              → backend projects + team-tools
```

`~/workspaces/frontend/claude-compose.json`:
```json
{
  "projects": [
    { "path": "~/Code/web-app", "name": "web" },
    { "path": "~/Code/design-system", "name": "ds" }
  ],
  "workspaces": [
    {
      "path": "~/workspaces/team-tools",
      "agents": { "exclude": ["backend-*"] }
    }
  ]
}
```

[← Back to README](../README.md)
