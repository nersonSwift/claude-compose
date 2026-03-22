# compose-config — Create or manage claude-compose workspace config

Config file: `__CONFIG_FILE__`__CONFIG_DEFAULT__

## Workspace Model (v2.0)

claude-compose uses a **workspace** model: the workspace directory contains all Claude configuration (MCP servers, agents, skills, permissions, CLAUDE.md). External projects provide only file access via `--add-dir`.

## Config schema

Top-level fields:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `projects` | array | `[]` | List of external projects for file access |
| `workspaces` | array | `[]` | Other workspaces to sync config from |
| `presets` | string[] | `[]` | Preset names to activate |

Each project in the `projects` array:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `path` | string | **required** | Path to external project directory |
| `name` | string | **required** | Short alias for the project (used as `name://` file reference prefix) |
| `claude_md` | boolean | `true` | Load CLAUDE.md from project |

Projects provide file access via `--add-dir` — nothing else. MCP servers, agents, skills, and permissions are managed directly in the workspace, via presets, or synced from other workspaces.

## Workspaces (cross-sync)

Sync MCP servers, agents, and skills from other workspaces at build time:

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
| `claude_md` | boolean | `true` | Load CLAUDE.md from source workspace |

Source workspace's own projects (from its `claude-compose.json`) are transitively added via `--add-dir`.

## Presets

Presets are reusable sets of Claude resources stored globally at `~/.claude-compose/presets/<name>/`. Each preset uses a `claude-compose.json` file with the same format as a workspace config — resources are declared explicitly via paths.

### Preset directory structure

```
~/.claude-compose/presets/<name>/
├── claude-compose.json    # required — resource declarations
├── agents/                # agent .md files
├── skills/                # skill directories
├── CLAUDE.md              # optional — loaded via --add-dir
└── .env.json              # optional — env vars for MCP prefixing
```

### Preset claude-compose.json schema

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `resources.agents` | string[] | `[]` | Relative paths to agent .md files |
| `resources.skills` | string[] | `[]` | Relative paths to skill directories |
| `resources.mcp` | object | `{}` | MCP server configs (same format as workspace) |
| `resources.env_files` | string[] | `[]` | Env files for MCP variable substitution |
| `claude_md` | boolean | `true` | Load CLAUDE.md from preset |
| `presets` | string[] | `[]` | Nested preset names (recursive) |
| `projects` | array | `[]` | External projects (`path` + optional `name`, `claude_md`) |

MCP servers from presets get env var prefixing to prevent cross-source conflicts.

### Preset management operations

- **Create preset**: Set up `claude-compose.json` and resource files in `~/.claude-compose/presets/<name>/`
- **List presets**: Scan `~/.claude-compose/presets/` and show contents summary
- **Delete preset**: Remove the preset directory
- **Edit preset**: Modify `claude-compose.json` or resource files in the preset directory

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
   - Active presets

2. **Ask** what to do:
   - **Add** a new project
   - **Edit** a project (change path or claude_md toggle)
   - **Remove** a project
   - **Manage presets** — add/remove preset names in config
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

Build presets:
  claude-compose build__CONFIG_F_FLAG__

Validate:
  claude-compose config --check__CONFIG_F_FLAG__
```

If presets were added/changed, suggest running `claude-compose build`.

## Rules
- Keep `~` in paths as-is (claude-compose expands at runtime)
- Always validate JSON with `jq` before writing
- Reject project paths that resolve to the current working directory
- Do NOT create the config if user adds zero projects (create mode)
- Do NOT modify or delete the config if user made no changes (edit mode)
- When showing current state, read the file fresh each time (edit mode)
