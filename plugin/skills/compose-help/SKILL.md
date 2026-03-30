---
name: compose-help
description: This skill should be used when the user asks "how to add project", "как настроить", "help with compose", "explain workspace", "how to configure MCP", "add plugin", "compose guide", "how does compose work", "workspace setup help", "add agent to workspace", "как добавить проект", "настройка воркспейса".
---

# compose-help — Get help with claude-compose

Launch the compose-guide agent to answer questions about claude-compose configuration, architecture, and best practices.

## Steps

1. Gather workspace context before launching the agent:

   ```bash
   # Read current config for context
   cat claude-compose.json 2>/dev/null || echo "no config file"

   # Note current directory
   pwd
   ```

2. Determine the user's question category:
   - **Adding resources** — how to add projects, agents, skills, MCP servers, env files, plugins, or workspaces
   - **Configuration** — how to edit config, what fields mean, schema questions
   - **Architecture** — how compose works, workspace model, build process
   - **Best practices** — conventions, recommendations, patterns
   - **Migration** — moving from existing Claude Code project to compose workspace

3. Launch the **compose-guide** agent with the user's question and workspace context:

   ```
   Agent: compose-guide
   Prompt: "Help mode. Workspace directory: <cwd>.
   Current config: <json contents or 'no config file'>.

   User question: <the user's original question>.

   Answer the question using compose knowledge. Show concrete examples
   with JSON config snippets where relevant. If the question involves
   modifying config, show the exact changes needed for this workspace."
   ```

4. The agent answers directly — no further action needed from the skill.

## Rules

- Always pass the current config contents to the agent so it can give context-aware answers
- If there is no config file, the agent can still answer conceptual questions
- Do not attempt to answer compose questions directly — always delegate to the compose-guide agent which has the full knowledge base
- If the user's question is unclear, ask for clarification before launching the agent
