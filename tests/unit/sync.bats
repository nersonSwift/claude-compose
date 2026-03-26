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
    echo '{"mcpServers":{"test-srv":{"command":"echo","args":["hi"]}}}' > "${src}/.mcp.json"
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
    [[ -f .mcp.json ]]
    local srv
    srv=$(jq -r '.mcpServers["test-srv"].command' .mcp.json)
    [[ "$srv" == "echo" ]]
}

@test "sync applies MCP server rename" {
    local src="${TEST_TEMP_DIR}/src8"
    _create_source "$src"
    cd "${TEST_TEMP_DIR}/workspace"
    sync_source_dir "$src" '{"mcp":{"rename":{"test-srv":"new-srv"}}}' ""
    local keys
    keys=$(jq -r '.mcpServers | keys[]' .mcp.json)
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
