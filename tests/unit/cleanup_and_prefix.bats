#!/usr/bin/env bats

setup() {
    load '../test_helper/common_setup'
    _common_setup
    load '../test_helper/fixtures'
}

teardown() {
    _common_teardown
}

# ── clean_manifest_section ───────────────────────────────────────────

@test "clean_manifest_section removes agents" {
    cd "${TEST_TEMP_DIR}/workspace"
    mkdir -p .claude/agents
    echo "test" > .claude/agents/test.md
    local manifest='{"presets":{"src1":{"agents":["test.md"],"skills":[],"mcp_servers":[]}}}'
    clean_manifest_section "$manifest" "presets"
    [[ ! -f .claude/agents/test.md ]]
}

@test "clean_manifest_section removes skill symlinks" {
    cd "${TEST_TEMP_DIR}/workspace"
    mkdir -p .claude/skills
    mkdir -p "${TEST_TEMP_DIR}/real-skill"
    ln -sf "${TEST_TEMP_DIR}/real-skill" .claude/skills/my-skill
    local manifest='{"presets":{"src1":{"agents":[],"skills":["my-skill"],"mcp_servers":[]}}}'
    clean_manifest_section "$manifest" "presets"
    [[ ! -L .claude/skills/my-skill ]]
}

@test "clean_manifest_section removes skill directories" {
    cd "${TEST_TEMP_DIR}/workspace"
    mkdir -p .claude/skills/my-skill
    echo "content" > .claude/skills/my-skill/SKILL.md
    local manifest='{"presets":{"src1":{"agents":[],"skills":["my-skill"],"mcp_servers":[]}}}'
    clean_manifest_section "$manifest" "presets"
    [[ ! -d .claude/skills/my-skill ]]
}

@test "clean_manifest_section removes MCP servers from .mcp.json" {
    cd "${TEST_TEMP_DIR}/workspace"
    echo '{"mcpServers":{"srv":{"command":"echo"},"keep":{"command":"echo"}}}' > .mcp.json
    local manifest='{"presets":{"src1":{"agents":[],"skills":[],"mcp_servers":["srv"]}}}'
    clean_manifest_section "$manifest" "presets"
    local remaining
    remaining=$(jq -r '.mcpServers | keys[]' .mcp.json)
    [[ "$remaining" == "keep" ]]
}

@test "clean_manifest_section removes .mcp.json when empty" {
    cd "${TEST_TEMP_DIR}/workspace"
    echo '{"mcpServers":{"srv":{"command":"echo"}}}' > .mcp.json
    local manifest='{"presets":{"src1":{"agents":[],"skills":[],"mcp_servers":["srv"]}}}'
    clean_manifest_section "$manifest" "presets"
    [[ ! -f .mcp.json ]]
}

@test "clean_manifest_section skips path traversal names" {
    cd "${TEST_TEMP_DIR}/workspace"
    mkdir -p .claude/agents
    echo "safe" > .claude/agents/good.md
    local manifest='{"presets":{"src1":{"agents":["../evil.md","good.md"],"skills":[],"mcp_servers":[]}}}'
    clean_manifest_section "$manifest" "presets"
    # good.md should be removed, but ../evil.md should be skipped (not processed)
    [[ ! -f .claude/agents/good.md ]]
}

@test "clean_manifest_section handles empty section" {
    cd "${TEST_TEMP_DIR}/workspace"
    local manifest='{"presets":{}}'
    run clean_manifest_section "$manifest" "presets"
    assert_success
}

@test "clean_manifest_section handles missing .mcp.json" {
    cd "${TEST_TEMP_DIR}/workspace"
    local manifest='{"presets":{"src1":{"agents":[],"skills":[],"mcp_servers":["srv"]}}}'
    run clean_manifest_section "$manifest" "presets"
    assert_success
}

# ── compute_source_prefix ────────────────────────────────────────────

@test "compute_source_prefix format is name_hash_" {
    run compute_source_prefix "my-source" "/abs/path"
    assert_success
    # Should match pattern: alphanumeric/underscore + _ + 4 hex chars + _
    [[ "$output" =~ ^[a-z0-9_]+_[a-f0-9]{4}_$ ]]
}

@test "compute_source_prefix sanitizes special chars" {
    run compute_source_prefix "my.source-v2" "/abs/path"
    assert_success
    # Dots and dashes should be replaced with underscores
    [[ "$output" == my_source_v2_* ]]
}

@test "compute_source_prefix different paths different hashes" {
    local prefix1 prefix2
    prefix1=$(compute_source_prefix "same" "/path/one")
    prefix2=$(compute_source_prefix "same" "/path/two")
    [[ "$prefix1" != "$prefix2" ]]
}

@test "compute_source_prefix is deterministic" {
    local prefix1 prefix2
    prefix1=$(compute_source_prefix "test" "/abs/path")
    prefix2=$(compute_source_prefix "test" "/abs/path")
    [[ "$prefix1" == "$prefix2" ]]
}

# ── prefix_env_vars_in_mcp ──────────────────────────────────────────

@test "prefix_env_vars_in_mcp prefixes known vars" {
    local config='{"env":{"KEY":"${MY_VAR}"}}'
    local result
    result=$(prefix_env_vars_in_mcp "$config" "src_a1b2_" "MY_VAR")
    local val
    val=$(echo "$result" | jq -r '.env.KEY')
    [[ "$val" == '${src_a1b2_MY_VAR}' ]]
}

@test "prefix_env_vars_in_mcp leaves unknown vars" {
    local config='{"env":{"KEY":"${OTHER}"}}'
    local result
    result=$(prefix_env_vars_in_mcp "$config" "src_a1b2_" "MY_VAR")
    local val
    val=$(echo "$result" | jq -r '.env.KEY')
    [[ "$val" == '${OTHER}' ]]
}

@test "prefix_env_vars_in_mcp no env block returns unchanged" {
    local config='{"command":"echo"}'
    local result
    result=$(prefix_env_vars_in_mcp "$config" "src_a1b2_" "MY_VAR")
    local cmd
    cmd=$(echo "$result" | jq -r '.command')
    [[ "$cmd" == "echo" ]]
}

@test "prefix_env_vars_in_mcp empty known_vars returns unchanged" {
    local config='{"env":{"KEY":"${MY_VAR}"}}'
    local result
    result=$(prefix_env_vars_in_mcp "$config" "src_a1b2_" "")
    local val
    val=$(echo "$result" | jq -r '.env.KEY')
    [[ "$val" == '${MY_VAR}' ]]
}

@test "prefix_env_vars_in_mcp handles multiple vars in value" {
    local config
    config=$(printf '{"env":{"KEY":"${A} and ${B}"}}')
    local known_vars
    known_vars=$(printf 'A\nB')
    local result
    result=$(prefix_env_vars_in_mcp "$config" "p_" "$known_vars")
    local val
    val=$(echo "$result" | jq -r '.env.KEY')
    [[ "$val" == '${p_A} and ${p_B}' ]]
}

@test "prefix_env_vars_in_mcp skips non-string values" {
    local config='{"env":{"PORT":8080}}'
    local result
    result=$(prefix_env_vars_in_mcp "$config" "p_" "PORT")
    local val
    val=$(echo "$result" | jq '.env.PORT')
    [[ "$val" == "8080" ]]
}
