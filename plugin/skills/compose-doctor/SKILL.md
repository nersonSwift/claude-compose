---
name: compose-doctor
description: This skill should be used when the user asks to "fix config", "diagnose compose", "что сломалось", "config broken", "not working", "ошибка конфигурации", "doctor", "debug compose", "validate config", "check config", "repair workspace", "почини конфиг", "проблема с compose".
---

# compose-doctor — Diagnose and fix compose workspace problems

Launch the compose-guide agent in diagnostic mode to find and fix problems in the claude-compose workspace configuration.

## Steps

1. Gather diagnostic context before launching the agent:

   ```bash
   # Check config exists
   test -f claude-compose.json && echo "config exists" || echo "no config"

   # Read config contents
   cat claude-compose.json

   # Run validation
   claude-compose config --check 2>&1

   # Check global config
   test -f ~/.claude-compose/global.json && cat ~/.claude-compose/global.json || echo "no global config"

   # Check build state
   ls -la .claude/claude-compose/ 2>/dev/null || echo "no build directory"
   ```

2. Launch the **compose-guide** agent with all gathered context:

   ```
   Agent: compose-guide
   Prompt: "Diagnostic mode. Workspace directory: <cwd>.
   Config file: <path or 'missing'>.
   Validation output: <output from config --check>.
   Config contents: <json or 'file not found'>.
   Global config: <contents or 'not found'>.
   Build state: <ls output or 'no build directory'>.

   Find ALL problems and fix them autonomously. Do not stop until the config
   is fully valid and launchable. Verify by reading back and running jq empty."
   ```

3. After the agent completes, report the summary of what was found and fixed.

## Rules

- Always gather context BEFORE launching the agent — the agent works better with upfront information
- If `claude-compose.json` does not exist, tell the user to run `claude-compose config` or `claude-compose start` first — do not launch the agent
- If validation passes cleanly, tell the user the config looks healthy and ask what specific issue they are experiencing before launching the agent
- Include the user's original error message or complaint in the agent prompt for context
