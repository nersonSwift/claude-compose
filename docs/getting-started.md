[← Back to README](../README.md)

# Getting Started

Set up your first claude-compose workspace in under 2 minutes.

## Prerequisites

- **[Claude Code CLI](https://claude.ai/code)** — must be in your PATH
- **[jq](https://jqlang.github.io/jq/)** — JSON processor (`brew install jq` or `apt install jq`)

## Installation

### Homebrew (macOS / Linux)

```bash
brew install nersonSwift/tap/claude-compose
```

### apt (Debian / Ubuntu)

```bash
curl -fsSL https://github.com/nersonSwift/claude-compose/releases/latest/download/claude-compose.deb -o /tmp/claude-compose.deb
sudo dpkg -i /tmp/claude-compose.deb
```

### Install script

```bash
curl -fsSL https://raw.githubusercontent.com/nersonSwift/claude-compose/main/install.sh | bash
```

### Manual

```bash
curl -fsSL https://github.com/nersonSwift/claude-compose/releases/latest/download/claude-compose -o ~/.local/bin/claude-compose
chmod +x ~/.local/bin/claude-compose

# Optional: IDE wrapper (needed for `claude-compose ide`)
curl -fsSL https://github.com/nersonSwift/claude-compose/releases/latest/download/claude-compose-wrapper -o ~/.local/bin/claude-compose-wrapper
chmod +x ~/.local/bin/claude-compose-wrapper
```

Make sure `~/.local/bin` is in your `PATH`.

## Create Your First Workspace

### 1. Create a workspace directory

```bash
mkdir my-workspace && cd my-workspace
```

### 2. Create a config

The quickest way — point to an existing project:

```bash
claude-compose config -y ~/Code/my-app
```

This creates `claude-compose.json`:

```json
{
  "name": "my-workspace",
  "projects": [
    { "path": "~/Code/my-app", "name": "my-app" }
  ]
}
```

For interactive config creation with multiple projects:

```bash
claude-compose config
```

### 3. Launch

```bash
claude-compose
```

On the first launch, claude-compose:
1. Validates your config
2. Runs a build (if workspaces or resources are configured)
3. Loads environment variables from env files
4. Launches `claude` with `--add-dir` for each project

### 4. Verify with dry run

To see what claude-compose will do without actually launching:

```bash
claude-compose --dry-run
```

This shows all `--add-dir` paths, MCP servers, settings, and environment variables that would be passed to `claude`.

## Adding More Projects

Edit `claude-compose.json` directly or use `claude-compose config`:

```json
{
  "name": "my-workspace",
  "projects": [
    { "path": "~/Code/my-app", "name": "app" },
    { "path": "~/Code/my-lib", "name": "lib" },
    { "path": "~/Code/shared", "name": "shared", "claude_md": false }
  ]
}
```

Each project gets:
- **`path`** — directory path (`~` is expanded at runtime)
- **`name`** — alias for file references (`app://src/main.ts`)
- **`claude_md`** — load CLAUDE.md from project (default: `true`, omit if true)

## Adding Resources

MCP servers, agents, skills, and env files go in the `resources` section:

```json
{
  "projects": [...],
  "resources": {
    "agents": ["agents/reviewer.md"],
    "skills": ["skills/commit"],
    "mcp": {
      "my-server": { "command": "npx", "args": ["my-mcp-server"] }
    },
    "env_files": [".env.json"]
  }
}
```

See [Configuration Reference](configuration.md) for all fields.

## Importing from an Existing Project

If you already have a Claude Code project with MCP servers, agents, and permissions:

```bash
claude-compose migrate ~/Code/my-app
```

This copies the project's `.claude/` config into your workspace. See [Commands](commands.md#claude-compose-migrate) for details.

## Next Steps

- [Configuration Reference](configuration.md) — all config fields
- [Commands](commands.md) — all CLI commands and flags
- [Workspaces](workspaces.md) — sync config from other workspaces
- [Plugins](plugins.md) — marketplace and local plugins
- [IDE Integration](ide.md) — use with VS Code or Cursor
- [Global Config](global-config.md) — config that applies everywhere
- [Troubleshooting](troubleshooting.md) — common errors and FAQ

[← Back to README](../README.md)
