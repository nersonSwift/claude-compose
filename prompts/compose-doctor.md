# compose-doctor — Diagnose and fix claude-compose problems

<!-- Keep in sync with compose-instructions.md — content is inlined because Makefile cannot nest __PROMPT__ markers -->

Config file: `__CONFIG_FILE__`
Workspace: `__WORKSPACE_DIR__`
Mode: __DOCTOR_MODE__

## Error context

```
__ERROR_CONTEXT__
```

## Workspace summary

__WORKSPACE_SUMMARY__

---

## Full compose knowledge

claude-compose is a multi-project workspace launcher (like Docker Compose for Claude Code). It creates a unified working environment where you can work across multiple codebases simultaneously.

### Key concepts

**Workspace directory** — the current working directory. It may contain its own code, or serve purely as a launch point for working with external projects. All Claude configuration (.claude/, .mcp.json, agents, skills, permissions) lives here and is managed by claude-compose.

**Projects** — external codebases added via `--add-dir`. They provide file access (read/write) and optionally their CLAUDE.md instructions. Projects are listed in `claude-compose.json` and referenced by aliases (e.g., `myapp://src/main.ts`).

**Presets** — reusable sets of resources (MCP servers, agents, skills) stored globally at `~/.claude-compose/presets/<name>/`. Each preset has a `claude-compose.json` with explicit `resources` declarations (same format as workspace). Activated by name in config. Can also come from GitHub registries via `{"source": "github:owner/repo@spec"}`.

**Workspaces** — other claude-compose workspaces that can share their configuration (MCP servers, agents, skills) into this one at build time.

**Build** — the process of syncing resources from presets/workspaces/local config into the workspace's `.claude/` directory and `.mcp.json`. Runs automatically at launch when changes are detected.

**Global config** — `~/.claude-compose/global.json` is an optional file with the same schema as `claude-compose.json`. It is auto-applied to all workspaces. Useful for presets, MCP servers, agents, or skills you always want available. **Important: global and local configs are processed independently — their arrays (presets, projects, etc.) are NOT merged. Each is iterated separately at build time.** An empty `"presets": []` in local config does NOT conflict with global presets.

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
  "presets": ["my-tools", "common-agents"],
  "update_interval": 24
}
```

Field rules:
- `projects[].path` — path to external project (required)
- `projects[].name` — alias for file references (required)
- `projects[].claude_md` — load CLAUDE.md from project (default: `true`, omit if true)
- `presets[]` — string (local preset name) or object `{"source": "github:owner/repo@spec", "prefix": "...", "rename": {...}, "env_files": [...]}`
- `resources.agents` — array of string paths to agent .md files
- `resources.skills` — array of string paths to skill directories
- `resources.mcp` — object of MCP server configs
- `resources.env_files` — array of string paths to JSON env files
- `update_interval` — number (hours), must be >= 0
- `workspaces[].path` — path to source workspace (required)
- `workspaces[].mcp.include/exclude/rename` — MCP server filters
- `workspaces[].agents.include/exclude/rename` — agent filters
- `workspaces[].skills.include/exclude` — skill filters

GitHub preset source format: `github:owner/repo[/path][@version-spec]`
- Version spec: `@1.2.3` (exact), `@^1.2.3` (compatible), `@~1.2.3` (patch-only), omit for latest
- Owner/repo must be alphanumeric with hyphens/dots/underscores
- Path segments must not contain `.` or `..`

### File structure

```
workspace/
├── claude-compose.json        # main config
├── claude-compose.lock.json   # version lock for GitHub presets
├── CLAUDE.md                  # workspace instructions
├── .mcp.json                  # GENERATED — merged MCP servers
├── .compose-manifest.json     # GENERATED — tracks synced resources
├── .compose-hash              # GENERATED — content hash for rebuild detection
├── .claude/
│   ├── agents/                # GENERATED — symlinks to agent files
│   ├── skills/                # GENERATED — symlinks to skill dirs
│   └── settings.local.json    # permissions (user-managed)
├── agents/                    # user-created agent source files
├── skills/                    # user-created skill source dirs
└── .env.json                  # env vars for MCP servers
```

Global config: `~/.claude-compose/global.json` (same schema)
Presets dir: `~/.claude-compose/presets/<name>/`
Registries dir: `~/.claude-compose/registries/<owner>/<repo>/<version>/`

### CLI reference

```
claude-compose                        # launch workspace
claude-compose build [--force]        # build/rebuild resources
claude-compose config                 # create or edit config interactively
claude-compose config -y ~/path       # quick-create config with one project
claude-compose config --check         # validate config
claude-compose migrate ~/project      # import config from existing project
claude-compose copy ~/ws/src ~/ws/dst # clone workspace
claude-compose update [source]        # check and apply GitHub preset updates
claude-compose registries             # list GitHub presets and status
claude-compose instructions           # show workspace management guide
claude-compose doctor                 # diagnose and fix problems
claude-compose start [root-path]      # onboarding wizard
claude-compose --dry-run              # preview without mutations
claude-compose -- -p "prompt"         # pass args through to claude
```

---

## Diagnostic approach

### If error context is present (auto-triggered mode)

You MUST fix the problem yourself, fully and autonomously. Do NOT stop halfway or ask the user to run commands. Your goal is to leave the config in a valid, launchable state.

1. **Read** the config file:
   ```bash
   cat __CONFIG_FILE__
   ```

2. **Analyze** the error and identify ALL problems — not just the reported one. Check:
   - JSON syntax validity
   - Required fields (every project needs `"name"`)
   - Field types match schema
   - Referenced presets exist (`ls ~/.claude-compose/presets/`)
   - Referenced project paths exist (expand `~` to `$HOME` when checking)
   - Global config if relevant: `~/.claude-compose/global.json`

3. **Fix everything** in one pass. For ambiguous fixes, use sensible defaults:
   - Missing `"name"` → use basename of path
   - Nonexistent preset → remove it from config
   - Nonexistent project path → warn but keep (user may create it later)

4. **Apply** atomically:
   ```bash
   tmp=$(mktemp __CONFIG_FILE__.XXXXXX)
   jq '.' <<< '<updated json>' > "$tmp" && mv "$tmp" __CONFIG_FILE__
   ```
   If `jq` fails, remove `$tmp` and report the error.

5. **Verify** by reading the file back AND running a full validation:
   ```bash
   cat __CONFIG_FILE__
   jq empty __CONFIG_FILE__
   ```
   If verification fails, fix again.

6. **Report** what was fixed and tell the user to re-run `claude-compose`.

**Key rule: the session must end with a fully valid config. Never exit leaving known problems unfixed.**

### If no error context (manual `claude-compose doctor`)

1. **Ask** the user what problem they're experiencing.

2. **Investigate** systematically:
   - Read config file
   - Check JSON validity
   - Validate semantic correctness (required fields, types, values)
   - Check that referenced paths exist (project dirs, preset dirs, workspace dirs)
   - Check global config
   - Check `.mcp.json` and `.compose-manifest.json` for build state
   - Check tool availability (jq, git, claude)

3. **Report** findings and propose fixes.

4. **Apply** fixes with user confirmation.

---

## Common problems and solutions

### Invalid JSON
- **Symptom**: `jq` parse error
- **Cause**: Trailing commas, missing quotes, unmatched braces, bad escaping
- **Fix**: Read the file, find the syntax error, rewrite the corrected JSON

### Missing project name
- **Symptom**: "Each project must have a name field"
- **Fix**: Add `"name"` field to each project entry. Suggest basename of path.

### Wrong field types
- **Symptom**: "X must be an array/object, got: Y"
- **Fix**: Convert to the correct type. Show before/after.

### Preset not found
- **Symptom**: "Preset not found: X"
- **Cause**: Preset directory `~/.claude-compose/presets/X/` doesn't exist
- **Fix**: List available presets (`ls ~/.claude-compose/presets/`), suggest correction or creation

### GitHub preset errors
- **Symptom**: Various source format or git clone errors
- **Cause**: Invalid source format, network issues, private repo without auth
- **Fix**: Verify source format, check network, suggest `git clone` manually to test

### Global config errors
- **Symptom**: "Global config error" or "Invalid JSON in global config"
- **Cause**: Same issues as workspace config but in `~/.claude-compose/global.json`
- **Fix**: Same approach but on the global config file

### Build failures
- **Symptom**: Errors during preset/workspace processing
- **Cause**: Missing dependencies, broken symlinks, permission issues
- **Fix**: Check the specific resource, verify source exists, fix paths

### Missing tools
- **Symptom**: "jq is required" / "git is required" / "claude CLI not found"
- **Fix**: Provide install instructions:
  - jq: `brew install jq` / `apt install jq`
  - git: `brew install git` / `apt install git` / Xcode Command Line Tools
  - claude: See Anthropic docs for Claude CLI installation

### Project path not found
- **Symptom**: "Warning: Project path not found, skipping"
- **Cause**: Path in config doesn't exist on disk
- **Fix**: Check if path is correct, if `~` needs expansion, or if directory was moved

---

## Rules

- Use `jq` to parse and produce all JSON — never sed or string concatenation.
- Atomic writes only: `mktemp` + `mv`.
- Keep `~` in paths as-is (claude-compose expands them at runtime).
- Fix ALL problems found, not just the first one. The config must be fully valid when you're done.
- If `__CONFIG_FILE__` does not exist, create a minimal valid config with an empty projects array.
- If global config is the problem, edit `~/.claude-compose/global.json` (not the workspace config).
- For ambiguous fixes, use sensible defaults and explain what you chose.
- Remove references to nonexistent presets rather than leaving broken config.
- After fixing, always verify by reading the file back and checking with `jq empty`.
