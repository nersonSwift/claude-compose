# claude-compose

Multi-project launcher for [Claude Code](https://claude.ai/code). Uses a **workspace model** where all Claude configuration lives in one place, and external projects provide file access — like `docker-compose` for Claude Code workspaces.

## Why

Claude Code's `--add-dir` gives file access to other directories, but **MCP servers, permissions, agents, and settings from added directories are not loaded**. If you work across multiple projects, you need a way to compose them.

`claude-compose` creates a workspace with all Claude configuration (MCP, agents, skills, permissions) and launches Claude with `--add-dir` for external project file access.

## Workspace Model

```
my-workspace/                    # Your workspace directory
├── claude-compose.json          # Config — lists projects and presets
├── .mcp.json                    # MCP servers (yours + from presets)
├── CLAUDE.md                    # Instructions
├── .claude/
│   ├── agents/*.md              # Agent definitions
│   ├── skills/*/                # Skills
│   └── settings.local.json      # Permissions
├── .compose-manifest.json       # Auto-generated: tracks preset resources
└── .compose-hash                # Auto-generated: build change detection
```

All Claude configuration lives in the workspace. Projects are external — they provide only file access via `--add-dir`.

## Install

### Homebrew (macOS/Linux)

```bash
brew install nersonSwift/tap/claude-compose
```

### apt (Debian/Ubuntu)

Download the `.deb` from the [latest release](https://github.com/nersonSwift/claude-compose/releases/latest):

```bash
curl -fsSL https://github.com/nersonSwift/claude-compose/releases/latest/download/claude-compose.deb -o /tmp/claude-compose.deb
sudo dpkg -i /tmp/claude-compose.deb
```

### Script

```bash
curl -fsSL https://raw.githubusercontent.com/nersonSwift/claude-compose/main/install.sh | bash
```

### Manual

```bash
curl -fsSL https://github.com/nersonSwift/claude-compose/releases/latest/download/claude-compose -o ~/.local/bin/claude-compose
chmod +x ~/.local/bin/claude-compose
```

## Requirements

- [Claude Code CLI](https://claude.ai/code) in PATH
- [jq](https://jqlang.github.io/jq/) (`brew install jq` / `apt install jq`)

## Quick Start

```bash
# Create a workspace directory
mkdir my-workspace && cd my-workspace

# Quick config — point to your project
claude-compose config -y ~/Code/my-app

# Launch
claude-compose
```

## Usage

```bash
# Launch from workspace (uses claude-compose.json)
claude-compose

# Custom config file
claude-compose -f compose-full.json

# Preview what would be launched (no mutations)
claude-compose --dry-run

# Pass args through to claude
claude-compose -- -p "explain the architecture"

# Build presets explicitly
claude-compose build
claude-compose build --force

# Import config from an existing project
claude-compose migrate ~/Code/my-app

# Clone a workspace
claude-compose copy ~/workspaces/main ~/workspaces/feature
```

### Config management

```bash
# Interactive config creation/editing
claude-compose config

# Quick create with defaults
claude-compose config -y ~/Code/my-app

# Validate config
claude-compose config --check
```

### Migrate from a project

```bash
# Import Claude config (MCP, agents, skills, permissions, CLAUDE.md)
claude-compose migrate ~/Code/my-app

# Import and remove originals
claude-compose migrate ~/Code/my-app --delete

# Import to a specific workspace
claude-compose migrate ~/Code/my-app --workspace ~/workspaces/main

# Preview what would be imported
claude-compose migrate ~/Code/my-app --dry-run
```

## Config

Create `claude-compose.json` in your workspace:

```json
{
  "projects": [
    {"name": "my-app", "path": "~/Code/my-app"},
    {"name": "my-lib", "path": "~/Code/my-lib", "claude_md": false}
  ],
  "workspaces": [
    {"path": "~/workspaces/work"},
    {"path": "~/workspaces/personal", "mcp": {"rename": {"cal": "personal-cal"}}}
  ],
  "presets": ["my-tools"]
}
```

> Presets also support GitHub registry sources as objects — see [GitHub Registry Presets](#github-registry-presets) below.

### Project fields

| Field | Default | Description |
|-------|---------|-------------|
| `name` | *required* | Alias for file references (`name://path/to/file`) |
| `path` | *required* | Path to external project (`~` expanded) |
| `claude_md` | `true` | Load CLAUDE.md from project |

Projects provide **file access only** via `--add-dir`. MCP servers, agents, skills, and permissions are configured directly in the workspace, via presets, or synced from other workspaces.

## Workspaces (cross-workspace sync)

Reference other workspaces to automatically sync their Claude configuration:

```json
{
  "workspaces": [
    {"path": "~/workspaces/work"},
    {"path": "~/workspaces/personal", "mcp": {"rename": {"cal": "personal-cal"}}},
    {"path": "~/workspaces/business", "agents": {"exclude": ["internal-*"]}}
  ]
}
```

At build time, each referenced workspace's MCP servers, agents, and skills are synced into the current workspace. When the source workspace changes (e.g., a new MCP server is added), the next launch auto-rebuilds.

### Workspace fields

| Field | Default | Description |
|-------|---------|-------------|
| `path` | *required* | Path to source workspace |
| `mcp.include` | `["*"]` | MCP server names to include (glob) |
| `mcp.exclude` | `[]` | MCP server names to exclude (glob) |
| `mcp.rename` | `{}` | Rename servers: `{"old": "new"}` |
| `agents.include` | `["*"]` | Agent names to include (glob) |
| `agents.exclude` | `[]` | Agent names to exclude (glob) |
| `agents.rename` | `{}` | Rename agents: `{"old": "new"}` |
| `skills.include` | `["*"]` | Skill names to include (glob) |
| `skills.exclude` | `[]` | Skill names to exclude (glob) |
| `claude_md` | `true` | Load CLAUDE.md from source workspace |

Source workspace's own projects (from its `claude-compose.json`) are transitively added via `--add-dir`.

## Presets

Presets are reusable sets of Claude resources stored at `~/.claude-compose/presets/<name>/`. Each preset uses a `claude-compose-preset.json` file with explicit resource declarations (same format as workspace config).

```
~/.claude-compose/presets/my-tools/
├── claude-compose-preset.json   # Resource declarations (required)
├── agents/*.md                  # Agent files
├── skills/*/                    # Skill directories
├── CLAUDE.md                    # Instructions (loaded via --add-dir)
└── .env.json                    # Optional: env vars for MCP prefixing
```

Example `claude-compose-preset.json` for a preset:

```json
{
  "resources": {
    "agents": ["agents/reviewer.md"],
    "skills": ["skills/commit", "skills/task-s"],
    "mcp": {"my-server": {"command": "npx", "args": ["..."]}},
    "env_files": [".env.json"]
  },
  "presets": ["base-tools"],
  "projects": [{"path": "~/Code/shared-lib", "name": "shared"}]
}
```

Reference presets in config by name, path, or object:

```json
{
  "presets": [
    "my-tools",
    "./local-preset",
    "~/presets/shared",
    {"path": "../other-preset", "agents": {"include": ["reviewer"]}}
  ],
  "projects": [...]
}
```

Build copies preset resources into your workspace:

```bash
claude-compose build
```

The build is **idempotent** and uses content-based hashing — it only rebuilds when preset files change. A `.compose-manifest.json` tracks which resources came from which preset, so rebuilds cleanly remove old resources before adding new ones.

MCP servers from presets get env var prefixing (`{name}_{hash4}_`) to prevent cross-source conflicts.

## Resources

Define agents, skills, MCP servers, and env files directly in your workspace config:

```json
{
  "projects": [...],
  "resources": {
    "agents": ["agents/reviewer.md", "agents/planner.md"],
    "skills": ["skills/commit", "skills/deploy"],
    "mcp": {
      "my-server": {"command": "npx", "args": ["my-mcp-server"]},
      "another": {"command": "node", "args": ["server.js"]}
    },
    "env_files": [".env.json"]
  }
}
```

Resource paths are relative to the workspace directory. Env files are JSON objects (`{"KEY": "value"}`) loaded as environment variables at launch time.

## Global Config

Global configuration at `~/.claude-compose/global.json` applies to all workspaces. It supports the same fields as workspace config (`presets`, `workspaces`, `resources`). Workspace-level config takes precedence on conflicts.

```json
{
  "presets": ["shared-tools"],
  "resources": {
    "mcp": {"global-server": {"command": "..."}},
    "env_files": ["global-env.json"]
  },
  "update_interval": 24
}
```

## GitHub Registry Presets

Presets can be sourced from GitHub repositories with semver versioning:

```json
{
  "presets": [
    {"source": "github:owner/repo@^1.0.0"},
    {"source": "github:owner/repo/preset-name@~2.1.0", "prefix": "custom"},
    "local-preset"
  ]
}
```

### Version specs

| Spec | Meaning |
|------|---------|
| `1.2.3` | Exact version |
| `^1.2.3` | Compatible updates (>=1.2.3, <2.0.0) |
| `~1.2.3` | Patch updates only (>=1.2.3, <1.3.0) |
| *(omitted)* | Latest available version |

Resolved versions are saved in `claude-compose.lock.json` next to your config. The lock file ensures reproducible builds and should be committed to version control.

### Managing registries

```bash
# List configured GitHub presets and their status
claude-compose registries

# Check for and apply updates
claude-compose update

# Update a specific preset
claude-compose update owner/repo
```

## Additional Commands

```bash
# Diagnose and fix compose problems interactively
claude-compose doctor

# Onboarding wizard — scan for projects and create workspaces
claude-compose start ~/Code

# Show instructions for managing workspace resources
claude-compose instructions
```

## How it works

1. Reads `claude-compose.json` from workspace directory
2. Auto-builds from presets if changes detected (or run `build` explicitly)
3. Collects `--add-dir` args from projects (file access) and preset dirs (CLAUDE.md)
4. Sets `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` for CLAUDE.md loading
5. Launches `claude` with collected args

### Security

- `--dry-run` performs zero mutations
- No `eval` — tilde expansion uses safe string substitution
- Preset resources tracked via manifest — rebuilds are clean
- Path traversal protection on agent, skill, and env file paths
- Env variable blocklist prevents injection via `PATH`, `LD_PRELOAD`, `NODE_OPTIONS`, `ANTHROPIC_*`, and 40+ other dangerous keys
- MCP env var prefixing isolates cross-source variables

## License

MIT
