#!/usr/bin/env bats

setup() {
    load '../test_helper/common_setup'
    _common_setup
}

teardown() {
    _common_teardown
}

# ── _validate_projects ─────────────────────────────────────────────

@test "_validate_projects: valid projects array passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"projects":[{"name":"app","path":"/tmp"}]}' > "$cfg"
    run _validate_projects "$cfg"
    assert_success
    assert_output ""
}

@test "_validate_projects: missing name produces error" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"projects":[{"path":"/tmp"}]}' > "$cfg"
    run _validate_projects "$cfg"
    assert_success
    assert_output -p "name"
}

@test "_validate_projects: missing path produces error" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"projects":[{"name":"app"}]}' > "$cfg"
    run _validate_projects "$cfg"
    assert_success
    assert_output -p "path"
}

@test "_validate_projects: duplicate project names produces error" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"projects":[{"name":"app","path":"/a"},{"name":"app","path":"/b"}]}' > "$cfg"
    run _validate_projects "$cfg"
    assert_success
    assert_output -p "app"
}

@test "_validate_projects: non-array type produces error" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"projects":{"name":"app","path":"/tmp"}}' > "$cfg"
    run _validate_projects "$cfg"
    assert_success
    assert_output -p "must be an array"
}

@test "_validate_projects: empty array passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"projects":[]}' > "$cfg"
    run _validate_projects "$cfg"
    assert_success
    assert_output ""
}

@test "_validate_projects: non-string name does not crash" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"projects":[{"name":123,"path":"/tmp"}]}' > "$cfg"
    run _validate_projects "$cfg"
    assert_success
    # The function uses jq -r .name // empty; numeric name becomes non-empty string
    # so it should pass without error (no explicit type check)
}

# ── _validate_resources ────────────────────────────────────────────

@test "_validate_resources: valid agents array passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"resources":{"agents":["a.md","b.md"]}}' > "$cfg"
    run _validate_resources "$cfg"
    assert_success
    assert_output ""
}

@test "_validate_resources: non-string in agents array produces error" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"resources":{"agents":["a.md",123]}}' > "$cfg"
    run _validate_resources "$cfg"
    assert_success
    assert_output -p "expected string"
}

@test "_validate_resources: valid skills array passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"resources":{"skills":["s1.md","s2.md"]}}' > "$cfg"
    run _validate_resources "$cfg"
    assert_success
    assert_output ""
}

@test "_validate_resources: valid mcp object passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"resources":{"mcp":{"server":{"command":"echo"}}}}' > "$cfg"
    run _validate_resources "$cfg"
    assert_success
    assert_output ""
}

@test "_validate_resources: non-object mcp produces error" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"resources":{"mcp":"bad"}}' > "$cfg"
    run _validate_resources "$cfg"
    assert_success
    assert_output -p "must be an object"
}

@test "_validate_resources: env_files as array of strings passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"resources":{"env_files":["a.env","b.env"]}}' > "$cfg"
    run _validate_resources "$cfg"
    assert_success
    assert_output ""
}

@test "_validate_resources: append_system_prompt_files as array of strings passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"resources":{"append_system_prompt_files":["p1.md","p2.md"]}}' > "$cfg"
    run _validate_resources "$cfg"
    assert_success
    assert_output ""
}

@test "_validate_resources: settings as string passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"resources":{"settings":"my-settings.json"}}' > "$cfg"
    run _validate_resources "$cfg"
    assert_success
    assert_output ""
}

@test "_validate_resources: no resources section passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{}' > "$cfg"
    run _validate_resources "$cfg"
    assert_success
    assert_output ""
}

# ── _validate_workspaces ──────────────────────────────────────────

@test "_validate_workspaces: valid workspace passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"workspaces":[{"path":"~/other"}]}' > "$cfg"
    run _validate_workspaces "$cfg"
    assert_success
    assert_output ""
}

@test "_validate_workspaces: missing path produces error" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"workspaces":[{"name":"x"}]}' > "$cfg"
    run _validate_workspaces "$cfg"
    assert_success
    assert_output -p "path"
}

@test "_validate_workspaces: non-object entry produces error" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"workspaces":["bad"]}' > "$cfg"
    run _validate_workspaces "$cfg"
    assert_success
    assert_output -p "expected object"
}

@test "_validate_workspaces: non-object filter field produces error" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"workspaces":[{"path":"~/x","agents":"bad"}]}' > "$cfg"
    run _validate_workspaces "$cfg"
    assert_success
    assert_output -p "must be an object"
}

# ── _validate_marketplaces ────────────────────────────────────────

@test "_validate_marketplaces: valid object passes" {
    local config
    config=$(mktemp "$BATS_TEST_TMPDIR/cfg.XXXXXX")
    echo '{"marketplaces":{"team":{"source":"github","repo":"org/plugins"}}}' > "$config"
    run _validate_marketplaces "$config"
    assert_success
    assert_output ""
}

@test "_validate_marketplaces: non-object fails" {
    local config
    config=$(mktemp "$BATS_TEST_TMPDIR/cfg.XXXXXX")
    echo '{"marketplaces":["bad"]}' > "$config"
    run _validate_marketplaces "$config"
    assert_output --partial "must be an object"
}

@test "_validate_marketplaces: missing source fails" {
    local config
    config=$(mktemp "$BATS_TEST_TMPDIR/cfg.XXXXXX")
    echo '{"marketplaces":{"team":{"repo":"org/plugins"}}}' > "$config"
    run _validate_marketplaces "$config"
    assert_output --partial "must have a \"source\" field"
}

@test "_validate_marketplaces: missing repo fails" {
    local config
    config=$(mktemp "$BATS_TEST_TMPDIR/cfg.XXXXXX")
    echo '{"marketplaces":{"team":{"source":"github"}}}' > "$config"
    run _validate_marketplaces "$config"
    assert_output --partial "must have a \"repo\" field"
}

# ── _validate_name ────────────────────────────────────────────────

@test "_validate_name: valid name passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"name":"my-project"}' > "$cfg"
    run _validate_name "$cfg"
    assert_output ""
}

@test "_validate_name: single character name passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"name":"a"}' > "$cfg"
    run _validate_name "$cfg"
    assert_output ""
}

@test "_validate_name: missing name produces error" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"projects":[]}' > "$cfg"
    run _validate_name "$cfg"
    assert_output --partial "Required field \"name\" is missing"
}

@test "_validate_name: non-string type produces error" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"name":42}' > "$cfg"
    run _validate_name "$cfg"
    assert_output --partial "must be a string"
}

@test "_validate_name: name with spaces produces error" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"name":"my project"}' > "$cfg"
    run _validate_name "$cfg"
    assert_output --partial "invalid characters"
}

@test "_validate_name: name starting with dash produces error" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"name":"-bad"}' > "$cfg"
    run _validate_name "$cfg"
    assert_output --partial "invalid characters"
}

@test "_validate_name: name with dots and hyphens passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"name":"my-project.v2"}' > "$cfg"
    run _validate_name "$cfg"
    assert_output ""
}

# ── validate_config_semantics ─────────────────────────────────────

@test "validate_config_semantics: config with all valid sections has empty stdout" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    cat > "$cfg" <<'JSON'
{
    "name": "test-ws",
    "projects": [{"name":"app","path":"/tmp"}],
    "resources": {"agents":["a.md"]},
    "workspaces": [{"path":"~/other"}]
}
JSON
    local captured_stdout
    captured_stdout=$(validate_config_semantics "$cfg" 2>/dev/null)
    [[ -z "$captured_stdout" ]]
}

@test "validate_config_semantics: unknown top-level keys produce warning to stderr" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"bogus_key":true}' > "$cfg"
    local captured_stderr
    captured_stderr=$(validate_config_semantics "$cfg" 2>&1 >/dev/null)
    echo "$captured_stderr" | grep -qF "bogus_key"
}

@test "validate_config_semantics: first error stops validation" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    # name error should be reported; projects/resources errors should not appear
    echo '{"projects":"bad","resources":"bad"}' > "$cfg"
    local captured_stdout
    captured_stdout=$(validate_config_semantics "$cfg" 2>/dev/null)
    echo "$captured_stdout" | grep -qF "name"
    # Should NOT contain projects or resources error (stopped at name)
    ! echo "$captured_stdout" | grep -qF "projects"
    ! echo "$captured_stdout" | grep -qF "resources"
}

# ── validate_global_config ────────────────────────────────────────

@test "validate_global_config: missing global config file returns 0" {
    GLOBAL_CONFIG="${TEST_TEMP_DIR}/nonexistent.json"
    run validate_global_config
    assert_success
}

@test "validate_global_config: invalid JSON exits 1 via die_doctor" {
    GLOBAL_CONFIG="${TEST_TEMP_DIR}/bad_global.json"
    echo '{bad json' > "$GLOBAL_CONFIG"
    run validate_global_config
    assert_failure
}

# ── _validate_workspaces: plugins filter ──────────────────────────

@test "_validate_workspaces: plugins filter field as object passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"workspaces":[{"path":"~/x","plugins":{"include":["*"]}}]}' > "$cfg"
    run _validate_workspaces "$cfg"
    assert_success
    assert_output ""
}

@test "_validate_workspaces: plugins filter field as non-object fails" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"workspaces":[{"path":"~/x","plugins":"bad"}]}' > "$cfg"
    run _validate_workspaces "$cfg"
    assert_success
    assert_output -p "plugins must be an object"
}

# ── _validate_workspaces: claude_md_overrides ─────────────────────

@test "_validate_workspaces: claude_md_overrides as object with booleans passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"workspaces":[{"path":"~/x","claude_md_overrides":{"proj-A":true,"proj-B":false}}]}' > "$cfg"
    run _validate_workspaces "$cfg"
    assert_success
    assert_output ""
}

@test "_validate_workspaces: claude_md_overrides as non-object fails" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"workspaces":[{"path":"~/x","claude_md_overrides":"bad"}]}' > "$cfg"
    run _validate_workspaces "$cfg"
    assert_success
    assert_output -p "claude_md_overrides must be an object"
}

@test "_validate_workspaces: claude_md_overrides with non-boolean value fails" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"workspaces":[{"path":"~/x","claude_md_overrides":{"proj-A":"yes"}}]}' > "$cfg"
    run _validate_workspaces "$cfg"
    assert_success
    assert_output -p "expected boolean"
}
