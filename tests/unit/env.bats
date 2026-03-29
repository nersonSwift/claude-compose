#!/usr/bin/env bats

setup() {
    load '../test_helper/common_setup'
    _common_setup
    load '../test_helper/fixtures'
}

teardown() {
    _common_teardown
}

# ── _validate_env_key ────────────────────────────────────────────────

@test "validate_env_key accepts MY_VAR" {
    run _validate_env_key "MY_VAR" "test"
    assert_success
}

@test "validate_env_key accepts _private" {
    run _validate_env_key "_private" "test"
    assert_success
}

@test "validate_env_key accepts ABC123" {
    run _validate_env_key "ABC123" "test"
    assert_success
}

@test "validate_env_key accepts SIMPLE" {
    run _validate_env_key "SIMPLE" "test"
    assert_success
}

@test "validate_env_key rejects starts with number" {
    run _validate_env_key "3FOO" "test"
    assert_failure
}

@test "validate_env_key rejects dash" {
    run _validate_env_key "FOO-BAR" "test"
    assert_failure
}

@test "validate_env_key rejects space" {
    run _validate_env_key "FOO BAR" "test"
    assert_failure
}

@test "validate_env_key blocks PATH" {
    run _validate_env_key "PATH" "test"
    assert_failure
}

@test "validate_env_key blocks HOME" {
    run _validate_env_key "HOME" "test"
    assert_failure
}

@test "validate_env_key blocks LD_PRELOAD" {
    run _validate_env_key "LD_PRELOAD" "test"
    assert_failure
}

@test "validate_env_key blocks ANTHROPIC_API_KEY" {
    run _validate_env_key "ANTHROPIC_API_KEY" "test"
    assert_failure
}

# _has_path_traversal was removed — replaced by _is_within_dir checks after path resolution

# ── load_env_files ───────────────────────────────────────────────────

@test "load_env_files exports variables from JSON file" {
    cd "${TEST_TEMP_DIR}/workspace"
    create_env_file "${TEST_TEMP_DIR}/workspace/env.json" '{"MY_KEY":"val123"}'
    create_config '{"resources":{"env_files":["env.json"]}}'
    load_env_files
    [[ "${MY_KEY:-}" == "val123" ]]
}

@test "load_env_files skips path traversal files" {
    cd "${TEST_TEMP_DIR}/workspace"
    create_config '{"resources":{"env_files":["../secret.json"]}}'
    run load_env_files
    assert_success
    # Should produce warning on stderr (captured by run)
}

@test "load_env_files warns on missing file" {
    cd "${TEST_TEMP_DIR}/workspace"
    create_config '{"resources":{"env_files":["nonexistent.json"]}}'
    run load_env_files
    assert_success
}

@test "load_env_files handles empty env_files" {
    cd "${TEST_TEMP_DIR}/workspace"
    create_config '{"resources":{"env_files":[]}}'
    run load_env_files
    assert_success
}

@test "load_env_files validates keys before export" {
    cd "${TEST_TEMP_DIR}/workspace"
    create_env_file "${TEST_TEMP_DIR}/workspace/bad.json" '{"PATH":"bad","GOOD_KEY":"ok"}'
    create_config '{"resources":{"env_files":["bad.json"]}}'
    load_env_files
    # PATH should NOT be overwritten, GOOD_KEY should be set
    [[ "${GOOD_KEY:-}" == "ok" ]]
}

# ── load_source_env_files ────────────────────────────────────────────

@test "load_source_env_files loads with prefix" {
    local src_dir="${TEST_TEMP_DIR}/source1"
    mkdir -p "$src_dir"
    create_env_file "${src_dir}/env.json" '{"API_KEY":"secret"}'
    echo '{"resources":{"env_files":["env.json"]}}' > "${src_dir}/claude-compose.json"
    load_source_env_files "$src_dir" "mysource"
    # Check that prefixed var exists
    local prefix
    prefix=$(compute_source_prefix "mysource" "$src_dir")
    local var_name="${prefix}API_KEY"
    [[ "${!var_name}" == "secret" ]]
}

@test "load_source_env_files skips non-existent source" {
    run load_source_env_files "/nonexistent/path" "test"
    assert_success
}

@test "load_source_env_files skips missing env file" {
    local src_dir="${TEST_TEMP_DIR}/source2"
    mkdir -p "$src_dir"
    echo '{"resources":{"env_files":["missing.json"]}}' > "${src_dir}/claude-compose.json"
    run load_source_env_files "$src_dir" "test"
    assert_success
}
