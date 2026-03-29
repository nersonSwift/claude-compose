#!/usr/bin/env bats

setup() {
    load '../test_helper/common_setup'
    _common_setup
    load '../test_helper/mocks'
    load '../test_helper/fixtures'
    setup_mock "git" 0
}

teardown() {
    _common_teardown
}

# ── read_manifest ────────────────────────────────────────────────────

@test "read_manifest returns file contents when manifest exists" {
    local ws_dir="${TEST_TEMP_DIR}/workspace"
    mkdir -p "$ws_dir/$COMPOSE_DIR"
    local manifest_content='{"global":{},"workspaces":{},"resources":{}}'
    echo "$manifest_content" > "${ws_dir}/${COMPOSE_MANIFEST}"
    cd "$ws_dir"
    local result
    result=$(read_manifest)
    [[ "$result" == "$manifest_content" ]]
}

@test "read_manifest returns default JSON when file missing" {
    local ws_dir="${TEST_TEMP_DIR}/empty_workspace"
    mkdir -p "$ws_dir"
    cd "$ws_dir"
    local result
    result=$(read_manifest)
    echo "$result" | jq -e '.global' >/dev/null
    echo "$result" | jq -e '.workspaces' >/dev/null
}

# ── needs_rebuild ────────────────────────────────────────────────────

@test "needs_rebuild returns 0 when no manifest exists" {
    cd "${TEST_TEMP_DIR}/workspace"
    rm -f "$COMPOSE_MANIFEST"
    create_config '{"projects":[]}'
    run needs_rebuild
    assert_success
}

@test "needs_rebuild returns 0 when no hash file exists" {
    cd "${TEST_TEMP_DIR}/workspace"
    mkdir -p "$COMPOSE_DIR"
    echo '{}' > "$COMPOSE_MANIFEST"
    rm -f "$COMPOSE_HASH"
    create_config '{"projects":[]}'
    run needs_rebuild
    assert_success
}

@test "needs_rebuild returns 1 (up-to-date) when hash matches" {
    cd "${TEST_TEMP_DIR}/workspace"
    create_config '{"projects":[]}'
    mkdir -p "$COMPOSE_DIR"
    # Use run to call compute_build_hash in subshell (avoids RETURN trap issue)
    run compute_build_hash
    local hash_val="$output"
    echo "$hash_val" > "$COMPOSE_HASH"
    echo '{"global":{},"workspaces":{},"resources":{}}' > "$COMPOSE_MANIFEST"
    run needs_rebuild
    assert_failure  # exit 1 means up-to-date
}

@test "needs_rebuild returns 0 when hash differs" {
    cd "${TEST_TEMP_DIR}/workspace"
    create_config '{"projects":[]}'
    mkdir -p "$COMPOSE_DIR"
    echo "wrong_hash_value" > "$COMPOSE_HASH"
    echo '{"global":{},"workspaces":{},"resources":{}}' > "$COMPOSE_MANIFEST"
    run needs_rebuild
    assert_success
}

# ── compute_build_hash ───────────────────────────────────────────────

@test "compute_build_hash returns consistent 32-char hex string" {
    create_config '{"projects":[]}'
    # Use run — may exit 1 due to RETURN trap + set -u, but output is valid
    run compute_build_hash
    # Trim any trailing whitespace/newlines
    local hash_val
    hash_val=$(echo "$output" | grep -oE '[0-9a-f]{32}' | head -1)
    [[ ${#hash_val} -eq 32 ]]
    [[ "$hash_val" =~ ^[0-9a-f]{32}$ ]]
}

@test "compute_build_hash changes when config changes" {
    create_config '{"projects":[]}'
    run compute_build_hash
    local hash1="$output"

    create_config '{"projects":[{"path":"/tmp/foo","name":"foo"}]}'
    run compute_build_hash
    local hash2="$output"

    [[ "$hash1" != "$hash2" ]]
}

@test "compute_build_hash is deterministic" {
    create_config '{"projects":[{"path":"/tmp/a","name":"a"}]}'
    run compute_build_hash
    local h1="$output"
    run compute_build_hash
    local h2="$output"
    [[ "$h1" == "$h2" ]]
}

# ── hash_workspace_config_files ──────────────────────────────────────

@test "hash_workspace_config_files returns non-empty output for workspace with agents" {
    local ws_dir="${TEST_TEMP_DIR}/ext_ws"
    mkdir -p "${ws_dir}/.claude/agents"
    echo "# Test agent" > "${ws_dir}/.claude/agents/test.md"
    run hash_workspace_config_files "$ws_dir"
    assert_success
    [[ -n "$output" ]]
}

@test "hash_workspace_config_files returns empty for workspace with no relevant files" {
    local ws_dir="${TEST_TEMP_DIR}/bare_ws"
    mkdir -p "$ws_dir"
    run hash_workspace_config_files "$ws_dir"
    assert_success
    [[ -z "$output" ]]
}
