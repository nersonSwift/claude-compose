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

# ── extract_preset_filters ───────────────────────────────────────────

@test "extract_preset_filters extracts all filter types" {
    local entry='{"agents":{"include":["*"]},"skills":{"exclude":["x"]},"mcp":{"rename":{"a":"b"}}}'
    run extract_preset_filters "$entry"
    assert_success
    local agents skills mcp
    agents=$(echo "$output" | jq -c '.agents')
    skills=$(echo "$output" | jq -c '.skills')
    mcp=$(echo "$output" | jq -c '.mcp')
    [[ "$agents" == '{"include":["*"]}' ]]
    [[ "$skills" == '{"exclude":["x"]}' ]]
    [[ "$mcp" == '{"rename":{"a":"b"}}' ]]
}

@test "extract_preset_filters returns empty for no filters" {
    local entry='{"name":"preset"}'
    run extract_preset_filters "$entry"
    assert_success
    assert_output '{}'
}

@test "extract_preset_filters handles partial filters" {
    local entry='{"agents":{"include":["test-*"]},"name":"x"}'
    run extract_preset_filters "$entry"
    assert_success
    local agents
    agents=$(echo "$output" | jq -c '.agents')
    [[ "$agents" == '{"include":["test-*"]}' ]]
    # skills and mcp should not be present
    local has_skills
    has_skills=$(echo "$output" | jq 'has("skills")')
    [[ "$has_skills" == "false" ]]
}

# ── apply_resource_prefix ────────────────────────────────────────────

@test "apply_resource_prefix no prefix returns name" {
    run apply_resource_prefix "agent" "" '{}'
    assert_success
    assert_output "agent"
}

@test "apply_resource_prefix with prefix" {
    run apply_resource_prefix "agent" "pre" '{}'
    assert_success
    assert_output "pre-agent"
}

@test "apply_resource_prefix rename takes priority" {
    run apply_resource_prefix "old" "" '{"old":"new"}'
    assert_success
    assert_output "new"
}

@test "apply_resource_prefix rename over prefix" {
    run apply_resource_prefix "old" "pre" '{"old":"renamed"}'
    assert_success
    assert_output "renamed"
}

# ── iterate_presets ──────────────────────────────────────────────────

@test "iterate_presets calls callback for string entries" {
    local cfg="${TEST_TEMP_DIR}/iter1.json"
    echo '{"presets":["my-preset"]}' > "$cfg"
    local calls="${TEST_TEMP_DIR}/calls.log"
    _test_callback() { echo "$@" >> "$calls"; }
    iterate_presets "$cfg" "_test_callback"
    [[ -f "$calls" ]]
    run grep -F "my-preset" "$calls"
    assert_success
}

@test "iterate_presets calls callback for object entries" {
    local cfg="${TEST_TEMP_DIR}/iter2.json"
    echo '{"presets":[{"name":"p"}]}' > "$cfg"
    local calls="${TEST_TEMP_DIR}/calls2.log"
    _test_callback2() { echo "$@" >> "$calls"; }
    local calls="$calls"
    iterate_presets "$cfg" "_test_callback2"
    [[ -f "$calls" ]]
    run grep -F "object" "$calls"
    assert_success
}

@test "iterate_presets handles empty presets" {
    local cfg="${TEST_TEMP_DIR}/iter3.json"
    echo '{"presets":[]}' > "$cfg"
    local calls="${TEST_TEMP_DIR}/calls3.log"
    _test_callback3() { echo "$@" >> "$calls"; }
    iterate_presets "$cfg" "_test_callback3"
    [[ ! -f "$calls" ]]
}

@test "iterate_presets handles missing presets" {
    local cfg="${TEST_TEMP_DIR}/iter4.json"
    echo '{"projects":[]}' > "$cfg"
    local calls="${TEST_TEMP_DIR}/calls4.log"
    _test_callback4() { echo "$@" >> "$calls"; }
    run iterate_presets "$cfg" "_test_callback4"
    assert_success
}

@test "iterate_presets handles mixed entries" {
    local cfg="${TEST_TEMP_DIR}/iter5.json"
    echo '{"presets":["str-preset",{"name":"obj-preset"}]}' > "$cfg"
    local calls="${TEST_TEMP_DIR}/calls5.log"
    _test_callback5() { echo "CALL:$1:$3" >> "${TEST_TEMP_DIR}/calls5.log"; }
    iterate_presets "$cfg" "_test_callback5"
    local line_count
    line_count=$(wc -l < "${TEST_TEMP_DIR}/calls5.log" | tr -d ' ')
    [[ "$line_count" == "2" ]]
}
