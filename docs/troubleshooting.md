[← Back to README](../README.md)

# Troubleshooting

Common problems and how to fix them.

## Doctor Mode

claude-compose has a built-in diagnostic tool that can fix most config problems automatically.

### Manual

```bash
claude-compose doctor
```

Launches an interactive Claude session that reads your config, identifies problems, and fixes them.

### Automatic

When claude-compose encounters an error during normal operation, it automatically launches doctor mode with the error context. Claude will attempt to fix the problem and tell you to re-run.

## Common Errors

### Invalid JSON

**Symptom:** `Error: Invalid JSON in claude-compose.json`

**Causes:** Trailing commas, missing quotes, unmatched braces, bad escaping.

**Fix:**
```bash
# Check syntax
jq empty claude-compose.json

# Or let doctor fix it
claude-compose doctor
```

### Missing Project Fields

**Symptom:** `Each project must have a "name" field`

**Fix:** Every project entry needs both `path` and `name`:
```json
{ "path": "~/Code/app", "name": "app" }
```

### Duplicate Project Names

**Symptom:** `Duplicate project name: "app"`

**Fix:** Each project must have a unique `name` value.

### Wrong Field Types

**Symptom:** `"resources.agents" must be an array, got: string`

**Fix:** Arrays must use `[]` syntax:
```json
"agents": ["agents/reviewer.md"]
```
Not: `"agents": "agents/reviewer.md"`

### Missing Tools

**Symptom:** `Error: jq is required but not installed`

**Fix:**
```bash
# macOS
brew install jq

# Debian/Ubuntu
sudo apt install jq
```

**Symptom:** `Error: claude CLI not found in PATH`

**Fix:** Install [Claude Code CLI](https://claude.ai/code) and ensure it's in your PATH.

### Project Path Not Found

**Symptom:** `Warning: Project path not found, skipping: ~/Code/old-app`

**Fix:** Check that the path exists. Remember that `~` is expanded at runtime, not by the shell.

### Build Failures

**Symptom:** Errors during workspace/plugin processing

**Possible causes:**
- Source workspace doesn't exist (moved/deleted)
- Permission issues on symlink targets
- Broken symlinks in source workspace
- Plugin installation failed (network issue)

**Fix:**
```bash
# Force rebuild
claude-compose build --force

# Or check with dry-run
claude-compose build --dry-run
```

### Global Config Errors

**Symptom:** `Global config error (global.json): ...`

**Fix:** The global config at `~/.claude-compose/global.json` has the same validation rules as workspace config. Fix it the same way — check JSON syntax and field types.

## FAQ

### How do I see what claude-compose passes to claude?

```bash
claude-compose --dry-run
```

Shows all `--add-dir` paths, MCP servers, settings, env variables, and plugin dirs.

### How do I reset the build?

Delete the build artifacts and rebuild:

```bash
rm -rf .claude/claude-compose/
claude-compose build --force
```

### Config was fine yesterday but build fails now

Check if source workspaces have changed:

```bash
# Check what workspaces are configured
jq '.workspaces' claude-compose.json

# Verify each source exists
ls -la ~/workspaces/team-tools/claude-compose.json
```

### MCP server is configured but not found by Claude

1. Check that `.claude/claude-compose/mcp.json` exists and contains the server
2. Verify env vars are loaded: `claude-compose --dry-run` shows env file status
3. Check that `${VAR}` references in MCP env blocks match keys in your env files

### Unknown config key `presets`

**Symptom:** `Warning: unknown config key "presets"`

**Fix:** The `presets` key was removed in v3.0.0. Replace with `plugins` for marketplace/local extensions, or `workspaces` for sharing config from other workspaces.

### How do I uninstall?

```bash
# Homebrew
brew uninstall claude-compose

# Manual
rm ~/.local/bin/claude-compose ~/.local/bin/claude-compose-wrapper

# apt
sudo dpkg -r claude-compose
```

To clean up workspace artifacts: `rm -rf .claude/claude-compose/`

[← Back to README](../README.md)
