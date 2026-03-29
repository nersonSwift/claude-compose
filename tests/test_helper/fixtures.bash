#!/usr/bin/env bash

# Fixture helpers for claude-compose bats tests

# Create a config file with given JSON content
# $1 = path (optional, defaults to CONFIG_FILE), $2 = JSON content
create_config() {
    local path content
    if [[ $# -ge 2 ]]; then
        path="$1"
        content="$2"
    else
        path="$CONFIG_FILE"
        content="$1"
    fi
    mkdir -p "$(dirname "$path")"
    echo "$content" > "$path"
    if [[ "$path" == "$CONFIG_FILE" ]]; then
        LOCK_FILE="${path%.json}.lock.json"
    fi
}

# Create a preset directory with standard structure
# $1 = preset name
create_preset() {
    local name="$1"
    local preset_dir="${PRESETS_DIR}/${name}"

    mkdir -p "${preset_dir}/.claude/agents"
    mkdir -p "${preset_dir}/.claude/skills/default-skill"

    # Preset config — list agents, skills, and MCP in resources
    cat > "${preset_dir}/claude-compose-preset.json" <<EOF
{
    "resources": {
        "agents": [".claude/agents/${name}-agent.md"],
        "skills": [".claude/skills/default-skill"],
        "mcp": {
            "${name}-server": {
                "command": "echo",
                "args": ["test"]
            }
        }
    }
}
EOF

    # Agent with frontmatter
    cat > "${preset_dir}/.claude/agents/${name}-agent.md" <<EOF
---
name: ${name}-agent
description: Test agent for ${name}
---

# ${name} Agent

This is a test agent.
EOF

    # Skill
    cat > "${preset_dir}/.claude/skills/default-skill/SKILL.md" <<EOF
---
name: default-skill
description: Default skill for ${name}
---

# Default Skill

Test skill content.
EOF

    # MCP config (used by sync_source_dir for workspace-style processing)
    mkdir -p "${preset_dir}/${COMPOSE_DIR}"
    cat > "${preset_dir}/${COMPOSE_MCP}" <<EOF
{
    "mcpServers": {
        "${name}-server": {
            "command": "echo",
            "args": ["test"]
        }
    }
}
EOF
}

# Create a workspace source directory with standard structure
# $1 = path
create_workspace_source() {
    local path="$1"
    mkdir -p "${path}/.claude/agents"

    cat > "${path}/.claude/agents/ws-agent.md" <<EOF
---
name: ws-agent
description: Workspace agent
---

# Workspace Agent
EOF

    mkdir -p "${path}/${COMPOSE_DIR}"
    cat > "${path}/${COMPOSE_MCP}" <<EOF
{
    "mcpServers": {
        "ws-server": {
            "command": "echo",
            "args": ["workspace"]
        }
    }
}
EOF

    cat > "${path}/claude-compose.json" <<EOF
{
    "projects": []
}
EOF
}

# Create a test plugin directory
# $1 = path, $2 = name (optional, default "test-plugin")
create_test_plugin() {
    local path="$1" name="${2:-test-plugin}"
    mkdir -p "$path/.claude-plugin"
    echo "{\"name\":\"$name\",\"version\":\"1.0.0\"}" > "$path/.claude-plugin/plugin.json"
}

# Create a lock file
# $1 = source key, $2 = version, $3 = tag, $4 = spec (optional)
create_lock_file() {
    local source_key="$1"
    local version="$2"
    local tag="$3"
    local spec="${4:-}"
    local now
    now=$(date -u +%s 2>/dev/null || date +%s)

    local lock_json
    lock_json=$(jq -n \
        --arg key "$source_key" \
        --arg ver "$version" \
        --arg tag "$tag" \
        --arg spec "$spec" \
        --arg ts "$now" \
        '{registries: {($key): {resolved: $ver, tag: $tag, spec: $spec, checked_at: ($ts | tonumber)}}}')

    mkdir -p "$(dirname "$LOCK_FILE")"
    echo "$lock_json" > "$LOCK_FILE"
}

# Create a JSON env file
# $1 = path, $2 = JSON content
create_env_file() {
    local path="$1"
    local content="$2"
    mkdir -p "$(dirname "$path")"
    echo "$content" > "$path"
}
