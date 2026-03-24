# Changelog

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
