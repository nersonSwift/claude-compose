[← Back to README](../README.md)

# Plugins

Load Claude Code plugins from marketplaces or local directories.

## Overview

Plugins are reusable Claude Code extensions that add agents, skills, or other capabilities. claude-compose supports two types:

- **Marketplace plugins** — installed from Claude's plugin registry
- **Local plugins** — loaded from a directory on disk

## Configuration

### String Format

```json
{
  "plugins": [
    "ralph-loop",
    "code-review@my-marketplace",
    "./local/my-plugin",
    "~/presets/shared-plugin"
  ]
}
```

| Format | Type | Example |
|--------|------|---------|
| `"name"` | Marketplace plugin | `"ralph-loop"` |
| `"name@marketplace"` | Plugin from custom marketplace | `"tool@team-tools"` |
| `"./path"`, `"~/path"`, `"/path"` | Local plugin directory | `"./vendor/plugin"` |

### Object Format

For marketplace plugins that need configuration:

```json
{
  "plugins": [
    {
      "name": "security-guidance",
      "config": {
        "mode": "strict",
        "timeout": "30"
      }
    }
  ]
}
```

For local plugins as objects:

```json
{
  "plugins": [
    { "path": "./vendor/my-plugin" }
  ]
}
```

`name` and `path` are mutually exclusive in an object entry.

## Plugin Config Options

Config values are passed to the plugin as environment variables:

```json
"config": {
  "mode": "strict",
  "timeout": "30"
}
```

Becomes:
- `CLAUDE_PLUGIN_OPTION_MODE=strict`
- `CLAUDE_PLUGIN_OPTION_TIMEOUT=30`

Keys are uppercased. All values must be strings.

## Marketplace Plugins

Marketplace plugins are auto-installed via `claude plugins install` on first build. Once installed, they are enabled in Claude's settings (`enabledPlugins`).

Plugin names must match: `^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$`

## Local Plugins

Local plugins are loaded via `--plugin-dir` at launch. The directory must contain a valid plugin structure (typically a `manifest.json` and resources).

Path resolution:
- `./relative` — relative to the config file directory
- `~/home-relative` — expanded at runtime
- `/absolute` — used as-is

## Custom Marketplaces

Define custom plugin marketplaces in your config:

```json
{
  "marketplaces": {
    "team-tools": {
      "source": "github",
      "repo": "our-org/claude-plugins"
    }
  },
  "plugins": [
    "my-tool@team-tools"
  ]
}
```

### Marketplace Fields

| Field | Type | Description |
|-------|------|-------------|
| `source` | string | **Required.** Marketplace source type. |
| `repo` | string | **Required.** Repository identifier. |

Custom marketplaces are added to `extraKnownMarketplaces` in Claude settings.

## Plugins from Workspaces

Plugins defined in a workspace's `claude-compose.json` are automatically collected when that workspace is referenced. Use include/exclude filters to control which plugins are synced:

```json
{
  "workspaces": [{
    "path": "~/workspaces/team-tools",
    "plugins": {
      "include": ["code-*"],
      "exclude": ["code-debug"]
    }
  }]
}
```

Local plugin paths from workspaces are resolved relative to the source workspace directory.

**Deduplication:** If the same plugin appears from multiple sources (workspaces, local config, global config), the last one processed wins. For marketplace plugins with different `config` values, the last config takes effect.

See [Workspaces](workspaces.md) for full workspace sync documentation.

## How Plugins are Resolved

During build:
1. **Workspace plugins** → collected from each workspace's config with include/exclude filtering
2. **Local config plugins** → resolved from `claude-compose.json`
3. **Global config plugins** → resolved from `~/.claude-compose/global.json`
4. **Deduplication** → same plugin from multiple sources: last wins
5. **Local paths** → verified to exist → added to `PLUGIN_DIRS` array → passed as `--plugin-dir`
6. **Marketplace names** → installed via `claude plugins install` (skipped if already installed) → added to `enabledPlugins` in settings

[← Back to README](../README.md)
