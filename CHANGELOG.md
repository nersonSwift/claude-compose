# Changelog

## [2.2.0] - 2026-03-25

### Breaking Changes

- **Preset config renamed**: Preset config file renamed from `claude-compose.json` to `claude-compose-preset.json`. Existing presets using the old name will show a migration error. Workspace config remains `claude-compose.json`.

### Added

- **Preset path support**: Presets can now be referenced by filesystem path (relative or absolute) in addition to name. Use a string containing `/` or `~` (e.g., `"./my-preset"`, `"~/presets/custom"`) or an object with a `"path"` field. Path presets resolve relative to the config file that references them.

## [2.1.0] - 2026-03-25

### Security

- **Env blocklist hardened**: `NODE_OPTIONS`, `JAVA_TOOL_OPTIONS`, and `_JAVA_OPTIONS` added to the dangerous env key blocklist — these allow arbitrary code execution in Node.js/JVM processes (MCP servers are often Node.js).
- **Path traversal protection for agent/skill paths**: `process_resources()` now validates agent and skill paths from config against directory traversal (`../`) before creating symlinks. Prevents malicious presets from targeting files outside their directory.

### Fixed

- **Hash operator precedence**: 9 instances of `[[ cond ]] && cmd || true` replaced with proper `if/then` blocks in hash functions. The old pattern silently swallowed command failures when the condition was true, potentially causing missed hash entries and false cache-hits.
- **Temp file cleanup**: `compute_build_hash()` now uses a `RETURN` trap for temp file removal instead of an explicit `rm` that could be skipped on early exit.
- **base64 portability**: Changed `base64 --decode` to `base64 -d` in the Makefile build output — `--decode` is a GNU long option not supported on all platforms.
- **Batch MCP cleanup**: `clean_manifest_section()` now removes MCP servers in a single `jq reduce` + `atomic_write` instead of one file write per server.
- **Variable scope leak**: `_d` loop variable in `has_builtin_skills()` and `cmd_build()` dry-run now declared `local`.

### Improved

- **`iterate_presets()` helper**: Common preset iteration logic (mixed string/object array normalization) extracted into a shared function with callback pattern, eliminating 4 duplicated for-loops across `build()`, `process_global()`, `cmd_update()`, and `cmd_registries()`.
- **Validation decomposed**: `validate_config_semantics()` (320 lines) split into 5 focused sub-functions: `_validate_projects()`, `_validate_resources()`, `_validate_update_interval()`, `_validate_workspaces()`, `_validate_presets()`.
- **`process_resources()` documented**: All 4 call sites now have inline comments listing the 8 positional parameters.

## [2.0.0] - 2026-03-24

### Breaking Changes

- **Workspace model**: All Claude configuration now lives in the workspace directory. Projects provide file access only via `--add-dir`. Previous project-centric configs must be migrated.
- **Preset format**: Presets now use `claude-compose.json` with explicit `resources` declarations instead of the old `preset.json` / `.claude/` directory structure.

### Added

- **GitHub registry presets**: Source presets from GitHub repos with semver versioning (`github:owner/repo@^1.0.0`), lock files, and automatic update checks.
- **Global config**: `~/.claude-compose/global.json` for shared presets, resources, and settings across all workspaces.
- **Cross-workspace sync**: Reference other workspaces to automatically sync their MCP servers, agents, and skills with include/exclude/rename filters.
- **Resources section**: Define agents, skills, MCP servers, and env files directly in config.
- **Env files**: JSON-based environment variable loading with key validation and blocklist protection.
- **Built-in skills**: Bundled `compose-init` skill extracted at runtime from embedded base64 data.
- **`doctor` command**: Interactive diagnosis and repair of compose problems.
- **`start` command**: Onboarding wizard to scan for projects and create workspaces.
- **`update` command**: Check and apply updates for GitHub registry presets.
- **`registries` command**: List configured GitHub presets and their status.
- **`copy` command**: Clone a workspace to a new location.
- **`build` command**: Explicitly trigger workspace rebuild (with `--force` to skip hash check).
- **`instructions` command**: Show guidance for managing workspace resources.
- **`--dry-run`**: Preview mode that performs zero mutations.
- **MCP env var prefixing**: Automatic prefix isolation prevents cross-source env var conflicts.
- **Content-based build hashing**: Idempotent rebuilds — only rebuilds when source files change.
- **Manifest tracking**: `.compose-manifest.json` tracks resource provenance for clean rebuilds.
- **CI workflow**: Shellcheck linting on push and PRs.
- **Build concurrency lock**: Prevents concurrent build corruption.
- **Path traversal protection**: Env file paths validated against directory traversal.
- **Portable SHA hashing**: Automatic detection of `shasum` (macOS) or `sha256sum` (Linux).
- **Terminal-aware colors**: Color output disabled when stderr is not a terminal.
- **PID-based stale lock detection**: Lock files record holder PID for accurate stale lock cleanup.

### Fixed

- `.deb` package control file heredoc no longer depends on fragile indentation stripping.
- `compute_build_hash` RETURN trap no longer collides with `lock_write` trap.
- `pwd -P` used consistently for symlink-safe path resolution.
- Shadowed `has_resources` variable in `main()` renamed to avoid confusion.
- `require_claude` skipped in `--dry-run` mode so validation works without Claude CLI.
- `cmd_copy` prompts before auto-launching Claude instead of launching unconditionally.

### Improved

- Validation: workspaces array validated (type, required `path`, filter field types).
- Validation: unknown top-level config keys emit warnings.
- Homebrew formula description updated.
- Version injected from git tag during tagged builds.
