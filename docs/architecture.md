[← Back to README](../README.md)

# Architecture

How claude-compose works internally.

## Overview

claude-compose is a single Bash script (~4000 lines) built from 15 source files concatenated at build time. Prompts are embedded via marker replacement, and a built-in plugin is base64-encoded.

## Source Structure

Files are numbered for concatenation order:

| File | Lines | Purpose |
|------|-------|---------|
| `00-header.sh` | 9 | Shebang, version constant |
| `01-globals.sh` | ~80 | Global variables, color codes, config state |
| `02-utils.sh` | ~530 | CLI parsing, glob matching, path expansion, atomic writes, helpers |
| `03-validation.sh` | ~370 | JSON config validation (syntax + semantic) |
| `04-hash.sh` | ~130 | SHA256-based change detection |
| `05-env.sh` | ~100 | Environment variable loading from JSON files |
| `06-cleanup.sh` | ~65 | Manifest-based removal of old resources |
| `07-mcp-prefix.sh` | ~33 | MCP env var prefixing for source isolation |
| `08-sync.sh` | ~220 | Core sync: symlink agents/skills, merge MCP servers |
| `08a-collect.sh` | ~370 | Arg-collection helpers, plugin resolution |
| `09-build.sh` | ~450 | Build orchestrator |
| `10-commands.sh` | ~800 | All subcommand implementations |
| `11-embedded-skills.sh` | ~20 | Built-in plugin extraction |
| `12-prompts.sh` | ~95 | Prompt loading functions |
| `13-main.sh` | ~240 | Entry point, arg dispatch, launch |

## Build Pipeline

When claude-compose launches (or `build` is called explicitly):

```
1. compute_build_hash()     ← hash all source files BEFORE build
2. _acquire_lock()          ← prevent concurrent builds (mkdir-based)
3. clean_manifest_section() ← remove old agents/skills/MCP by manifest
4. process_global()         ← global.json resources + workspaces
5. process_workspace_source() × N  ← sync from each workspace
6. process_resources()      ← local resources from config
7. resolve_plugins()        ← install marketplace + resolve local dirs
8. atomic_write(manifest)   ← track what came from where
9. atomic_write(hash)       ← store pre-build hash for change detection
```

### Change Detection

The build hash includes:
- Content of `claude-compose.json` and `global.json`
- Built-in plugin files
- Workspace source config files, agents, skills
- Local agents, skills, env files, system prompt files, settings
- MCP server configs (inline JSON)

Hash is computed **before** the build starts. This prevents a TOCTOU race: if a file changes during build, the stored hash reflects the pre-build state, causing a rebuild on next launch.

### Manifest

`.claude/claude-compose/manifest.json` tracks which resources came from which source:

```json
{
  "global": { "resources": { "agents": ["global-reviewer.md"], ... } },
  "workspaces": { "/path/to/ws": { "agents": [...], "skills": [...], "mcp_servers": [...] } },
  "resources": { "local": { "agents": ["reviewer.md"], ... } }
}
```

On rebuild, old resources are cleaned first (by iterating the manifest), then new resources are synced.

## Launch Flow

```
main()
  ├── parse_args()              ← CLI argument parsing
  ├── ensure_builtin_plugin()   ← extract built-in plugin if version changed
  ├── _resolve_workspace_dir()  ← handle workspace_path, cd to workspace
  ├── trap ERR/EXIT             ← set up doctor error recovery
  ├── dispatch subcommand       ← config/build/migrate/etc.
  │   (or continue to launch)
  ├── validate()                ← JSON + semantic validation
  ├── auto-build if needed      ← _has_anything_to_build() + needs_rebuild()
  ├── load env files            ← global → local → source (with prefix)
  ├── _collect_project_args()   ← --add-dir for each project
  ├── _init_system_prompt()     ← compose system prompt + project aliases
  ├── _collect_manifest_args()  ← --add-dir from synced workspaces
  ├── _build_settings()         ← claudeMdExcludes, enabledPlugins, etc.
  ├── --mcp-config              ← if compose mcp.json exists
  ├── _collect_plugin_args()    ← --plugin-dir for local plugins
  └── claude "${CLAUDE_ARGS[@]}"← launch!
```

## Generated Files

```
.claude/
├── agents/                          ← symlinks to agent .md files
├── skills/                          ← symlinks to skill directories
└── claude-compose/
    ├── mcp.json                     ← merged MCP server definitions
    ├── manifest.json                ← resource tracking (source → files)
    ├── hash                         ← content hash for rebuild detection
    ├── settings.json                ← composed settings
    └── build.lock/                  ← directory-based lock (temporary)
```

## Security

### No eval

Tilde expansion uses safe string substitution (`${path/#\~/$HOME}`), not `eval`.

### Atomic Writes

All file writes use `mktemp` + `mv` to prevent partial writes or corruption.

### Path Validation

- **`_is_within_dir()`** — verifies resolved paths stay within expected directories (uses `cd` + `pwd -P` for symlink resolution)
- Applied to: agent paths, skill paths, env file paths
- Symlink escape detection for agents and skills synced from workspaces

### Env Var Blocklist

60+ dangerous environment variable keys are blocked. See [Environment](environment.md#blocked-variables).

### MCP Prefixing

Env vars from workspace sources are prefixed (`{name}_{hash4}_`) to prevent cross-source conflicts and injection.

### Prompt Sanitization

Error messages passed to doctor mode have backticks, `$`, and `\` stripped to prevent prompt injection.

### jq Parameterization

All user data passed to `jq` uses `--arg` / `--argjson` (parameterized), never string interpolation in jq expressions.

### Build Lock

Directory-based locking (`mkdir`) prevents concurrent builds. Stale locks are detected by checking if the PID is alive.

## Makefile Build System

The binary is built by concatenating source files and replacing markers:

```makefile
cat src/*.sh > claude-compose.tmp
# Replace __PROMPT_*__ markers with prompt file contents
# Replace __EMBEDDED_PLUGIN__ with base64-encoded plugin extraction function
# Replace __PROMPT_COMPOSE_KNOWLEDGE__ with shared knowledge base
```

The same process generates the test library (`tests/test_helper/claude-compose-functions.sh`) with markers stripped and `main "$@"` removed.

[← Back to README](../README.md)
