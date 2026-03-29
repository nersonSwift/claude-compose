[← Back to README](../README.md)

# Environment Variables

How claude-compose loads, validates, and isolates environment variables.

## Env File Format

Env files are JSON objects with string values:

```json
{
  "API_KEY": "sk-abc123",
  "DATABASE_URL": "postgres://localhost/mydb",
  "DEBUG": "true"
}
```

All values are converted to strings. Place env files in your workspace and reference them:

```json
{
  "resources": {
    "env_files": [".env.json", ".env.secrets.json"]
  }
}
```

Paths are relative to the workspace directory.

## Loading Order

Environment variables are loaded in this order (later values override earlier ones for the same key):

1. **Global env files** — from `~/.claude-compose/global.json` → `resources.env_files`
2. **Local env files** — from workspace `claude-compose.json` → `resources.env_files`
3. **Source env files** — from synced workspaces (with prefix — see below)

## Using Env Vars in MCP Config

Reference env vars in MCP server definitions using `${VAR}` syntax:

```json
{
  "resources": {
    "mcp": {
      "database": {
        "command": "npx",
        "args": ["@modelcontextprotocol/server-postgres"],
        "env": {
          "DATABASE_URL": "${DB_URL}"
        }
      }
    },
    "env_files": [".env.json"]
  }
}
```

`.env.json`:
```json
{
  "DB_URL": "postgres://localhost/mydb"
}
```

At launch, `${DB_URL}` is replaced with `postgres://localhost/mydb`.

## Source Prefixing

When MCP servers are synced from external workspaces, their env var references are prefixed to prevent conflicts:

```
{source_name}_{hash4}_VARNAME
```

**Example:** A workspace named `team-tools` at path `/Users/me/ws/team` (hash: `a1b2`):
- Source env: `API_KEY=secret`
- Exported as: `team_tools_a1b2_API_KEY=secret`
- MCP config references: `${team_tools_a1b2_API_KEY}`

This happens automatically — no manual configuration needed. Only variables defined in the source workspace's `env_files` are prefixed. System variables like `HOME` or `PATH` are never modified.

## Blocked Variables

For security, the following environment variable keys are **rejected** with a warning:

### System & Shell
`PATH`, `HOME`, `SHELL`, `USER`, `LOGNAME`, `IFS`, `CDPATH`, `TMPDIR`, `EDITOR`, `VISUAL`

### Dynamic Linker
`LD_PRELOAD`, `LD_LIBRARY_PATH`, `LD_AUDIT`, `LD_CONFIG`, `DYLD_*`, `GCONV_PATH`

### Shell Execution
`BASH_ENV`, `ENV`, `BASH_FUNC_*`, `PROMPT_COMMAND`, `GLOBIGNORE`, `HISTFILE`

### Language Paths
`PYTHONPATH`, `NODE_PATH`, `RUBYLIB`, `PERL5LIB`, `NODE_OPTIONS`, `JAVA_TOOL_OPTIONS`, `_JAVA_OPTIONS`

### Git
`GIT_SSH_COMMAND`, `GIT_EXEC_PATH`, `GIT_CONFIG_GLOBAL`, `GIT_DIR`, `GIT_WORK_TREE`, `GIT_AUTHOR_*`, `GIT_COMMITTER_*`

### API Keys
`ANTHROPIC_*`, `CLAUDE_*`, `OPENAI_*`

### Network / TLS
`http_proxy`, `https_proxy`, `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `no_proxy`, `NO_PROXY`, `SSL_CERT_FILE`, `SSL_CERT_DIR`, `CURL_CA_BUNDLE`, `REQUESTS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`

### Config
`XDG_CONFIG_HOME`, `XDG_DATA_HOME`

## Key Validation

Keys must be valid POSIX identifiers:
- Start with a letter or underscore
- Contain only letters, digits, and underscores
- Pattern: `[a-zA-Z_][a-zA-Z0-9_]*`

Invalid keys are skipped with a warning.

## Best Practices

1. **Separate secrets from config** — use `.env.secrets.json` for API keys and add it to `.gitignore`
2. **Use descriptive keys** — `MCP_DB_URL` is clearer than `URL`
3. **Don't duplicate system vars** — claude-compose blocks them for security
4. **Check with dry-run** — `claude-compose --dry-run` shows which env files are loaded and how many variables each contains

[← Back to README](../README.md)
