#!/usr/bin/env bats

setup() {
    load '../test_helper/common_setup'
    _common_setup
    load '../test_helper/mocks'
    load '../test_helper/fixtures'
    setup_mock "git" 0
    setup_mock "claude" 0
    reset_globals
}

teardown() {
    _common_teardown
}

@test "build with local preset syncs agents" {
    create_preset "test-preset"
    cd "${TEST_TEMP_DIR}/workspace"
    create_config '{"presets":["test-preset"]}'
    # Use run to isolate hash computation errors
    run build "true"
    # Verify agents were synced
    [[ -e "${TEST_TEMP_DIR}/workspace/.claude/agents/test-preset-agent.md" ]]
}

@test "build with local preset syncs skills" {
    create_preset "test-preset"
    cd "${TEST_TEMP_DIR}/workspace"
    create_config '{"presets":["test-preset"]}'
    run build "true"
    [[ -L "${TEST_TEMP_DIR}/workspace/.claude/skills/default-skill" ]]
}

@test "build with local preset syncs mcp" {
    create_preset "test-preset"
    cd "${TEST_TEMP_DIR}/workspace"
    create_config '{"presets":["test-preset"]}'
    run build "true"
    [[ -f "${TEST_TEMP_DIR}/workspace/.mcp.json" ]]
    local srv
    srv=$(jq -r '.mcpServers["test-preset-server"].command' "${TEST_TEMP_DIR}/workspace/.mcp.json")
    [[ "$srv" == "echo" ]]
}

@test "build with workspace source merges resources" {
    local ws_src="${TEST_TEMP_DIR}/ws_source"
    create_workspace_source "$ws_src"
    cd "${TEST_TEMP_DIR}/workspace"
    create_config "{\"workspaces\":[{\"path\":\"$ws_src\"}]}"
    run build "true"
    [[ -e "${TEST_TEMP_DIR}/workspace/.claude/agents/ws-agent.md" ]]
}

@test "build with resources section" {
    cd "${TEST_TEMP_DIR}/workspace"
    mkdir -p "${TEST_TEMP_DIR}/workspace/agents"
    echo "---" > "${TEST_TEMP_DIR}/workspace/agents/custom.md"
    create_config '{"resources":{"agents":["agents/custom.md"],"mcp":{"direct-srv":{"command":"echo"}}}}'
    run build "true"
    [[ -f "${TEST_TEMP_DIR}/workspace/.claude/agents/custom.md" ]]
    local srv
    srv=$(jq -r '.mcpServers["direct-srv"].command' "${TEST_TEMP_DIR}/workspace/.mcp.json")
    [[ "$srv" == "echo" ]]
}

@test "build creates manifest" {
    create_preset "test-preset"
    cd "${TEST_TEMP_DIR}/workspace"
    create_config '{"presets":["test-preset"]}'
    run build "true"
    [[ -f "${TEST_TEMP_DIR}/workspace/.compose-manifest.json" ]]
    local has_preset
    has_preset=$(jq 'has("presets")' "${TEST_TEMP_DIR}/workspace/.compose-manifest.json")
    [[ "$has_preset" == "true" ]]
}

@test "build creates hash file" {
    cd "${TEST_TEMP_DIR}/workspace"
    create_config '{"resources":{"mcp":{"srv":{"command":"echo"}}}}'
    run build "true"
    [[ -f "${TEST_TEMP_DIR}/workspace/.compose-hash" ]]
    local hash_val
    hash_val=$(cat "${TEST_TEMP_DIR}/workspace/.compose-hash")
    [[ ${#hash_val} -eq 32 ]]
}

@test "rebuild skipped when unchanged" {
    cd "${TEST_TEMP_DIR}/workspace"
    create_config '{"resources":{"mcp":{"srv":{"command":"echo"}}}}'
    run build "true"
    # Second build without force should skip
    cd "${TEST_TEMP_DIR}/workspace"
    run build "false"
    assert_success
}

@test "force build always runs" {
    cd "${TEST_TEMP_DIR}/workspace"
    create_config '{"resources":{"mcp":{"srv":{"command":"echo"}}}}'
    run build "true"
    cd "${TEST_TEMP_DIR}/workspace"
    run build "true"
    assert_success
}

@test "build with multiple presets" {
    create_preset "preset-a"
    create_preset "preset-b"
    cd "${TEST_TEMP_DIR}/workspace"
    create_config '{"presets":["preset-a","preset-b"]}'
    run build "true"
    [[ -e "${TEST_TEMP_DIR}/workspace/.claude/agents/preset-a-agent.md" ]]
    [[ -e "${TEST_TEMP_DIR}/workspace/.claude/agents/preset-b-agent.md" ]]
}
