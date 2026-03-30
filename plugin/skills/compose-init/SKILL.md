---
name: compose-init
description: Initialize CLAUDE.md for all projects and the workspace. Runs /init in each project via parallel agents, then generates a cross-project workspace CLAUDE.md.
---

# compose-init — Initialize workspace and project CLAUDE.md files

## Overview

This skill initializes CLAUDE.md files across the entire compose workspace:
- For each project — via `/init` (delegated to parallel agents)
- For the workspace itself — a cross-project CLAUDE.md synthesized from project context

## Phase 1: Gather workspace context

1. Read `claude-compose.json` and the workspace CLAUDE.md to understand workspace structure and what is managed by build.

2. Read `claude-compose.json` to get the exact list of projects:
   ```bash
   jq -r '.projects[] | "\(.name) → \(.path)"' claude-compose.json
   ```
   Record each project's `name` (alias for `name://` references) and `path`.

3. Check which projects already have CLAUDE.md:
   ```bash
   # For each project path:
   test -f <project_path>/CLAUDE.md && echo "exists" || echo "missing"
   ```

4. Check if the workspace already has CLAUDE.md:
   ```bash
   test -f CLAUDE.md && echo "exists" || echo "missing"
   ```

## Phase 2: Initialize projects (parallel agents)

For each **direct project** (from `projects[]` in config) that does **NOT** have a CLAUDE.md, launch an Agent in parallel:

```
Agent prompt: "Go to directory <project_path>. This project is called '<project_name>'.
Run /init to initialize CLAUDE.md for this project. Work autonomously — do not ask the user questions, answer /init prompts based on the project's code and structure.
Do not modify any existing files other than creating CLAUDE.md."
```

Rules:
- Launch all agents **in parallel** — one per project
- **Skip** projects that already have CLAUDE.md
- **Do NOT initialize** projects from connected workspaces — those belong to other workspaces
- If ALL projects already have CLAUDE.md, skip this phase entirely and tell the user

Wait for all agents to complete before proceeding.

## Phase 3: Generate workspace CLAUDE.md

### 3.0 — Check existing workspace CLAUDE.md

If workspace CLAUDE.md already exists:
- Read it and show the current content to the user
- Ask: "Workspace CLAUDE.md already exists. Do you want to update it or skip?"
- If user chooses to skip — go directly to Phase 4
- If user chooses to update — continue with 3.1, using existing content as baseline

### 3.1 — Read project context

Read every project's CLAUDE.md (both newly created and pre-existing) to understand:
- What each project does
- Tech stack and build commands
- Architecture patterns

Also read CLAUDE.md from connected workspaces (from `workspaces[]` in config) for additional context — but do NOT modify them.

### 3.2 — Ask the user (structured form)

Use the AskUserQuestion tool to collect workspace context. Ask all questions in a single structured form:

```
Project CLAUDE.md files are ready. To generate the workspace CLAUDE.md, I need some context:

1. **Workspace purpose** — Why does this workspace exist? What problem does the combination of projects solve?

2. **Project relationships** — How are the projects connected? (e.g., "project-a is the app, project-b is its SDK", "project-c is a reference/docs workspace")

3. **Cross-project rules** — Any conventions that must apply across ALL projects? (e.g., coding style, language, naming patterns). Leave blank if none.

4. **Common workflows** — Typical multi-project scenarios? (e.g., "when changing API in X, update types in Y"). Leave blank if none.
```

Wait for the answer before proceeding.

### 3.3 — Generate workspace CLAUDE.md

Write `CLAUDE.md` in the workspace root. **IMPORTANT rules:**

**Language:** Always write in English, regardless of the user's language. Translate user's answers if needed.

**Project references:** Use the `name://` alias system, NOT absolute paths. Each project has a `name` field in `claude-compose.json` — use it as `name://path/to/file` to reference files. When referring to a project itself, use its alias name. Example: write "letterly" and `letterly://Sources/App/main.swift`, not `/Users/user/Code/Letterly/Sources/App/main.swift`.

**Structure:**

```markdown
# CLAUDE.md

## Workspace Purpose
<Why this workspace exists. What problem the combination of projects solves.>

## Projects
<For each DIRECT project (from projects[] in config): alias + one-line description.
How projects relate to each other. Use aliases only — no absolute paths.>

## Connected Workspaces
<For each connected workspace (from workspaces[] in config): name + why it's connected.
What context it provides. This section is SEPARATE from Projects.
Only include if there are connected workspaces.>

## Cross-Project Rules
<Conventions that apply across ALL projects in this workspace.>

## Workflows
<Common multi-project scenarios.>
```

**Content rules:**
- **Do NOT duplicate** information already in project CLAUDE.md files — reference projects by alias instead
- **Omit empty sections** — if there are no cross-project rules, don't include that section
- **Keep it concise** — workspace CLAUDE.md should be short and focused on cross-project context
- **No boilerplate** — skip generic advice like "follow best practices"
- **No absolute paths** — use `name://` aliases (e.g. `myapp://src/file.ts`)

### 3.4 — Confirm before writing

Show the generated CLAUDE.md to the user and ask for confirmation before writing the file.

## Phase 4: Summary

After completion, show:

```
Workspace initialized:
  - Projects with new CLAUDE.md: <list or "none">
  - Projects already had CLAUDE.md: <list or "none">
  - Workspace CLAUDE.md: <created / updated / skipped>
```

## Rules

- **Never overwrite** existing CLAUDE.md files without explicit user permission
- **Workspace CLAUDE.md goes in the workspace root** — not inside `.claude/` or any project directory
- **Project CLAUDE.md stays in the project directory** — the workspace does not manage it after creation
- **Do NOT touch projects from connected workspaces** — only read their CLAUDE.md for context
- **Always write CLAUDE.md content in English** — translate user input if needed
- **Always use project aliases** — never hardcode absolute paths in CLAUDE.md
- If no projects are configured, tell the user to run `claude-compose config` first
