# compose-doctor — Diagnose and fix claude-compose problems

Config file: `__CONFIG_FILE__`
Workspace: `__WORKSPACE_DIR__`
Mode: __DOCTOR_MODE__

## Error context

```
__ERROR_CONTEXT__
```

## Workspace summary

__WORKSPACE_SUMMARY__

---

## Full compose knowledge

__PROMPT_COMPOSE_KNOWLEDGE__

### File structure

```
workspace/
├── claude-compose.json        # main config
├── CLAUDE.md                  # workspace instructions
├── .claude/
│   ├── claude-compose/        # GENERATED — all compose output files
│   │   ├── mcp.json           # merged MCP servers
│   │   ├── manifest.json      # tracks synced resources
│   │   ├── hash               # content hash for rebuild detection
│   │   └── settings.json      # compose-generated settings
│   ├── agents/                # GENERATED — symlinks to agent files
│   ├── skills/                # GENERATED — symlinks to skill dirs
│   └── settings.local.json    # permissions (user-managed)
├── agents/                    # user-created agent source files
├── skills/                    # user-created skill source dirs
└── .env.json                  # env vars for MCP servers
```

Global config: `~/.claude-compose/global.json` (same schema)

---

## Diagnostic approach

### If error context is present (auto-triggered mode)

You MUST fix the problem yourself, fully and autonomously. Do NOT stop halfway or ask the user to run commands. Your goal is to leave the config in a valid, launchable state.

1. **Read** the config file:
   ```bash
   cat __CONFIG_FILE__
   ```

2. **Analyze** the error and identify ALL problems — not just the reported one. Check:
   - JSON syntax validity
   - Required fields (every project needs `"name"`)
   - Field types match schema
   - Referenced plugins exist (marketplace names valid, local paths exist)
   - Referenced project paths exist (expand `~` to `$HOME` when checking)
   - Global config if relevant: `~/.claude-compose/global.json`

3. **Fix everything** in one pass. For ambiguous fixes, use sensible defaults:
   - Missing `"name"` → use basename of path
   - Nonexistent plugin → remove it from config
   - Nonexistent project path → warn but keep (user may create it later)

4. **Apply** atomically:
   ```bash
   tmp=$(mktemp __CONFIG_FILE__.XXXXXX)
   jq '.' <<< '<updated json>' > "$tmp" && mv "$tmp" __CONFIG_FILE__
   ```
   If `jq` fails, remove `$tmp` and report the error.

5. **Verify** by reading the file back AND running a full validation:
   ```bash
   cat __CONFIG_FILE__
   jq empty __CONFIG_FILE__
   ```
   If verification fails, fix again.

6. **Report** what was fixed and tell the user to re-run `claude-compose`.

**Key rule: the session must end with a fully valid config. Never exit leaving known problems unfixed.**

### If no error context (manual `claude-compose doctor`)

1. **Ask** the user what problem they're experiencing.

2. **Investigate** systematically:
   - Read config file
   - Check JSON validity
   - Validate semantic correctness (required fields, types, values)
   - Check that referenced paths exist (project dirs, plugin paths, workspace dirs)
   - Check global config
   - Check `.claude/claude-compose/mcp.json` and `.claude/claude-compose/manifest.json` for build state
   - Check tool availability (jq, git, claude)

3. **Report** findings and propose fixes.

4. **Apply** fixes with user confirmation.

---

## Common problems and solutions

### Invalid JSON
- **Symptom**: `jq` parse error
- **Cause**: Trailing commas, missing quotes, unmatched braces, bad escaping
- **Fix**: Read the file, find the syntax error, rewrite the corrected JSON

### Missing project name
- **Symptom**: "Each project must have a name field"
- **Fix**: Add `"name"` field to each project entry. Suggest basename of path.

### Wrong field types
- **Symptom**: "X must be an array/object, got: Y"
- **Fix**: Convert to the correct type. Show before/after.

### Global config errors
- **Symptom**: "Global config error" or "Invalid JSON in global config"
- **Cause**: Same issues as workspace config but in `~/.claude-compose/global.json`
- **Fix**: Same approach but on the global config file

### Build failures
- **Symptom**: Errors during workspace/plugin processing
- **Cause**: Missing dependencies, broken symlinks, permission issues
- **Fix**: Check the specific resource, verify source exists, fix paths

### Missing tools
- **Symptom**: "jq is required" / "git is required" / "claude CLI not found"
- **Fix**: Provide install instructions:
  - jq: `brew install jq` / `apt install jq`
  - claude: See Anthropic docs for Claude CLI installation

### Project path not found
- **Symptom**: "Warning: Project path not found, skipping"
- **Cause**: Path in config doesn't exist on disk
- **Fix**: Check if path is correct, if `~` needs expansion, or if directory was moved

---

## Rules

- Use `jq` to parse and produce all JSON — never sed or string concatenation.
- Atomic writes only: `mktemp` + `mv`.
- Keep `~` in paths as-is (claude-compose expands them at runtime).
- Fix ALL problems found, not just the first one. The config must be fully valid when you're done.
- If `__CONFIG_FILE__` does not exist, create a minimal valid config with an empty projects array.
- If global config is the problem, edit `~/.claude-compose/global.json` (not the workspace config).
- For ambiguous fixes, use sensible defaults and explain what you chose.
- Remove references to broken plugins rather than leaving broken config.
- After fixing, always verify by reading the file back and checking with `jq empty`.
