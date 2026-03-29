#!/usr/bin/env bats

setup() {
    load '../test_helper/common_setup'
    _common_setup
    load '../test_helper/fixtures'
}

teardown() {
    _common_teardown
}

# Helper: create a source dir with agent, skill, and MCP
_create_source() {
    local src="$1"
    mkdir -p "${src}/.claude/agents"
    mkdir -p "${src}/.claude/skills/test-skill"
    cat > "${src}/.claude/agents/test-agent.md" <<'EOF'
---
name: test-agent
description: Test
---
Body
EOF
    echo "skill content" > "${src}/.claude/skills/test-skill/SKILL.md"
    mkdir -p "${src}/.claude/claude-compose"
    echo '{"mcpServers":{"test-srv":{"command":"echo","args":["hi"]}}}' > "${src}/.claude/claude-compose/mcp.json"
}

# ── sync_source_dir ──────────────────────────────────────────────────

@test "sync creates agent symlinks" {
    local src="${TEST_TEMP_DIR}/src1"
    _create_source "$src"
    cd "${TEST_TEMP_DIR}/workspace"
    sync_source_dir "$src" '{}' "test"
    [[ -L .claude/agents/test-agent.md ]]
}

@test "sync applies agent include filter" {
    local src="${TEST_TEMP_DIR}/src2"
    _create_source "$src"
    cat > "${src}/.claude/agents/skip-agent.md" <<'EOF'
---
name: skip-agent
---
EOF
    cat > "${src}/.claude/agents/keep-agent.md" <<'EOF'
---
name: keep-agent
---
EOF
    cd "${TEST_TEMP_DIR}/workspace"
    sync_source_dir "$src" '{"agents":{"include":["keep-*"]}}' ""
    [[ -e .claude/agents/keep-agent.md ]]
    [[ ! -e .claude/agents/skip-agent.md ]]
}

@test "sync applies agent exclude filter" {
    local src="${TEST_TEMP_DIR}/src3"
    _create_source "$src"
    cat > "${src}/.claude/agents/secret-agent.md" <<'EOF'
---
name: secret-agent
---
EOF
    cd "${TEST_TEMP_DIR}/workspace"
    sync_source_dir "$src" '{"agents":{"exclude":["secret-*"]}}' ""
    [[ -e .claude/agents/test-agent.md ]]
    [[ ! -e .claude/agents/secret-agent.md ]]
}

@test "sync applies agent rename" {
    local src="${TEST_TEMP_DIR}/src4"
    _create_source "$src"
    cd "${TEST_TEMP_DIR}/workspace"
    sync_source_dir "$src" '{"agents":{"rename":{"test-agent":"renamed-agent"}}}' ""
    [[ -f .claude/agents/renamed-agent.md ]]
    [[ ! -e .claude/agents/test-agent.md ]]
    # Check frontmatter was rewritten
    run grep "^name:" .claude/agents/renamed-agent.md
    assert_output "name: renamed-agent"
}

@test "sync creates skill symlinks" {
    local src="${TEST_TEMP_DIR}/src5"
    _create_source "$src"
    cd "${TEST_TEMP_DIR}/workspace"
    sync_source_dir "$src" '{}' ""
    [[ -L .claude/skills/test-skill ]]
}

@test "sync applies skill filter" {
    local src="${TEST_TEMP_DIR}/src6"
    _create_source "$src"
    mkdir -p "${src}/.claude/skills/excluded-skill"
    echo "x" > "${src}/.claude/skills/excluded-skill/SKILL.md"
    cd "${TEST_TEMP_DIR}/workspace"
    sync_source_dir "$src" '{"skills":{"exclude":["excluded-*"]}}' ""
    [[ -L .claude/skills/test-skill ]]
    [[ ! -e .claude/skills/excluded-skill ]]
}

@test "sync merges MCP servers" {
    local src="${TEST_TEMP_DIR}/src7"
    _create_source "$src"
    cd "${TEST_TEMP_DIR}/workspace"
    sync_source_dir "$src" '{}' "test"
    [[ -f "$COMPOSE_MCP" ]]
    local srv
    srv=$(jq -r '.mcpServers["test-srv"].command' "$COMPOSE_MCP")
    [[ "$srv" == "echo" ]]
}

@test "sync applies MCP server rename" {
    local src="${TEST_TEMP_DIR}/src8"
    _create_source "$src"
    cd "${TEST_TEMP_DIR}/workspace"
    sync_source_dir "$src" '{"mcp":{"rename":{"test-srv":"new-srv"}}}' ""
    local keys
    keys=$(jq -r '.mcpServers | keys[]' "$COMPOSE_MCP")
    [[ "$keys" == *"new-srv"* ]]
    [[ "$keys" != *"test-srv"* ]]
}

@test "sync skips symlink escaping source" {
    local src="${TEST_TEMP_DIR}/src9"
    mkdir -p "${src}/.claude/agents"
    # Create a file outside source dir
    echo "outside" > "${TEST_TEMP_DIR}/outside.md"
    # Create symlink inside source pointing outside
    ln -sf "${TEST_TEMP_DIR}/outside.md" "${src}/.claude/agents/escape-agent.md"
    cd "${TEST_TEMP_DIR}/workspace"
    run sync_source_dir "$src" '{}' ""
    assert_success
    [[ ! -e .claude/agents/escape-agent.md ]]
}

@test "sync detects CLAUDE.md" {
    local src="${TEST_TEMP_DIR}/src10"
    _create_source "$src"
    echo "# CLAUDE" > "${src}/CLAUDE.md"
    cd "${TEST_TEMP_DIR}/workspace"
    sync_source_dir "$src" '{}' "test"
    [[ ${#CURRENT_SOURCE_ADD_DIRS[@]} -gt 0 ]]
}

@test "sync handles empty source" {
    local src="${TEST_TEMP_DIR}/src11"
    mkdir -p "$src"
    cd "${TEST_TEMP_DIR}/workspace"
    run sync_source_dir "$src" '{}' ""
    assert_success
    [[ ${#CURRENT_SOURCE_AGENTS[@]} -eq 0 ]]
}

# ── write_source_manifest ────────────────────────────────────────────

@test "write_source_manifest updates MANIFEST_JSON" {
    CURRENT_SOURCE_AGENTS=("agent.md")
    CURRENT_SOURCE_SKILLS=("skill1")
    CURRENT_SOURCE_MCP_SERVERS=("srv1")
    CURRENT_SOURCE_ADD_DIRS=()
    CURRENT_SOURCE_PROJECT_DIRS=()
    CURRENT_SOURCE_SYSTEM_PROMPT_FILES=()
    CURRENT_SOURCE_SETTINGS_FILES=()
    CURRENT_SOURCE_NAME="test-source"
    write_source_manifest "presets" "my-preset"
    local agents
    agents=$(echo "$MANIFEST_JSON" | jq -r '.presets["my-preset"].agents[0]')
    [[ "$agents" == "agent.md" ]]
}

@test "write_source_manifest tracks agents" {
    CURRENT_SOURCE_AGENTS=("a.md" "b.md")
    CURRENT_SOURCE_SKILLS=()
    CURRENT_SOURCE_MCP_SERVERS=()
    CURRENT_SOURCE_ADD_DIRS=()
    CURRENT_SOURCE_PROJECT_DIRS=()
    CURRENT_SOURCE_SYSTEM_PROMPT_FILES=()
    CURRENT_SOURCE_SETTINGS_FILES=()
    CURRENT_SOURCE_NAME="src"
    write_source_manifest "presets" "test"
    local count
    count=$(echo "$MANIFEST_JSON" | jq '.presets["test"].agents | length')
    [[ "$count" == "2" ]]
}

@test "write_source_manifest tracks add_dirs with claude_md" {
    CURRENT_SOURCE_AGENTS=()
    CURRENT_SOURCE_SKILLS=()
    CURRENT_SOURCE_MCP_SERVERS=()
    CURRENT_SOURCE_ADD_DIRS=("/some/path|true")
    CURRENT_SOURCE_PROJECT_DIRS=()
    CURRENT_SOURCE_SYSTEM_PROMPT_FILES=()
    CURRENT_SOURCE_SETTINGS_FILES=()
    CURRENT_SOURCE_NAME="src"
    write_source_manifest "presets" "test"
    local path_val cm_val
    path_val=$(echo "$MANIFEST_JSON" | jq -r '.presets["test"].add_dirs[0].path')
    cm_val=$(echo "$MANIFEST_JSON" | jq -r '.presets["test"].add_dirs[0].claude_md')
    [[ "$path_val" == "/some/path" ]]
    [[ "$cm_val" == "true" ]]
}

@test "write_source_manifest handles empty arrays" {
    CURRENT_SOURCE_AGENTS=()
    CURRENT_SOURCE_SKILLS=()
    CURRENT_SOURCE_MCP_SERVERS=()
    CURRENT_SOURCE_ADD_DIRS=()
    CURRENT_SOURCE_PROJECT_DIRS=()
    CURRENT_SOURCE_SYSTEM_PROMPT_FILES=()
    CURRENT_SOURCE_SETTINGS_FILES=()
    CURRENT_SOURCE_NAME=""
    write_source_manifest "presets" "empty"
    local agent_count
    agent_count=$(echo "$MANIFEST_JSON" | jq '.presets["empty"].agents | length')
    [[ "$agent_count" == "0" ]]
}

# ── process_workspace_source: claude_md cascade ──────────────────

@test "process_workspace_source: claude_md false cascades to projects" {
    # Create a workspace with a project that has claude_md: true
    local ws_dir="${TEST_TEMP_DIR}/ws-cascade"
    local proj_dir="${TEST_TEMP_DIR}/proj-a"
    mkdir -p "$ws_dir" "$proj_dir"
    echo '{"projects":[{"path":"'"$proj_dir"'","name":"proj-a","claude_md":true}]}' > "${ws_dir}/claude-compose.json"

    cd "${TEST_TEMP_DIR}/workspace"
    PROCESSED_WORKSPACES=()
    DIRECT_PROJECT_PATHS=()
    MANIFEST_JSON='{"global":{},"workspaces":{},"resources":{}}'

    local ws_json='{"path":"'"$ws_dir"'","claude_md":false}'
    process_workspace_source "$ws_json"

    # Resolve ws_dir the same way process_workspace_source does (macOS /private/var symlinks)
    local resolved_ws_dir
    resolved_ws_dir=$(cd "$ws_dir" && pwd -P)

    # The project_dirs in manifest should have claude_md=false (cascade)
    local cm_val
    cm_val=$(echo "$MANIFEST_JSON" | jq -r --arg k "$resolved_ws_dir" '.workspaces[$k].project_dirs[0].claude_md')
    [[ "$cm_val" == "false" ]]
}

@test "process_workspace_source: claude_md_overrides takes priority over cascade" {
    local ws_dir="${TEST_TEMP_DIR}/ws-override"
    local proj_a="${TEST_TEMP_DIR}/proj-a"
    local proj_b="${TEST_TEMP_DIR}/proj-b"
    mkdir -p "$ws_dir" "$proj_a" "$proj_b"
    echo '{"projects":[{"path":"'"$proj_a"'","name":"proj-a"},{"path":"'"$proj_b"'","name":"proj-b"}]}' > "${ws_dir}/claude-compose.json"

    cd "${TEST_TEMP_DIR}/workspace"
    PROCESSED_WORKSPACES=()
    DIRECT_PROJECT_PATHS=()
    MANIFEST_JSON='{"global":{},"workspaces":{},"resources":{}}'

    local ws_json='{"path":"'"$ws_dir"'","claude_md":false,"claude_md_overrides":{"proj-a":true}}'
    process_workspace_source "$ws_json"

    local resolved_ws_dir
    resolved_ws_dir=$(cd "$ws_dir" && pwd -P)

    # proj-a should be true (override), proj-b should be false (cascade)
    local cm_a cm_b
    cm_a=$(echo "$MANIFEST_JSON" | jq -r --arg k "$resolved_ws_dir" --arg p "$proj_a" '.workspaces[$k].project_dirs[] | select(.path == $p) | .claude_md')
    cm_b=$(echo "$MANIFEST_JSON" | jq -r --arg k "$resolved_ws_dir" --arg p "$proj_b" '.workspaces[$k].project_dirs[] | select(.path == $p) | .claude_md')
    [[ "$cm_a" == "true" ]]
    [[ "$cm_b" == "false" ]]
}

@test "process_workspace_source: direct project wins over workspace indirect" {
    local ws_dir="${TEST_TEMP_DIR}/ws-direct"
    local proj_dir="${TEST_TEMP_DIR}/proj-direct"
    mkdir -p "$ws_dir" "$proj_dir"
    echo '{"projects":[{"path":"'"$proj_dir"'","name":"proj-direct","claude_md":true}]}' > "${ws_dir}/claude-compose.json"

    cd "${TEST_TEMP_DIR}/workspace"
    PROCESSED_WORKSPACES=()
    DIRECT_PROJECT_PATHS=("$proj_dir")
    MANIFEST_JSON='{"global":{},"workspaces":{},"resources":{}}'

    local ws_json='{"path":"'"$ws_dir"'"}'
    process_workspace_source "$ws_json"

    local resolved_ws_dir
    resolved_ws_dir=$(cd "$ws_dir" && pwd -P)

    # proj-direct should be skipped (not in manifest project_dirs)
    local proj_count
    proj_count=$(echo "$MANIFEST_JSON" | jq --arg k "$resolved_ws_dir" '.workspaces[$k].project_dirs | length')
    [[ "$proj_count" == "0" ]]
}

@test "process_workspace_source: collects workspace plugins" {
    local ws_dir="${TEST_TEMP_DIR}/ws-plugins"
    local plugin_dir="${ws_dir}/my-plugin"
    mkdir -p "$plugin_dir"
    echo '{"plugins":["./my-plugin"]}' > "${ws_dir}/claude-compose.json"

    cd "${TEST_TEMP_DIR}/workspace"
    PROCESSED_WORKSPACES=()
    DIRECT_PROJECT_PATHS=()
    PLUGIN_DIRS=()
    MANIFEST_JSON='{"global":{},"workspaces":{},"resources":{}}'

    local ws_json='{"path":"'"$ws_dir"'"}'
    process_workspace_source "$ws_json"

    [[ ${#PLUGIN_DIRS[@]} -eq 1 ]]
    [[ "${PLUGIN_DIRS[0]}" == *"/my-plugin" ]]
}
