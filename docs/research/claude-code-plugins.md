# Claude Code Plugins — Research Findings

> Researched: 2026-03-29, Claude Code v2.1.86

## Overview

Plugins are self-contained directories that extend Claude Code with skills, agents, hooks, MCP servers, and LSP servers. They are distributable via marketplaces (GitHub repos).

## Plugin Structure

```
my-plugin/
├── .claude-plugin/
│   └── plugin.json          # Manifest (only `name` is required)
├── skills/                   # Model-invoked or user-invoked (preferred format)
│   └── my-skill/
│       ├── SKILL.md
│       └── references/
├── commands/                 # Legacy format (same as skills, flat .md files)
├── agents/                   # Specialized subagents
├── hooks/
│   ├── hooks.json
│   └── scripts/
├── .mcp.json                # MCP server configs
├── .lsp.json                # LSP server configs
├── output-styles/           # Custom response formatting
├── scripts/                 # Helper scripts
└── README.md
```

## Plugin Manifest (plugin.json)

```json
{
  "name": "my-plugin",                    // REQUIRED, kebab-case
  "version": "1.0.0",                     // semver
  "description": "...",
  "author": { "name": "...", "email": "..." },
  "homepage": "...",
  "repository": "...",
  "license": "MIT",
  "keywords": ["..."],

  // Override default component paths (all relative to plugin root)
  "commands": ["./custom/commands/"],
  "agents": "./custom/agents/",
  "skills": "./custom/skills/",
  "hooks": "./config/hooks.json",
  "mcpServers": "./.mcp.json",
  "lspServers": "./.lsp.json",
  "outputStyles": "./styles/",

  // User-configurable values (prompted on enable, sensitive → keychain)
  "userConfig": {
    "api_endpoint": { "description": "API endpoint", "sensitive": false },
    "api_token": { "description": "API token", "sensitive": true }
  },

  // Default settings
  "settings": {
    "agent": "agent-name"   // only agent is currently supported
  }
}
```

`userConfig` values are available as:
- Template: `${user_config.api_endpoint}`
- Env var: `CLAUDE_PLUGIN_OPTION_API_ENDPOINT`

## CLI Commands

```bash
# Install/uninstall
claude plugins install <name[@marketplace]> [--scope user|project|local]
claude plugins uninstall <name> [--scope user|project|local] [--keep-data]

# Enable/disable
claude plugins enable <name> [--scope user|project|local]
claude plugins disable <name> [--scope user|project|local]
claude plugins disable --all

# List/update
claude plugins list [--available --json]
claude plugins update <name> [--scope user|project|local|managed]

# Validation
claude plugins validate <path>

# Marketplaces
claude plugins marketplace add <source> [--scope user|project|local] [--sparse <paths>]
claude plugins marketplace list
claude plugins marketplace update [name]
claude plugins marketplace remove <name>
```

## Settings.json Configuration

### enabledPlugins — OBJECT, not array

```json
{
  "enabledPlugins": {
    "ralph-loop@claude-plugins-official": true,
    "code-review@claude-plugins-official": false
  }
}
```

**Verified behavior:**
- `true` → enables an installed-but-disabled plugin ✅
- `false` → disables an installed-and-enabled plugin ✅
- Enabling a **not-installed** plugin → silently ignored ❌
- Works via `--settings <file>` flag for overrides ✅
- CLI `enable/disable` updates this key in settings.json automatically

### extraKnownMarketplaces

```json
{
  "extraKnownMarketplaces": {
    "my-marketplace": {
      "source": {
        "source": "github",
        "repo": "org/repo"
      }
    }
  }
}
```

Works at all scope levels (user, project, local, --settings).

## File Locations

| File | Purpose |
|------|---------|
| `~/.claude/settings.json` | `enabledPlugins`, `extraKnownMarketplaces` (user scope) |
| `.claude/settings.json` | Same keys (project scope, shared via git) |
| `.claude/settings.local.json` | Same keys (local scope, gitignored) |
| `~/.claude/plugins/installed_plugins.json` | Install registry: scope, path, version, dates |
| `~/.claude/plugins/known_marketplaces.json` | Marketplace configs + cache paths |
| `~/.claude/plugins/blocklist.json` | Anthropic-maintained blocklist |
| `~/.claude/plugins/cache/{marketplace}/{plugin}/{version}/` | Downloaded plugin code |
| `~/.claude/plugins/data/{id}/` | Persistent plugin data (survives updates) |

### installed_plugins.json Format

```json
{
  "version": 2,
  "plugins": {
    "plugin-name@marketplace": [
      {
        "scope": "user",
        "installPath": "~/.claude/plugins/cache/marketplace/plugin/version",
        "version": "unknown",
        "installedAt": "2026-03-28T21:06:39.824Z",
        "lastUpdated": "2026-03-28T21:06:39.824Z",
        "projectPath": "/path/to/project"  // only for scope=project
      }
    ]
  }
}
```

## Installation Scopes

| Scope | Flag | Meaning |
|-------|------|---------|
| user | `--scope user` (default) | Available in all projects |
| project | `--scope project` | Only for specific project (has `projectPath`) |
| local | `--scope local` | Current session only |
| managed | (read-only) | IT/enterprise enforced |

## Loading Without Installation

```bash
claude --plugin-dir ./my-local-plugin          # single
claude --plugin-dir ./a --plugin-dir ./b       # multiple
```

Loads plugin for current session only, no install needed. Plugin must have valid structure.

## Plugin Namespacing

Installed plugin commands appear as `/plugin-name:command-name`:
```
/ralph-loop:help
/ralph-loop:ralph-loop
/ralph-loop:cancel-ralph
```

## Plugin Settings Pattern

Plugins can store per-project config in `.claude/plugin-name.local.md`:
```markdown
---
enabled: true
strict_mode: false
max_retries: 3
---

# Additional context
```

Parsed via `sed` in hooks/scripts. Changes require Claude Code restart.

## Environment Variables in Plugins

- `${CLAUDE_PLUGIN_ROOT}` — absolute path to plugin installation directory
- `${CLAUDE_PLUGIN_DATA}` — persistent data directory (~/.claude/plugins/data/{id}/)

## Marketplaces

Two built-in:
- `claude-plugins-official` — `anthropics/claude-plugins-official` (main catalog, 100+ plugins)
- `claude-code-plugins` — `anthropics/claude-code` (plugins from Claude Code repo itself)

Custom marketplaces: GitHub repos, git URLs, local paths, remote URLs.

Marketplace manifest: `.claude-plugin/marketplace.json` with plugin entries containing name, description, source, category.

## userConfig and Plugin Configuration Values

### How userConfig works

Plugins can declare configurable values in `plugin.json`:

```json
{
  "userConfig": {
    "api_key": {
      "title": "API Key",
      "description": "Your API key",
      "type": "string",        // REQUIRED: string|number|boolean|directory|file
      "sensitive": true         // true = stored in keychain
    },
    "greeting_prefix": {
      "title": "Greeting Prefix",
      "description": "Prefix for greetings",
      "type": "string",
      "sensitive": false
    }
  }
}
```

### How values are consumed

Values are available as environment variables: `CLAUDE_PLUGIN_OPTION_{UPPER_SNAKE_KEY}`

- `api_key` → `CLAUDE_PLUGIN_OPTION_API_KEY`
- `greeting_prefix` → `CLAUDE_PLUGIN_OPTION_GREETING_PREFIX`

### How to pre-configure values (VERIFIED)

**Method 1: External env vars** — set env vars before launching Claude Code:
```bash
CLAUDE_PLUGIN_OPTION_API_KEY="secret" claude
```
This works with both `--plugin-dir` and installed plugins. Verified experimentally.

**Method 2: Interactive TUI** — plugin prompts user on enable (not in `-p` mode).

**Method 3: Keychain** — sensitive values stored in macOS keychain after TUI prompt.

### Current state (2026-03-29)

- `userConfig` is supported in the plugin schema and validated by `claude plugins validate`
- Required fields: `title`, `type` (string|number|boolean|directory|file)
- Optional: `description`, `sensitive`
- No real plugins in the official marketplace use `userConfig` yet
- Values are NOT auto-populated — must be set via TUI prompt or external env vars
- In `-p` mode, TUI prompt is skipped, so env vars are the only way

## Integration with claude-compose

### Approach C: Hybrid (recommended)

**For marketplace plugins:**
1. Check `installed_plugins.json` — if plugin not installed → `claude plugins install <name>`
2. Use `enabledPlugins` in settings to toggle state
3. Use `extraKnownMarketplaces` in settings to add custom marketplaces

**For local/preset plugins:**
1. Use `--plugin-dir <path>` — no install needed
2. Plugin loaded for session only, no global side effects

**For plugin configuration (userConfig):**
1. Set `CLAUDE_PLUGIN_OPTION_*` env vars before launch
2. Compose can read config from `claude-compose.json` and export as env

### Settings.json keys (verified format)

```json
{
  "enabledPlugins": {
    "plugin-name@marketplace": true     // NOT an array — object with bool values
  },
  "extraKnownMarketplaces": {
    "marketplace-name": {
      "source": {
        "source": "github",            // or "directory", "url"
        "repo": "org/repo"             // for github
      }
    }
  }
}
```

### CLI commands for automation

```bash
# Install (downloads code to cache, adds to installed_plugins.json, enables in settings)
claude plugins install <name[@marketplace]> --scope user|project|local

# Marketplace (adds to extraKnownMarketplaces in settings)
claude plugins marketplace add <source> --scope user|project|local
```

### --plugin-dir behavior

- Plugin loaded without installation
- `userConfig` NOT prompted — env vars must be set externally
- Plugin namespaced as `plugin-name:command-name`
- Multiple: `--plugin-dir A --plugin-dir B`

## Key Constraints

- Plugin code must be **installed** (downloaded) before it can be enabled — `enabledPlugins` in settings only toggles state
- `--plugin-dir` is the only way to load a plugin without `claude plugins install`
- Plugin agents cannot use: `hooks`, `mcpServers`, or `permissionMode` fields
- Plugins cannot reference files outside their directory
- Only relative paths (starting with `./`) allowed in manifest
- `enabledPlugins` is an **object** `{ "id": bool }`, NOT an array (documentation may be wrong)
