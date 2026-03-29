[← Back to README](../README.md)

# VS Code Integration

Use claude-compose workspaces with the Claude Code VS Code extension (and Cursor).

## Setup

```bash
claude-compose vscode
```

For Cursor or VS Code Insiders:

```bash
claude-compose vscode cursor
claude-compose vscode insiders
```

This does two things:

### 1. Configures the process wrapper

Adds `claudeCode.claudeProcessWrapper` to your VS Code `settings.json`:

```json
{
  "claudeCode.claudeProcessWrapper": "/usr/local/bin/claude-compose-wrapper"
}
```

This routes all Claude sessions through claude-compose, applying your workspace config (MCP servers, agents, system prompt, env vars) transparently.

### 2. Generates a `.code-workspace` file

Creates `{workspace-name}.code-workspace` with all project folders:

```json
{
  "folders": [
    { "path": ".", "name": "MainWS / my-workspace" },
    { "path": "/Users/me/Code/app", "name": "Project / app" },
    { "path": "/Users/me/Code/lib", "name": "Project / lib" }
  ]
}
```

Folders are organized by type:
- **MainWS** — the workspace directory itself
- **Project** — projects from your config
- **Workspace** — synced workspace directories

## Using the Workspace

1. Run `claude-compose vscode`
2. Open the generated `.code-workspace` file in VS Code
3. Start a Claude session — it automatically uses your compose config

## How Wrap Mode Works

When VS Code starts a Claude session:

1. VS Code calls `claude-compose-wrapper` instead of `claude` directly
2. The wrapper runs `claude-compose wrap /path/to/claude [vscode-args...]`
3. claude-compose checks for `claude-compose.json`:
   - **No config or invalid JSON** → passes through to `claude` unchanged (graceful degradation)
   - **Valid config** → auto-builds, loads env, collects args
4. System prompts from VS Code and claude-compose are merged
5. `exec claude` with all composed arguments

This means VS Code features (streaming, output formatting) work normally while getting all your workspace configuration.

## Removing Integration

1. Open VS Code settings (Cmd+Shift+P → "Preferences: Open Settings (JSON)")
2. Delete the `claudeCode.claudeProcessWrapper` line
3. Optionally delete the `.code-workspace` file

## Troubleshooting

**Claude works in terminal but not VS Code:**
- Check that `claude-compose-wrapper` is installed and in PATH
- Verify `settings.json` has the correct path to the wrapper
- Check `claude-compose config --check` passes

**Build errors in VS Code:**
- Wrap mode suppresses stderr — run `claude-compose build` in terminal to see errors
- Check that `jq` is available in VS Code's shell environment

**Workspace file not updating:**
- Re-run `claude-compose vscode` to regenerate
- The `.code-workspace` file auto-updates on build in wrap mode

[← Back to README](../README.md)
