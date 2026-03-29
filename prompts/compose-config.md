# compose-config — Create or manage claude-compose workspace config

Config file: `__CONFIG_FILE__`__CONFIG_DEFAULT__

## Workspace Model (v2.0)

claude-compose uses a **workspace** model: the workspace directory contains all Claude configuration (MCP servers, agents, skills, permissions, CLAUDE.md). External projects provide only file access via `--add-dir`.

## Config schema

Top-level fields:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `projects` | array | `[]` | List of external projects for file access |
| `resources` | object | `{}` | Local agents, skills, MCP servers, env files |
| `workspaces` | array | `[]` | Other workspaces to sync config from |
| `plugins` | array | `[]` | Plugins: marketplace names or local paths |
| `marketplaces` | object | `{}` | Custom plugin marketplaces |

Each project in the `projects` array:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `path` | string | **required** | Path to external project directory |
| `name` | string | **required** | Short alias for the project (used as `name://` file reference prefix) |
| `claude_md` | boolean | `true` | Load CLAUDE.md from project |

Projects provide file access via `--add-dir` — nothing else. MCP servers, agents, skills, and permissions are managed directly in the workspace, via plugins, or synced from other workspaces.

## Workspaces (cross-sync)

Sync MCP servers, agents, skills, and plugins from other workspaces at build time:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `path` | string | **required** | Path to source workspace |
| `mcp.include` | string[] | `["*"]` | MCP servers to include (glob) |
| `mcp.exclude` | string[] | `[]` | MCP servers to exclude |
| `mcp.rename` | object | `{}` | Rename MCP servers: `{"old": "new"}` |
| `agents.include` | string[] | `["*"]` | Agents to include |
| `agents.exclude` | string[] | `[]` | Agents to exclude |
| `agents.rename` | object | `{}` | Rename agents |
| `skills.include` | string[] | `["*"]` | Skills to include |
| `skills.exclude` | string[] | `[]` | Skills to exclude |
| `plugins.include` | string[] | `["*"]` | Plugins to include (glob) |
| `plugins.exclude` | string[] | `[]` | Plugins to exclude |
| `claude_md` | boolean | `true` | Load CLAUDE.md from source workspace (cascades to child projects when false) |
| `claude_md_overrides` | object | `{}` | Per-project claude_md overrides: `{"project-name": true}` |

Source workspace's own projects and plugins (from its `claude-compose.json`) are transitively synced. If a project is also directly in your `projects[]`, your direct config takes priority.

## Plugins

Plugins are reusable Claude Code extensions installed from marketplaces or local paths.

Plugin entries can be:
- **Marketplace name** (string): `"ralph-loop"` → auto-installed from default marketplace
- **Marketplace with specific marketplace** (string): `"code-review@my-marketplace"` → installed from named marketplace
- **Local path** (string starting with `./`, `~/`, or `/`): `"./local/plugin"` → loaded via `--plugin-dir`
- **Object with `name`**: `{"name": "security-guidance", "config": {"mode": "strict"}}` → marketplace with config
- **Object with `path`**: `{"path": "./vendor/my-plugin"}` → local plugin

Plugin config values are passed as `CLAUDE_PLUGIN_OPTION_*` env vars (keys uppercased).

### Custom Marketplaces

```json
"marketplaces": {
  "team-tools": {
    "source": "github",
    "repo": "our-org/claude-plugins"
  }
}
```

Custom marketplaces are added to `extraKnownMarketplaces` in Claude settings.

## Simplification rules — IMPORTANT

When writing config, **omit any field that equals its default**:
- `claude_md: true` → omit
- `name` is **required** — always include it, never omit
- A minimal project entry is `{"path": "~/path", "name": "alias"}`

## Mode detection

Check if `__CONFIG_FILE__` exists:
- **File does not exist** → **Create mode**
- **File exists** → **Edit mode**

## Create mode

1. **Ask** for project paths. For each path:
   a. Verify directory exists (warn if not, but allow — user may set up later)
   b. Reject if a project path resolves to the workspace directory (the current working directory)

2. Ask if user wants to add another project or finish.

3. **Write config** using bash + jq for proper JSON formatting:
   ```bash
   tmp=$(mktemp "__CONFIG_FILE__.XXXXXX")
   echo '<json>' | jq '.' > "$tmp" && mv "$tmp" "__CONFIG_FILE__"
   ```
   Apply simplification rules before writing.

4. **Show summary**: number of projects, key settings.

## Edit mode

1. **Read** `__CONFIG_FILE__` and show summary:
   - Project paths
   - claude_md toggle (only show if non-default)
   - Active plugins

2. **Ask** what to do:
   - **Add** a new project
   - **Edit** a project (change path or claude_md toggle)
   - **Remove** a project
   - **Manage plugins** — add/remove plugins in config
   - **Manage workspaces** — add/remove/edit workspace entries (path or scan, with filters)
   - **Done** — finish

3. After each operation, show updated config state and ask for next action.

4. **Write** changes atomically:
   ```bash
   tmp=$(mktemp "__CONFIG_FILE__.XXXXXX")
   echo '<json>' | jq '.' > "$tmp" && mv "$tmp" "__CONFIG_FILE__"
   ```

## After finishing

Show the user how to launch and manage:

```
Ready to launch:
  claude-compose__CONFIG_F_FLAG__

Build workspace:
  claude-compose build__CONFIG_F_FLAG__

Validate:
  claude-compose config --check__CONFIG_F_FLAG__
```

If plugins or workspaces were added/changed, suggest running `claude-compose build`.

## Rules
- Keep `~` in paths as-is (claude-compose expands at runtime)
- Always validate JSON with `jq` before writing
- Reject project paths that resolve to the current working directory
- Do NOT create the config if user adds zero projects (create mode)
- Do NOT modify or delete the config if user made no changes (edit mode)
- When showing current state, read the file fresh each time (edit mode)
