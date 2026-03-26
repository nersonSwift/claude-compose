#!/usr/bin/env bats

setup() {
    load '../test_helper/common_setup'
    _common_setup
    load '../test_helper/mocks'
    load '../test_helper/fixtures'
}

teardown() {
    _common_teardown
}

# ── parse_github_source ──────────────────────────────────────────────

@test "parse_github_source: owner/repo only" {
    parse_github_source "github:owner/repo"
    assert_equal "$_GH_OWNER" "owner"
    assert_equal "$_GH_REPO" "repo"
    assert_equal "$_GH_PATH" ""
    assert_equal "$_GH_SPEC" ""
}

@test "parse_github_source: with nested path" {
    parse_github_source "github:owner/repo/path/to/preset"
    assert_equal "$_GH_OWNER" "owner"
    assert_equal "$_GH_REPO" "repo"
    assert_equal "$_GH_PATH" "path/to/preset"
    assert_equal "$_GH_SPEC" ""
}

@test "parse_github_source: with version spec" {
    parse_github_source "github:owner/repo@^1.2.3"
    assert_equal "$_GH_OWNER" "owner"
    assert_equal "$_GH_REPO" "repo"
    assert_equal "$_GH_PATH" ""
    assert_equal "$_GH_SPEC" "^1.2.3"
}

@test "parse_github_source: path and version spec" {
    parse_github_source "github:owner/repo/path@~2.0.0"
    assert_equal "$_GH_OWNER" "owner"
    assert_equal "$_GH_REPO" "repo"
    assert_equal "$_GH_PATH" "path"
    assert_equal "$_GH_SPEC" "~2.0.0"
}

# ── parse_version_spec ───────────────────────────────────────────────

@test "parse_version_spec: empty string returns latest" {
    run parse_version_spec ""
    assert_success
    assert_output "latest 0 0 0"
}

@test "parse_version_spec: exact version" {
    run parse_version_spec "1.2.3"
    assert_success
    assert_output "exact 1 2 3"
}

@test "parse_version_spec: caret prefix" {
    run parse_version_spec "^1.2.3"
    assert_success
    assert_output "caret 1 2 3"
}

@test "parse_version_spec: tilde prefix" {
    run parse_version_spec "~1.2.3"
    assert_success
    assert_output "tilde 1 2 3"
}

@test "parse_version_spec: zero version" {
    run parse_version_spec "0.1.0"
    assert_success
    assert_output "exact 0 1 0"
}

# ── parse_tag_version ────────────────────────────────────────────────

@test "parse_tag_version: v-prefixed tag" {
    run parse_tag_version "v1.2.3"
    assert_success
    assert_output "1 2 3"
}

@test "parse_tag_version: without v prefix" {
    run parse_tag_version "1.2.3"
    assert_success
    assert_output "1 2 3"
}

@test "parse_tag_version: zeros" {
    run parse_tag_version "v0.0.1"
    assert_success
    assert_output "0 0 1"
}

@test "parse_tag_version: two-part version X.Y defaults patch to 0" {
    run parse_tag_version "1.2"
    assert_success
    assert_output "1 2 0"
}

@test "parse_tag_version: invalid tag fails" {
    run parse_tag_version "invalid"
    assert_failure
}

@test "parse_tag_version: double-v prefix fails" {
    run parse_tag_version "vv1.0.0"
    assert_failure
}

# ── version_matches ──────────────────────────────────────────────────

@test "version_matches: latest matches anything" {
    run version_matches 5 0 0 latest 0 0 0
    assert_success
}

@test "version_matches: exact matches same version" {
    run version_matches 1 2 3 exact 1 2 3
    assert_success
}

@test "version_matches: exact rejects different patch" {
    run version_matches 1 2 4 exact 1 2 3
    assert_failure
}

@test "version_matches: exact rejects different minor" {
    run version_matches 1 3 3 exact 1 2 3
    assert_failure
}

@test "version_matches: tilde matches same version" {
    run version_matches 1 2 3 tilde 1 2 3
    assert_success
}

@test "version_matches: tilde matches higher patch" {
    run version_matches 1 2 5 tilde 1 2 3
    assert_success
}

@test "version_matches: tilde rejects higher minor" {
    run version_matches 1 3 0 tilde 1 2 3
    assert_failure
}

@test "version_matches: tilde rejects higher major" {
    run version_matches 2 0 0 tilde 1 2 3
    assert_failure
}

@test "version_matches: caret matches higher minor" {
    run version_matches 1 3 0 caret 1 2 3
    assert_success
}

@test "version_matches: caret matches higher patch" {
    run version_matches 1 2 4 caret 1 2 3
    assert_success
}

@test "version_matches: caret rejects higher major" {
    run version_matches 2 0 0 caret 1 2 3
    assert_failure
}

@test "version_matches: caret 0.x locks minor, allows higher patch" {
    run version_matches 0 2 5 caret 0 2 3
    assert_success
}

@test "version_matches: caret 0.x locks minor, rejects different minor" {
    run version_matches 0 3 0 caret 0 2 3
    assert_failure
}

@test "version_matches: caret 0.0.x locks patch, exact match succeeds" {
    run version_matches 0 0 3 caret 0 0 3
    assert_success
}

@test "version_matches: caret 0.0.x locks patch, different patch fails" {
    run version_matches 0 0 4 caret 0 0 3
    assert_failure
}

# ── find_best_tag ────────────────────────────────────────────────────

@test "find_best_tag: returns highest matching tag with latest spec" {
    local tags
    tags=$(printf "v1.0.0\nv1.1.0\nv2.0.0\n")
    run find_best_tag "$tags" latest 0 0 0
    assert_success
    assert_output "v2.0.0"
}

@test "find_best_tag: returns failure when no match" {
    local tags="v1.0.0"
    run find_best_tag "$tags" exact 2 0 0
    assert_failure
}

@test "find_best_tag: handles mixed v-prefix tags" {
    local tags
    tags=$(printf "v1.0.0\n1.1.0\nv1.2.0\n")
    run find_best_tag "$tags" caret 1 0 0
    assert_success
    assert_output "v1.2.0"
}

@test "find_best_tag: single matching tag returns it" {
    local tags="v3.5.1"
    run find_best_tag "$tags" exact 3 5 1
    assert_success
    assert_output "v3.5.1"
}

# ── check_major_bump ─────────────────────────────────────────────────

@test "check_major_bump: detects major version increase" {
    run check_major_bump "1.0.0" "2.0.0"
    assert_success
}

@test "check_major_bump: no bump on minor increase" {
    run check_major_bump "1.0.0" "1.1.0"
    assert_failure
}

@test "check_major_bump: 0 to 1 is a bump" {
    run check_major_bump "0.9.0" "1.0.0"
    assert_success
}

# ── registry_version_dir / registry_preset_dir ───────────────────────

@test "registry_version_dir: returns correct path" {
    run registry_version_dir "myowner" "myrepo" "1.0.0"
    assert_success
    assert_output "${REGISTRIES_DIR}/myowner/myrepo/v1.0.0"
}

@test "registry_preset_dir: without path returns version dir" {
    run registry_preset_dir "myowner" "myrepo" "1.0.0" ""
    assert_success
    assert_output "${REGISTRIES_DIR}/myowner/myrepo/v1.0.0"
}

@test "registry_preset_dir: with path appends subpath" {
    run registry_preset_dir "myowner" "myrepo" "1.0.0" "presets/web"
    assert_success
    assert_output "${REGISTRIES_DIR}/myowner/myrepo/v1.0.0/presets/web"
}

# ── has_github_presets ───────────────────────────────────────────────

@test "has_github_presets: returns 0 when github preset exists" {
    create_config '{
        "projects": [],
        "presets": [
            { "source": "github:owner/repo@^1.0.0" }
        ]
    }'
    run has_github_presets "$CONFIG_FILE"
    assert_success
}

@test "has_github_presets: returns 1 when no github presets" {
    create_config '{
        "projects": [],
        "presets": [
            "local-preset"
        ]
    }'
    run has_github_presets "$CONFIG_FILE"
    assert_failure
}

# ── lock operations ──────────────────────────────────────────────────

@test "lock_write and lock_read roundtrip" {
    # lock_write needs to acquire lock, so ensure directory exists
    mkdir -p "$(dirname "$LOCK_FILE")"

    lock_write "github:owner/repo" "1.2.3" "v1.2.3" "^1.0.0"

    run lock_read "github:owner/repo"
    assert_success
    assert_output "1.2.3 v1.2.3 ^1.0.0"
}

@test "lock_read: returns 1 on missing lock file" {
    rm -f "$LOCK_FILE"
    run lock_read "github:owner/repo"
    assert_failure
}

@test "get_update_interval: reads from config file" {
    create_config '{"update_interval": 12}'
    run get_update_interval
    assert_success
    assert_output "12"
}

@test "get_update_interval: defaults to 24 without config" {
    rm -f "$CONFIG_FILE" "$GLOBAL_CONFIG"
    run get_update_interval
    assert_success
    assert_output "24"
}

# ── _acquire_lock / _release_lock ────────────────────────────────────

@test "_acquire_lock: creates lock directory with pid" {
    local lock_dir="${TEST_TEMP_DIR}/test.lock"

    run _acquire_lock "$lock_dir"
    assert_success
    assert_file_exists "$lock_dir/pid"

    # Clean up
    _release_lock "$lock_dir"
}

@test "_release_lock: removes lock directory" {
    local lock_dir="${TEST_TEMP_DIR}/test.lock"

    _acquire_lock "$lock_dir"
    assert_file_exists "$lock_dir/pid"

    _release_lock "$lock_dir"
    assert_not_exist "$lock_dir"
}

@test "_acquire_lock: detects stale lock and recovers" {
    local lock_dir="${TEST_TEMP_DIR}/test.lock"

    # Create a stale lock with a non-existent PID
    mkdir -p "$lock_dir"
    echo "99999999" > "$lock_dir/pid"

    run _acquire_lock "$lock_dir"
    assert_success
    assert_file_exists "$lock_dir/pid"

    # Clean up
    _release_lock "$lock_dir"
}
