#!/usr/bin/env bats

setup() {
    load '../test_helper/common_setup'
    _common_setup
    load '../test_helper/fixtures'
}

teardown() {
    _common_teardown
}

# ── _validate_plugins ─────────────────────────────────────────────

@test "_validate_plugins: no plugins key passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{}' > "$cfg"
    run _validate_plugins "$cfg"
    assert_success
    assert_output ""
}

@test "_validate_plugins: empty array passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"plugins":[]}' > "$cfg"
    run _validate_plugins "$cfg"
    assert_success
    assert_output ""
}

@test "_validate_plugins: string local path passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"plugins":["./my-plugin"]}' > "$cfg"
    run _validate_plugins "$cfg"
    assert_success
    assert_output ""
}

@test "_validate_plugins: marketplace name string passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"plugins":["ralph-loop"]}' > "$cfg"
    run _validate_plugins "$cfg"
    assert_success
    assert_output ""
}

@test "_validate_plugins: tilde path passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"plugins":["~/my-plugins/tool"]}' > "$cfg"
    run _validate_plugins "$cfg"
    assert_success
    assert_output ""
}

@test "_validate_plugins: absolute path passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"plugins":["/opt/plugins/tool"]}' > "$cfg"
    run _validate_plugins "$cfg"
    assert_success
    assert_output ""
}

@test "_validate_plugins: object with path passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"plugins":[{"path":"./my-plugin"}]}' > "$cfg"
    run _validate_plugins "$cfg"
    assert_success
    assert_output ""
}

@test "_validate_plugins: object with name passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"plugins":[{"name":"my-plugin"}]}' > "$cfg"
    run _validate_plugins "$cfg"
    assert_success
    assert_output ""
}

@test "_validate_plugins: object with name and config passes" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"plugins":[{"name":"my-plugin","config":{"api_key":"test"}}]}' > "$cfg"
    run _validate_plugins "$cfg"
    assert_success
    assert_output ""
}

@test "_validate_plugins: non-array produces error" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"plugins":"bad"}' > "$cfg"
    run _validate_plugins "$cfg"
    assert_success
    assert_output --partial 'must be an array'
}

@test "_validate_plugins: empty string produces error" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"plugins":[""]}' > "$cfg"
    run _validate_plugins "$cfg"
    assert_success
    assert_output --partial 'empty string'
}

@test "_validate_plugins: object without name or path produces error" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"plugins":[{"prefix":"bad"}]}' > "$cfg"
    run _validate_plugins "$cfg"
    assert_success
    assert_output --partial 'must have'
}

@test "_validate_plugins: invalid name format produces error" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"plugins":["-bad-name-"]}' > "$cfg"
    run _validate_plugins "$cfg"
    assert_success
    assert_output --partial 'invalid marketplace plugin name'
}

@test "_validate_plugins: object with unknown key produces error" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"plugins":[{"name":"x","bogus":"bad"}]}' > "$cfg"
    run _validate_plugins "$cfg"
    assert_success
    assert_output --partial 'unknown key'
}

@test "_validate_plugins: number entry produces error" {
    local cfg="${TEST_TEMP_DIR}/cfg.json"
    echo '{"plugins":[42]}' > "$cfg"
    run _validate_plugins "$cfg"
    assert_success
    assert_output --partial 'expected string or object'
}

# ── _is_plugin_installed ─────────────────────────────────────────

@test "_is_plugin_installed: returns false when no installed file" {
    run _is_plugin_installed "some-plugin"
    assert_failure
}

@test "_is_plugin_installed: returns true when plugin is in installed_plugins.json" {
    mkdir -p "$HOME/.claude/plugins"
    echo '{"version":2,"plugins":{"test-plugin@mkt":[{"scope":"user"}]}}' > "$HOME/.claude/plugins/installed_plugins.json"
    run _is_plugin_installed "test-plugin@mkt"
    assert_success
}

@test "_is_plugin_installed: returns false when plugin not in installed_plugins.json" {
    mkdir -p "$HOME/.claude/plugins"
    echo '{"version":2,"plugins":{"other-plugin@mkt":[{"scope":"user"}]}}' > "$HOME/.claude/plugins/installed_plugins.json"
    run _is_plugin_installed "test-plugin@mkt"
    assert_failure
}

# ── resolve_plugins ───────────────────────────────────────────────

@test "resolve_plugins: local path populates PLUGIN_DIRS" {
    local plugin_dir="${TEST_TEMP_DIR}/my-plugin"
    mkdir -p "$plugin_dir/.claude-plugin"
    echo '{"name":"test"}' > "$plugin_dir/.claude-plugin/plugin.json"

    local cfg="${TEST_TEMP_DIR}/workspace/claude-compose.json"
    mkdir -p "${TEST_TEMP_DIR}/workspace"
    echo "{\"plugins\":[\"$plugin_dir\"]}" > "$cfg"

    PLUGIN_DIRS=()
    _PLUGINS_RESOLVED=false
    resolve_plugins "$cfg" "${TEST_TEMP_DIR}/workspace"
    [[ ${#PLUGIN_DIRS[@]} -eq 1 ]]
    [[ "${PLUGIN_DIRS[0]}" == "$plugin_dir" ]]
    [[ "$_PLUGINS_RESOLVED" == "true" ]]
}

@test "resolve_plugins: relative path resolved from base_dir" {
    local plugin_dir="${TEST_TEMP_DIR}/workspace/plugins/my-plugin"
    mkdir -p "$plugin_dir"

    local cfg="${TEST_TEMP_DIR}/workspace/claude-compose.json"
    echo '{"plugins":["./plugins/my-plugin"]}' > "$cfg"

    PLUGIN_DIRS=()
    _PLUGINS_RESOLVED=false
    resolve_plugins "$cfg" "${TEST_TEMP_DIR}/workspace"
    [[ ${#PLUGIN_DIRS[@]} -eq 1 ]]
    [[ -d "${PLUGIN_DIRS[0]}" ]]
    # Path resolves to base_dir + relative path
    [[ "${PLUGIN_DIRS[0]}" == *"plugins/my-plugin" ]]
}

@test "resolve_plugins: missing directory warns" {
    local cfg="${TEST_TEMP_DIR}/workspace/claude-compose.json"
    mkdir -p "${TEST_TEMP_DIR}/workspace"
    echo '{"plugins":["/nonexistent/plugin"]}' > "$cfg"

    PLUGIN_DIRS=()
    _PLUGINS_RESOLVED=false
    run resolve_plugins "$cfg" "${TEST_TEMP_DIR}/workspace"
    assert_output --partial 'Plugin directory not found'
}

@test "resolve_plugins: no plugins key does nothing" {
    local cfg="${TEST_TEMP_DIR}/workspace/claude-compose.json"
    mkdir -p "${TEST_TEMP_DIR}/workspace"
    echo '{}' > "$cfg"

    PLUGIN_DIRS=()
    _PLUGINS_RESOLVED=false
    resolve_plugins "$cfg" "${TEST_TEMP_DIR}/workspace"
    [[ ${#PLUGIN_DIRS[@]} -eq 0 ]]
    [[ "$_PLUGINS_RESOLVED" == "true" ]]
}

@test "resolve_plugins: marketplace string adds to MARKETPLACE_PLUGINS" {
    local config
    config=$(mktemp "$BATS_TEST_TMPDIR/cfg.XXXXXX")
    echo '{"plugins":["ralph-loop"]}' > "$config"
    # Stub _install_marketplace_plugin to prevent actual install
    _install_marketplace_plugin() { return 0; }
    export -f _install_marketplace_plugin
    resolve_plugins "$config" "$BATS_TEST_TMPDIR"
    [[ ${#MARKETPLACE_PLUGINS[@]} -eq 1 ]]
    [[ "${MARKETPLACE_PLUGINS[0]}" == "ralph-loop" ]]
}

@test "resolve_plugins: object with name and config" {
    local config
    config=$(mktemp "$BATS_TEST_TMPDIR/cfg.XXXXXX")
    echo '{"plugins":[{"name":"my-plugin","config":{"api_key":"test","mode":"strict"}}]}' > "$config"
    _install_marketplace_plugin() { return 0; }
    export -f _install_marketplace_plugin
    resolve_plugins "$config" "$BATS_TEST_TMPDIR"
    [[ ${#MARKETPLACE_PLUGINS[@]} -eq 1 ]]
    [[ "${MARKETPLACE_PLUGINS[0]}" == "my-plugin" ]]
    # Check config env vars
    [[ ${#PLUGIN_CONFIG_ENVS[@]} -eq 2 ]]
}

# ── dedup tests ──────────────────────────────────────────────────

@test "resolve_plugins: dedup local path last wins" {
    local plugin_dir="${TEST_TEMP_DIR}/my-plugin"
    mkdir -p "$plugin_dir"
    local cfg1="${TEST_TEMP_DIR}/cfg1.json"
    local cfg2="${TEST_TEMP_DIR}/cfg2.json"
    echo "{\"plugins\":[\"$plugin_dir\"]}" > "$cfg1"
    echo "{\"plugins\":[\"$plugin_dir\"]}" > "$cfg2"

    PLUGIN_DIRS=()
    _PLUGINS_RESOLVED=false
    resolve_plugins "$cfg1" "${TEST_TEMP_DIR}"
    _PLUGINS_RESOLVED=false
    resolve_plugins "$cfg2" "${TEST_TEMP_DIR}"

    [[ ${#PLUGIN_DIRS[@]} -eq 1 ]]
    [[ "${PLUGIN_DIRS[0]}" == "$plugin_dir" ]]
}

@test "resolve_plugins: dedup marketplace plugin last wins" {
    local cfg1="${TEST_TEMP_DIR}/cfg1.json"
    local cfg2="${TEST_TEMP_DIR}/cfg2.json"
    echo '{"plugins":["ralph-loop"]}' > "$cfg1"
    echo '{"plugins":["ralph-loop"]}' > "$cfg2"

    _install_marketplace_plugin() { return 0; }
    export -f _install_marketplace_plugin
    MARKETPLACE_PLUGINS=()
    _PLUGINS_RESOLVED=false
    resolve_plugins "$cfg1" "${TEST_TEMP_DIR}"
    _PLUGINS_RESOLVED=false
    resolve_plugins "$cfg2" "${TEST_TEMP_DIR}"

    [[ ${#MARKETPLACE_PLUGINS[@]} -eq 1 ]]
    [[ "${MARKETPLACE_PLUGINS[0]}" == "ralph-loop" ]]
}

# ── collect_workspace_plugins ────────────────────────────────────

@test "collect_workspace_plugins: collects local plugin from workspace" {
    local ws_dir="${TEST_TEMP_DIR}/ws"
    local plugin_dir="${ws_dir}/plugins/my-plugin"
    mkdir -p "$plugin_dir"
    echo "{\"plugins\":[\"./plugins/my-plugin\"]}" > "${ws_dir}/claude-compose.json"

    PLUGIN_DIRS=()
    collect_workspace_plugins "${ws_dir}/claude-compose.json" "$ws_dir" '{}'
    [[ ${#PLUGIN_DIRS[@]} -eq 1 ]]
    [[ "${PLUGIN_DIRS[0]}" == *"/plugins/my-plugin" ]]
}

@test "collect_workspace_plugins: applies include filter" {
    local ws_dir="${TEST_TEMP_DIR}/ws"
    mkdir -p "${ws_dir}/plugins/keep-me" "${ws_dir}/plugins/skip-me"
    echo '{"plugins":["./plugins/keep-me","./plugins/skip-me"]}' > "${ws_dir}/claude-compose.json"

    PLUGIN_DIRS=()
    collect_workspace_plugins "${ws_dir}/claude-compose.json" "$ws_dir" '{"plugins":{"include":["keep-*"]}}'
    [[ ${#PLUGIN_DIRS[@]} -eq 1 ]]
    [[ "${PLUGIN_DIRS[0]}" == *"/keep-me" ]]
}

@test "collect_workspace_plugins: applies exclude filter" {
    local ws_dir="${TEST_TEMP_DIR}/ws"
    mkdir -p "${ws_dir}/plugins/good" "${ws_dir}/plugins/bad"
    echo '{"plugins":["./plugins/good","./plugins/bad"]}' > "${ws_dir}/claude-compose.json"

    PLUGIN_DIRS=()
    collect_workspace_plugins "${ws_dir}/claude-compose.json" "$ws_dir" '{"plugins":{"exclude":["bad"]}}'
    [[ ${#PLUGIN_DIRS[@]} -eq 1 ]]
    [[ "${PLUGIN_DIRS[0]}" == *"/good" ]]
}

@test "collect_workspace_plugins: resolves paths relative to workspace dir" {
    local ws_dir="${TEST_TEMP_DIR}/ws-a"
    local root_dir="${TEST_TEMP_DIR}/root"
    mkdir -p "${ws_dir}/my-plugin" "$root_dir"
    echo '{"plugins":["./my-plugin"]}' > "${ws_dir}/claude-compose.json"

    PLUGIN_DIRS=()
    collect_workspace_plugins "${ws_dir}/claude-compose.json" "$ws_dir" '{}'
    [[ ${#PLUGIN_DIRS[@]} -eq 1 ]]
    [[ "${PLUGIN_DIRS[0]}" == "${ws_dir}/my-plugin" || "${PLUGIN_DIRS[0]}" == "${ws_dir}/./my-plugin" ]]
}

@test "collect_workspace_plugins: marketplace plugin with filter" {
    local ws_dir="${TEST_TEMP_DIR}/ws"
    mkdir -p "$ws_dir"
    echo '{"plugins":["ralph-loop","debug-tool"]}' > "${ws_dir}/claude-compose.json"

    _install_marketplace_plugin() { return 0; }
    export -f _install_marketplace_plugin
    MARKETPLACE_PLUGINS=()
    collect_workspace_plugins "${ws_dir}/claude-compose.json" "$ws_dir" '{"plugins":{"exclude":["debug-*"]}}'
    [[ ${#MARKETPLACE_PLUGINS[@]} -eq 1 ]]
    [[ "${MARKETPLACE_PLUGINS[0]}" == "ralph-loop" ]]
}
