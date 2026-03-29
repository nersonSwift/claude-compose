#!/usr/bin/env bats

setup() {
    load '../test_helper/common_setup'
    _common_setup
    load '../test_helper/mocks'
    load '../test_helper/fixtures'
    # Mock claude and git for all command tests
    setup_mock "claude" 0
    setup_mock "git" 0
}

teardown() {
    _common_teardown
}

# ── cmd_config ───────────────────────────────────────────────────────

@test "cmd_config -y creates minimal config" {
    reset_globals
    CONFIG_YES=true
    SUBCOMMAND="config"
    CONFIG_PATH="${TEST_TEMP_DIR}/myproject"
    mkdir -p "$CONFIG_PATH"
    CONFIG_FILE="${TEST_TEMP_DIR}/workspace/claude-compose.json"
    rm -f "$CONFIG_FILE"
    cmd_config
    [[ -f "$CONFIG_FILE" ]]
    local name
    name=$(jq -r '.projects[0].name' "$CONFIG_FILE")
    [[ "$name" == "myproject" ]]
}

@test "cmd_config -y fails when config exists" {
    reset_globals
    CONFIG_YES=true
    SUBCOMMAND="config"
    CONFIG_PATH="${TEST_TEMP_DIR}/myproject"
    CONFIG_FILE="${TEST_TEMP_DIR}/workspace/claude-compose.json"
    echo '{}' > "$CONFIG_FILE"
    run cmd_config
    assert_failure
}

@test "cmd_config -y requires path" {
    reset_globals
    CONFIG_YES=true
    SUBCOMMAND="config"
    CONFIG_PATH=""
    CONFIG_FILE="${TEST_TEMP_DIR}/workspace/claude-compose.json"
    rm -f "$CONFIG_FILE"
    run cmd_config
    assert_failure
}

# ── cmd_migrate ──────────────────────────────────────────────────────

@test "cmd_migrate missing path exits 1" {
    reset_globals
    SUBCOMMAND="migrate"
    MIGRATE_PATH=""
    run cmd_migrate
    assert_failure
}

@test "cmd_migrate non-existent dir exits 1" {
    reset_globals
    SUBCOMMAND="migrate"
    MIGRATE_PATH="/nonexistent/path"
    run cmd_migrate
    assert_failure
}

@test "cmd_migrate discovers .mcp.json" {
    reset_globals
    local proj="${TEST_TEMP_DIR}/project"
    mkdir -p "$proj"
    echo '{"mcpServers":{"srv":{"command":"echo"}}}' > "$proj/.mcp.json"
    SUBCOMMAND="migrate"
    MIGRATE_PATH="$proj"
    ORIGINAL_CWD="${TEST_TEMP_DIR}/workspace"
    CONFIG_FILE="${TEST_TEMP_DIR}/workspace/claude-compose.json"
    cd "${TEST_TEMP_DIR}/workspace"
    cmd_migrate
    [[ -f "${TEST_TEMP_DIR}/workspace/${COMPOSE_MCP}" ]]
    local srv
    srv=$(jq -r '.mcpServers.srv.command' "${TEST_TEMP_DIR}/workspace/${COMPOSE_MCP}")
    [[ "$srv" == "echo" ]]
}

@test "cmd_migrate discovers agents" {
    reset_globals
    local proj="${TEST_TEMP_DIR}/project2"
    mkdir -p "$proj/.claude/agents"
    echo "---" > "$proj/.claude/agents/test.md"
    SUBCOMMAND="migrate"
    MIGRATE_PATH="$proj"
    ORIGINAL_CWD="${TEST_TEMP_DIR}/workspace"
    CONFIG_FILE="${TEST_TEMP_DIR}/workspace/claude-compose.json"
    cd "${TEST_TEMP_DIR}/workspace"
    cmd_migrate
    [[ -f "${TEST_TEMP_DIR}/workspace/.claude/agents/test.md" ]]
}

@test "cmd_migrate dry-run shows files" {
    reset_globals
    local proj="${TEST_TEMP_DIR}/project3"
    mkdir -p "$proj"
    echo '{"mcpServers":{}}' > "$proj/.mcp.json"
    DRY_RUN=true
    SUBCOMMAND="migrate"
    MIGRATE_PATH="$proj"
    ORIGINAL_CWD="${TEST_TEMP_DIR}/workspace"
    CONFIG_FILE="${TEST_TEMP_DIR}/workspace/claude-compose.json"
    run cmd_migrate
    assert_success
    # Should not actually copy files
    [[ ! -f "${TEST_TEMP_DIR}/workspace/${COMPOSE_MCP}" ]]
}

# ── cmd_copy ─────────────────────────────────────────────────────────

@test "cmd_copy missing source exits 1" {
    reset_globals
    SUBCOMMAND="copy"
    COPY_SOURCE=""
    run cmd_copy
    assert_failure
}

@test "cmd_copy non-existent source exits 1" {
    reset_globals
    SUBCOMMAND="copy"
    COPY_SOURCE="/nonexistent"
    run cmd_copy
    assert_failure
}

@test "cmd_copy creates destination structure" {
    reset_globals
    local src_ws="${TEST_TEMP_DIR}/src_ws"
    local dest_ws="${TEST_TEMP_DIR}/dest_ws"
    mkdir -p "$src_ws/.claude/agents"
    echo '{"projects":[]}' > "$src_ws/claude-compose.json"
    echo "---" > "$src_ws/.claude/agents/a.md"
    SUBCOMMAND="copy"
    COPY_SOURCE="$src_ws"
    COPY_DEST="$dest_ws"
    CONFIG_FILE="claude-compose.json"
    cmd_copy
    [[ -f "$dest_ws/claude-compose.json" ]]
    [[ -f "$dest_ws/.claude/agents/a.md" ]]
}

# ── cmd_instructions ─────────────────────────────────────────────────

@test "cmd_instructions runs without error" {
    reset_globals
    create_config '{"projects":[{"name":"app","path":"/tmp/app"}]}'
    run cmd_instructions
    assert_success
}

@test "cmd_instructions runs with resources" {
    reset_globals
    create_config '{"projects":[],"resources":{"agents":["a.md","b.md"],"skills":[],"mcp":{"s":{"command":"echo"}},"env_files":[]}}'
    run cmd_instructions
    assert_success
}

# ── cmd_build ────────────────────────────────────────────────────────

@test "cmd_build with valid config" {
    reset_globals
    cd "${TEST_TEMP_DIR}/workspace"
    create_config '{"projects":[{"name":"app","path":"/tmp/app"}]}'
    BUILD_FORCE=true
    run cmd_build
    assert_success
}

@test "cmd_build dry-run" {
    reset_globals
    cd "${TEST_TEMP_DIR}/workspace"
    create_config '{"projects":[{"name":"app","path":"/tmp/app"}]}'
    DRY_RUN=true
    run cmd_build
    assert_success
}

# ── cmd_doctor / cmd_start ───────────────────────────────────────────

@test "cmd_doctor calls claude" {
    reset_globals
    run cmd_doctor
    assert_success
    assert_mock_called_with "claude" "--system-prompt"
}

@test "cmd_start calls claude" {
    reset_globals
    run cmd_start
    assert_success
    assert_mock_called_with "claude" "--system-prompt"
}
