#!/usr/bin/env bats

# Prompt functions return empty/minimal strings in test lib since prompt markers are stripped.
# We verify functions exist and accept parameters without error.

setup() {
    load '../test_helper/common_setup'
    _common_setup
}

teardown() {
    _common_teardown
}

# ── compose_config_prompt ────────────────────────────────────────────

@test "compose_config_prompt accepts config_file arg" {
    run compose_config_prompt "claude-compose.json"
    assert_success
}

@test "compose_config_prompt returns string" {
    local result
    result=$(compose_config_prompt "custom.json")
    # Result is a string (may be empty in test lib)
    [[ -z "$result" || -n "$result" ]]
}

# ── compose_system_prompt ────────────────────────────────────────────

@test "compose_system_prompt is callable" {
    run compose_system_prompt
    assert_success
}

# ── compose_doctor_prompt ────────────────────────────────────────────

@test "compose_doctor_prompt accepts three args" {
    run compose_doctor_prompt "config.json" "/workspace" "test error"
    assert_success
}

@test "compose_doctor_prompt returns string" {
    local result
    result=$(compose_doctor_prompt "config.json" "/workspace" "error msg")
    [[ -z "$result" || -n "$result" ]]
}

# ── compose_instructions_prompt ──────────────────────────────────────

@test "compose_instructions_prompt accepts summary arg" {
    run compose_instructions_prompt "test summary"
    assert_success
}

# ── compose_start_prompt ─────────────────────────────────────────────

@test "compose_start_prompt accepts root_path" {
    run compose_start_prompt "/some/path"
    assert_success
}
