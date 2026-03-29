# claude-compose

Multi-project launcher for [Claude Code](https://claude.ai/code) — like Docker Compose for Claude workspaces.

All Claude configuration (MCP servers, agents, skills, permissions) lives in one workspace. External projects provide file access via `--add-dir`.

## Install

```bash
# Homebrew
brew install nersonSwift/tap/claude-compose

# apt
curl -fsSL https://github.com/nersonSwift/claude-compose/releases/latest/download/claude-compose.deb -o /tmp/claude-compose.deb
sudo dpkg -i /tmp/claude-compose.deb

# Script
curl -fsSL https://raw.githubusercontent.com/nersonSwift/claude-compose/main/install.sh | bash
```

Requires [Claude Code CLI](https://claude.ai/code) and [jq](https://jqlang.github.io/jq/).

## Quick Start

```bash
mkdir my-workspace && cd my-workspace
claude-compose config -y ~/Code/my-app
claude-compose
```

## Config

```json
{
  "name": "my-workspace",
  "projects": [
    { "path": "~/Code/app", "name": "app" },
    { "path": "~/Code/lib", "name": "lib" }
  ],
  "resources": {
    "agents": ["agents/reviewer.md"],
    "mcp": { "server": { "command": "npx", "args": ["my-server"] } },
    "env_files": [".env.json"]
  },
  "workspaces": [
    { "path": "~/workspaces/shared" }
  ],
  "plugins": ["ralph-loop"]
}
```

## Commands

```bash
claude-compose                        # Launch workspace
claude-compose build [--force]        # Build resources
claude-compose config [-y path]       # Create/edit config
claude-compose config --check         # Validate config
claude-compose migrate <project>      # Import from project
claude-compose copy <src> [dst]       # Clone workspace
claude-compose doctor                 # Diagnose problems
claude-compose start [root]           # Onboarding wizard
claude-compose ide [variant]          # IDE setup (VS Code/Cursor)
claude-compose instructions           # Show guide
claude-compose --dry-run              # Preview mode
```

## Documentation

| Guide | Description |
|-------|-------------|
| [Getting Started](docs/getting-started.md) | Installation, first workspace, tutorial |
| [Configuration](docs/configuration.md) | Complete `claude-compose.json` reference |
| [Commands](docs/commands.md) | All CLI commands, flags, and examples |
| [Workspaces](docs/workspaces.md) | Cross-workspace sync with filters |
| [Plugins](docs/plugins.md) | Marketplace and local plugins |
| [Environment](docs/environment.md) | Env files, secrets, variable isolation |
| [IDE Integration](docs/ide.md) | VS Code and Cursor integration |
| [Global Config](docs/global-config.md) | Config that applies everywhere |
| [Troubleshooting](docs/troubleshooting.md) | Doctor mode, common errors, FAQ |
| [Architecture](docs/architecture.md) | Internals, build pipeline, security |

## License

MIT
