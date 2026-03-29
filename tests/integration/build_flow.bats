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
    srv=$(jq -r '.mcpServers["direct-srv"].command' "${TEST_TEMP_DIR}/workspace/${COMPOSE_MCP}")
    [[ "$srv" == "echo" ]]
}

@test "build creates manifest" {
    cd "${TEST_TEMP_DIR}/workspace"
    create_config '{"resources":{"mcp":{"srv":{"command":"echo"}}}}'
    run build "true"
    [[ -f "${TEST_TEMP_DIR}/workspace/${COMPOSE_MANIFEST}" ]]
}

@test "build creates hash file" {
    cd "${TEST_TEMP_DIR}/workspace"
    create_config '{"resources":{"mcp":{"srv":{"command":"echo"}}}}'
    run build "true"
    [[ -f "${TEST_TEMP_DIR}/workspace/${COMPOSE_HASH}" ]]
    local hash_val
    hash_val=$(cat "${TEST_TEMP_DIR}/workspace/${COMPOSE_HASH}")
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

