#!/usr/bin/env bats

setup() {
    load '../test_helper/common_setup'
    _common_setup
    load '../test_helper/mocks'
    load '../test_helper/fixtures'
    setup_mock "claude" 0
    setup_mock "git" 0
}

teardown() {
    _common_teardown
}

@test "main dry-run shows CLAUDE_ARGS" {
    cd "${TEST_TEMP_DIR}/workspace"
    local proj="${TEST_TEMP_DIR}/proj1"
    mkdir -p "$proj"
    create_config "{\"projects\":[{\"name\":\"app\",\"path\":\"$proj\"}]}"
    reset_globals
    CONFIG_FILE="${TEST_TEMP_DIR}/workspace/claude-compose.json"
    LOCK_FILE="${CONFIG_FILE%.json}.lock.json"
    ORIGINAL_CWD="${TEST_TEMP_DIR}/workspace"
    DRY_RUN=true
    run main --dry-run -f "$CONFIG_FILE"
    assert_success
}

@test "main adds projects as --add-dir" {
    cd "${TEST_TEMP_DIR}/workspace"
    local proj1="${TEST_TEMP_DIR}/p1"
    local proj2="${TEST_TEMP_DIR}/p2"
    mkdir -p "$proj1" "$proj2"
    create_config "{\"projects\":[{\"name\":\"a\",\"path\":\"$proj1\"},{\"name\":\"b\",\"path\":\"$proj2\"}]}"
    reset_globals
    CONFIG_FILE="${TEST_TEMP_DIR}/workspace/claude-compose.json"
    LOCK_FILE="${CONFIG_FILE%.json}.lock.json"
    ORIGINAL_CWD="${TEST_TEMP_DIR}/workspace"
    DRY_RUN=true
    main --dry-run -f "$CONFIG_FILE"
    # CLAUDE_ARGS should contain --add-dir for both projects
    local add_dir_count=0
    for arg in "${CLAUDE_ARGS[@]}"; do
        [[ "$arg" == "--add-dir" ]] && ((add_dir_count++))
    done
    [[ "$add_dir_count" -ge 2 ]]
}

@test "main includes system prompt" {
    cd "${TEST_TEMP_DIR}/workspace"
    local proj="${TEST_TEMP_DIR}/proj_sp"
    mkdir -p "$proj"
    create_config "{\"projects\":[{\"name\":\"app\",\"path\":\"$proj\"}]}"
    reset_globals
    CONFIG_FILE="${TEST_TEMP_DIR}/workspace/claude-compose.json"
    LOCK_FILE="${CONFIG_FILE%.json}.lock.json"
    ORIGINAL_CWD="${TEST_TEMP_DIR}/workspace"
    DRY_RUN=true
    main --dry-run -f "$CONFIG_FILE"
    # CLAUDE_ARGS should contain --append-system-prompt
    local found=false
    for arg in "${CLAUDE_ARGS[@]}"; do
        [[ "$arg" == "--append-system-prompt" ]] && found=true
    done
    [[ "$found" == "true" ]]
}

@test "main with multiple projects" {
    cd "${TEST_TEMP_DIR}/workspace"
    local p1="${TEST_TEMP_DIR}/mx1"
    local p2="${TEST_TEMP_DIR}/mx2"
    local p3="${TEST_TEMP_DIR}/mx3"
    mkdir -p "$p1" "$p2" "$p3"
    create_config "{\"projects\":[{\"name\":\"a\",\"path\":\"$p1\"},{\"name\":\"b\",\"path\":\"$p2\"},{\"name\":\"c\",\"path\":\"$p3\"}]}"
    reset_globals
    CONFIG_FILE="${TEST_TEMP_DIR}/workspace/claude-compose.json"
    LOCK_FILE="${CONFIG_FILE%.json}.lock.json"
    ORIGINAL_CWD="${TEST_TEMP_DIR}/workspace"
    DRY_RUN=true
    main --dry-run -f "$CONFIG_FILE"
    local add_dir_count=0
    for arg in "${CLAUDE_ARGS[@]}"; do
        [[ "$arg" == "--add-dir" ]] && ((add_dir_count++))
    done
    [[ "$add_dir_count" -ge 3 ]]
}

@test "main passes extra args to claude" {
    cd "${TEST_TEMP_DIR}/workspace"
    local proj="${TEST_TEMP_DIR}/proj_ea"
    mkdir -p "$proj"
    create_config "{\"projects\":[{\"name\":\"app\",\"path\":\"$proj\"}]}"
    reset_globals
    CONFIG_FILE="${TEST_TEMP_DIR}/workspace/claude-compose.json"
    LOCK_FILE="${CONFIG_FILE%.json}.lock.json"
    ORIGINAL_CWD="${TEST_TEMP_DIR}/workspace"
    DRY_RUN=true
    main --dry-run -f "$CONFIG_FILE" -- -p "model"
    [[ "${EXTRA_ARGS[0]}" == "-p" ]]
    [[ "${EXTRA_ARGS[1]}" == "model" ]]
}

@test "main handles missing config gracefully" {
    cd "${TEST_TEMP_DIR}/workspace"
    reset_globals
    CONFIG_FILE="${TEST_TEMP_DIR}/workspace/nonexistent.json"
    DRY_RUN=true
    run main --dry-run -f "$CONFIG_FILE"
    assert_failure
}

@test "main dry-run with presets works" {
    cd "${TEST_TEMP_DIR}/workspace"
    create_preset "fp"
    local proj="${TEST_TEMP_DIR}/proj_f"
    mkdir -p "$proj"
    create_config "{\"projects\":[{\"name\":\"app\",\"path\":\"$proj\"}],\"presets\":[\"fp\"]}"
    reset_globals
    CONFIG_FILE="${TEST_TEMP_DIR}/workspace/claude-compose.json"
    LOCK_FILE="${CONFIG_FILE%.json}.lock.json"
    ORIGINAL_CWD="${TEST_TEMP_DIR}/workspace"
    DRY_RUN=true
    run main --dry-run -f "$CONFIG_FILE"
    assert_success
}

@test "main exports env vars" {
    cd "${TEST_TEMP_DIR}/workspace"
    local proj="${TEST_TEMP_DIR}/proj_env"
    mkdir -p "$proj"
    create_env_file "${TEST_TEMP_DIR}/workspace/env.json" '{"TEST_VAR":"hello"}'
    create_config "{\"projects\":[{\"name\":\"app\",\"path\":\"$proj\"}],\"resources\":{\"env_files\":[\"env.json\"]}}"
    reset_globals
    CONFIG_FILE="${TEST_TEMP_DIR}/workspace/claude-compose.json"
    LOCK_FILE="${CONFIG_FILE%.json}.lock.json"
    ORIGINAL_CWD="${TEST_TEMP_DIR}/workspace"
    DRY_RUN=true
    main --dry-run -f "$CONFIG_FILE"
    [[ "${TEST_VAR:-}" == "hello" ]]
}

@test "main dry-run with claude_md false succeeds" {
    cd "${TEST_TEMP_DIR}/workspace"
    local proj="${TEST_TEMP_DIR}/proj_set"
    mkdir -p "$proj"
    create_config "{\"projects\":[{\"name\":\"app\",\"path\":\"$proj\",\"claude_md\":false}]}"
    reset_globals
    run main --dry-run -f "${TEST_TEMP_DIR}/workspace/claude-compose.json"
    assert_success
}
