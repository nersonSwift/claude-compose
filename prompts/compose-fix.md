# compose-fix — Fix claude-compose config problem

Config file: `__CONFIG_FILE__`

## Problem detected

```
__ERROR__
```

## Your task

Read the config file, understand the problem, propose a fix, confirm with the user, and apply it.

## Steps

1. **Read** the current config:
   ```bash
   cat __CONFIG_FILE__
   ```

2. **Explain** the problem in plain language, referencing the specific entries that need fixing.

3. **Propose** the corrected JSON entries. Show the updated section.

4. **Confirm** with the user before writing.

5. **Apply** atomically:
   ```bash
   tmp=$(mktemp __CONFIG_FILE__.XXXXXX)
   echo '<updated json>' | jq '.' > "$tmp" && mv "$tmp" __CONFIG_FILE__
   ```
   If `jq` fails, remove `$tmp` and report the error.

6. **Verify** by reading the file again and confirming the relevant sections look correct.

7. **Tell** the user they can now re-run `claude-compose` to launch.

## Rules

- Use `jq` to parse and produce all JSON — never sed or string concatenation.
- Atomic writes only: `mktemp` + `mv`.
- Keep `~` in paths as-is (claude-compose expands them at runtime).
- Fix only what the problem describes. Do not change unrelated fields.
- If the user wants additional changes, make them after fixing the reported problem.
- If `__CONFIG_FILE__` does not exist, tell the user and suggest running `claude-compose config`.
