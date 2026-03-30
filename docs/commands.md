[← Back to README](../README.md)

# Commands Reference

All claude-compose CLI commands and their options.

## Global Flags

These flags work with any command:

| Flag | Description |
|------|-------------|
| `-f <file>` | Use a custom config file (default: `claude-compose.json`) |
| `--dry-run` | Preview mode — show what would happen without mutations |
| `-h`, `--help` | Show help |
| `-v`, `--version` | Show version |

## claude-compose

Launch Claude with the composed workspace.

```bash
claude-compose [options] [-- claude-args...]
```

Reads `claude-compose.json`, auto-builds if needed, loads env files, and launches `claude` with all configured projects, MCP servers, agents, skills, and system prompt.

| Option | Description |
|--------|-------------|
| `--` | Everything after `--` is passed directly to `claude` |

**Examples:**

```bash
# Launch workspace
claude-compose

# Preview without launching
claude-compose --dry-run

# Pass a prompt to claude
claude-compose -- -p "explain the architecture"

# Use a different config file
claude-compose -f compose-work.json
```

---

## claude-compose build

Build workspace resources from workspaces, plugins, and local config.

```bash
claude-compose build [--force]
```

The build runs automatically on launch when changes are detected. Use this command to build explicitly or force a rebuild.

| Option | Description |
|--------|-------------|
| `--force` | Rebuild even if the workspace is up to date |

**What it does:**
1. Symlinks agents and skills to `.claude/agents/` and `.claude/skills/`
2. Merges MCP servers into `.claude/claude-compose/mcp.json`
3. Resolves and installs plugins
4. Writes manifest (`.claude/claude-compose/manifest.json`) and hash

**Examples:**

```bash
claude-compose build
claude-compose build --force
claude-compose build --dry-run
```

---

## claude-compose config

Create or edit `claude-compose.json` interactively.

```bash
claude-compose config [-y <path>] [--check]
```

| Option | Description |
|--------|-------------|
| `-y <path>` | Quick-create config with one project at `<path>`. No interactive prompts. `<path>` is required. |
| `--check` | Validate config without launching. Exits with code 1 on errors. |

**Examples:**

```bash
# Interactive creation or editing
claude-compose config

# Quick-create with one project
claude-compose config -y ~/Code/my-app

# Validate config
claude-compose config --check

# Validate a specific config file
claude-compose config --check -f alternate.json
```

---

## claude-compose migrate

Import Claude configuration from an existing project into the workspace.

```bash
claude-compose migrate <project-path> [--delete] [--workspace <path>]
```

Copies from the project:
- `.claude/settings.local.json` (permissions — merged, deduplicated)
- `.claude/agents/*.md` (agent files)
- `.claude/skills/*/` (skill directories)
- MCP servers from `.mcp.json`
- `CLAUDE.md` (appended to workspace CLAUDE.md)

Adds the project to `claude-compose.json` if not already present.

| Option | Description |
|--------|-------------|
| `--delete` | Remove originals from the project after migration |
| `--workspace <path>` | Target workspace directory (default: current directory) |

**Examples:**

```bash
# Import from a project
claude-compose migrate ~/Code/my-app

# Import and remove originals
claude-compose migrate ~/Code/my-app --delete

# Import to a specific workspace
claude-compose migrate ~/Code/my-app --workspace ~/workspaces/main

# Preview what would be imported
claude-compose migrate ~/Code/my-app --dry-run
```

---

## claude-compose copy

Clone a workspace to a new location.

```bash
claude-compose copy <source> [destination]
```

Copies config, agents, skills, MCP config, settings, and CLAUDE.md. Build artifacts (manifest, hash) are not copied — they regenerate on first launch.

If `destination` is omitted, copies to the current directory.

**Example:**

```bash
claude-compose copy ~/workspaces/main ~/workspaces/feature
```

---

## claude-compose doctor

Diagnose and fix configuration problems.

```bash
claude-compose doctor
```

Launches an interactive Claude session that can read your config, identify problems, and fix them automatically.

Doctor mode is also triggered **automatically** when claude-compose encounters an error during normal operation (invalid JSON, semantic errors, build failures).

**What it checks:**
- JSON syntax validity
- Required fields and correct types
- Referenced paths exist
- Global config validity
- Tool availability (jq, claude)

---

## claude-compose start

Onboarding wizard for new users.

```bash
claude-compose start [root-path]
```

Scans a directory for projects (looks for `.claude/`, `CLAUDE.md`, `package.json`, `Cargo.toml`, etc.) and guides you through creating one or more workspaces.

**Example:**

```bash
claude-compose start ~/Code
```

---

## claude-compose ide

Set up IDE integration (VS Code, Cursor).

```bash
claude-compose ide [variant]
```

| Variant | Editor |
|---------|--------|
| `code` | VS Code (default) |
| `insiders` | VS Code Insiders |
| `cursor` | Cursor |

See [IDE Integration](ide.md) for full details.

**Examples:**

```bash
claude-compose ide
claude-compose ide cursor
```

---

## claude-compose wrap

Internal IDE process wrapper. **Not for manual use.**

```bash
claude-compose wrap <claude-binary> [args...]
```

Called automatically by `claudeCode.claudeProcessWrapper` when VS Code integration is set up. Routes Claude through claude-compose for workspace composition.

[← Back to README](../README.md)
