# claude-compose

Multi-project launcher for [Claude Code](https://claude.ai/code). Merges MCP servers, permissions, skills, and CLAUDE.md from external projects into a single session — like `docker-compose` for Claude Code workspaces.

## Why

Claude Code's `--add-dir` gives file access to other directories, but **MCP servers, permissions, and settings from added directories are not loaded**. If you work across multiple projects (e.g., an app repo + an Obsidian vault + a shared tooling repo), you need a way to compose them.

`claude-compose` reads a simple JSON config, merges resources from external projects, and launches Claude Code with everything wired up.

## What it merges

| Resource | How | Filterable |
|----------|-----|------------|
| **MCP servers** | `--mcp-config` (temp file) | include/exclude/rename |
| **Permissions** | `--settings` (merge, no file modification) | include/exclude (glob) |
| **Skills** | Loaded via `--add-dir` when `files: true`; copied when `files: false` | include/exclude (when copied) |
| **CLAUDE.md** | `--add-dir` + `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` | on/off |
| **Files** | `--add-dir` | on/off |

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
curl -fsSL https://raw.githubusercontent.com/nersonSwift/claude-compose/main/claude-compose -o ~/.local/bin/claude-compose
chmod +x ~/.local/bin/claude-compose
```

## Requirements

- [Claude Code CLI](https://claude.ai/code) in PATH
- [jq](https://jqlang.github.io/jq/) (`brew install jq` / `apt install jq`)

## Usage

```bash
# Default config (claude-compose.json in current dir)
claude-compose

# Custom config
claude-compose -f compose-full.json

# Preview what would be launched (no mutations)
claude-compose --dry-run

# Pass args through to claude
claude-compose -- -p "explain the architecture"
```

## Config

Create `claude-compose.json` in your project root:

```json
{
  "projects": [
    {
      "path": "~/Documents/Code/MyProject",
      "mcp": {
        "include": ["*"],
        "exclude": ["discord"],
        "rename": {
          "linear": "linear-work"
        }
      },
      "permissions": {
        "include": ["mcp__*"],
        "exclude": []
      },
      "claude_md": true,
      "files": true
    }
  ]
}
```

### Fields

| Field | Default | Description |
|-------|---------|-------------|
| `path` | *required* | Path to external project (`~` expanded) |
| `mcp.include` | `["*"]` | MCP server names to include (glob) |
| `mcp.exclude` | `[]` | MCP server names to exclude (glob) |
| `mcp.rename` | `{}` | Rename servers: `{"old": "new"}` |
| `permissions.include` | `["*"]` | Permission patterns to include (glob) |
| `permissions.exclude` | `[]` | Permission patterns to exclude (glob) |
| `skills.include` | `["*"]` | Skill names to include (only when `files: false`) |
| `skills.exclude` | `[]` | Skill names to exclude (only when `files: false`) |
| `claude_md` | `true` | Load CLAUDE.md from external project |
| `files` | `true` | Add project directory via `--add-dir` |

### Pattern matching

- `*` — matches everything
- `"linear"` — exact match
- `"mcp__linear__*"` — glob pattern
- Include is evaluated first, then exclude removes from the result

## How it works

1. Reads config and validates prerequisites
2. For each external project: collects MCP servers, permissions, skills
3. Writes merged MCP config to a temp file (mode 600, in `$TMPDIR`)
4. Expands `~` and `${HOME}` in all string values
5. Launches `claude` with `--mcp-config`, `--add-dir`, `--settings` flags
6. Cleans up temp files and copied skills on exit (`trap EXIT`)

### Concurrency

Multiple `claude-compose` sessions can run from the same directory without conflicts. Each session uses PID-based isolation for copied skills (`_compose_<pid>_<name>`). Stale directories from crashed sessions (kill -9) are cleaned up on next startup.

### Security

- Temp MCP files created with `umask 077` in `$TMPDIR` (per-user directory on macOS)
- Permissions passed via `--settings` flag — no files modified
- `--dry-run` performs zero mutations
- No `eval` — tilde expansion uses safe string substitution

## License

MIT
