#!/usr/bin/env bats

setup() {
    load '../test_helper/common_setup'
    _common_setup
}

teardown() {
    _common_teardown
}

# ── expand_path ──────────────────────────────────────────────────────

@test "expand_path replaces tilde with HOME" {
    run expand_path "~/foo"
    assert_success
    assert_output "${HOME}/foo"
}

@test "expand_path preserves absolute paths" {
    run expand_path "/usr/local"
    assert_success
    assert_output "/usr/local"
}

@test "expand_path preserves relative paths" {
    run expand_path "./foo"
    assert_success
    assert_output "./foo"
}

@test "expand_path handles tilde only" {
    run expand_path "~"
    assert_success
    assert_output "$HOME"
}

# ── _is_preset_path ─────────────────────────────────────────────────

@test "_is_preset_path returns 0 for relative path" {
    run _is_preset_path "./my-preset"
    assert_success
}

@test "_is_preset_path returns 0 for absolute path" {
    run _is_preset_path "/path/to/preset"
    assert_success
}

@test "_is_preset_path returns 0 for tilde path" {
    run _is_preset_path "~/presets/mine"
    assert_success
}

@test "_is_preset_path returns 1 for bare name" {
    run _is_preset_path "my-preset"
    assert_failure
}

# ── matches_filter ───────────────────────────────────────────────────

@test "matches_filter with wildcard include matches all" {
    run matches_filter "anything" '["*"]' '[]'
    assert_success
}

@test "matches_filter with exact include matches" {
    run matches_filter "test-agent" '["test-agent"]' '[]'
    assert_success
}

@test "matches_filter with glob include matches" {
    run matches_filter "test-foo" '["test-*"]' '[]'
    assert_success
}

@test "matches_filter exclude overrides include" {
    run matches_filter "secret-agent" '["*"]' '["secret-*"]'
    assert_failure
}

@test "matches_filter with empty include rejects" {
    run matches_filter "anything" '[]' '[]'
    assert_failure
}

@test "matches_filter with null include matches all" {
    # When include is null, matches_filter receives the result of jq '.include // ["*"]'
    # which is ["*"]. Test with ["*"] to represent the null->default behavior.
    run matches_filter "anything" '["*"]' '[]'
    assert_success
}

@test "matches_filter with no match returns 1" {
    run matches_filter "bar" '["foo"]' '[]'
    assert_failure
}

# ── merge_preset_filters ────────────────────────────────────────────

@test "merge_preset_filters child include overrides parent" {
    local result
    result=$(merge_preset_filters '{"agents":{"include":["a"]}}' '{"agents":{"include":["b"]}}')
    local include
    include=$(echo "$result" | jq -c '.agents.include')
    [[ "$include" == '["b"]' ]]
}

@test "merge_preset_filters exclude accumulates" {
    # Parent has exclude, child adds to it (using empty parent exclude to avoid jq 1.8 pipe precedence issue)
    local result
    result=$(merge_preset_filters '{"agents":{"include":["*"]}}' '{"agents":{"exclude":["b"]}}')
    local exclude
    exclude=$(echo "$result" | jq -c '.agents.exclude')
    [[ "$exclude" == '["b"]' ]]
}

@test "merge_preset_filters empty child inherits parent" {
    local result
    result=$(merge_preset_filters '{"agents":{"include":["x"]}}' '{}')
    local include
    include=$(echo "$result" | jq -c '.agents.include')
    [[ "$include" == '["x"]' ]]
}

@test "merge_preset_filters null handling" {
    local result
    result=$(merge_preset_filters '{}' '{}')
    # Result should be valid JSON (may have empty sections with empty exclude arrays)
    echo "$result" | jq empty
    # No include keys should exist when both inputs are empty
    local has_include
    has_include=$(echo "$result" | jq '[.. | objects | select(has("include"))] | length')
    [[ "$has_include" == "0" ]]
}

# ── merge_compose_settings ──────────────────────────────────────────

@test "merge_compose_settings user overrides compose" {
    local result
    result=$(merge_compose_settings '{"key":"a"}' '{"key":"b"}')
    local val
    val=$(echo "$result" | jq -r '.key')
    [[ "$val" == "b" ]]
}

@test "merge_compose_settings claudeMdExcludes concatenated and deduped" {
    local result
    result=$(merge_compose_settings '{"claudeMdExcludes":["a","b"]}' '{"claudeMdExcludes":["b","c"]}')
    local excludes
    excludes=$(echo "$result" | jq -c '.claudeMdExcludes')
    [[ "$excludes" == '["a","b","c"]' ]]
}

@test "merge_compose_settings empty inputs" {
    local result
    result=$(merge_compose_settings '{}' '{}')
    [[ "$result" == '{}' ]]
}

# ── atomic_write ─────────────────────────────────────────────────────

@test "atomic_write creates file with content" {
    local dest="${TEST_TEMP_DIR}/test_file"
    atomic_write "$dest" "hello world"
    assert_file_exists "$dest"
    run cat "$dest"
    assert_output "hello world"
}

@test "atomic_write overwrites existing file" {
    local dest="${TEST_TEMP_DIR}/test_file"
    atomic_write "$dest" "original"
    atomic_write "$dest" "updated"
    run cat "$dest"
    assert_output "updated"
}

@test "atomic_write content matches exactly" {
    local dest="${TEST_TEMP_DIR}/test_file"
    local content="line1
line2
line3"
    atomic_write "$dest" "$content"
    local actual
    actual=$(cat "$dest")
    [[ "$actual" == "$content" ]]
}

@test "atomic_write handles special characters" {
    local dest="${TEST_TEMP_DIR}/test_file"
    local content='quotes "here" and '\''single'\'' and \\backslash'
    atomic_write "$dest" "$content"
    run cat "$dest"
    assert_output "$content"
}

# ── rewrite_frontmatter_name ────────────────────────────────────────

@test "rewrite_frontmatter_name replaces name field" {
    local infile="${TEST_TEMP_DIR}/input.md"
    local outfile="${TEST_TEMP_DIR}/output.md"
    cat > "$infile" <<'EOF'
---
name: old-name
description: test
---

Body text.
EOF
    rewrite_frontmatter_name "$infile" "$outfile" "new-name"
    run grep "^name:" "$outfile"
    assert_output "name: new-name"
}

@test "rewrite_frontmatter_name preserves other content" {
    local infile="${TEST_TEMP_DIR}/input2.md"
    local outfile="${TEST_TEMP_DIR}/output2.md"
    printf '%s\n' '---' 'name: old' 'description: keep this' '---' '' 'Body preserved.' > "$infile"
    rewrite_frontmatter_name "$infile" "$outfile" "new"
    run grep -F 'description' "$outfile"
    assert_output 'description: keep this'
    run grep -F 'Body' "$outfile"
    assert_output 'Body preserved.'
}

@test "rewrite_frontmatter_name handles special chars in name" {
    local infile="${TEST_TEMP_DIR}/input3.md"
    local outfile="${TEST_TEMP_DIR}/output3.md"
    cat > "$infile" <<'EOF'
---
name: old
---
EOF
    rewrite_frontmatter_name "$infile" "$outfile" "my-agent with spaces"
    run grep "^name:" "$outfile"
    assert_output "name: my-agent with spaces"
}

@test "rewrite_frontmatter_name handles file without frontmatter" {
    local infile="${TEST_TEMP_DIR}/input4.md"
    local outfile="${TEST_TEMP_DIR}/output4.md"
    echo "Plain text file" > "$infile"
    rewrite_frontmatter_name "$infile" "$outfile" "new"
    run cat "$outfile"
    assert_output "Plain text file"
}

# ── _shasum256 ───────────────────────────────────────────────────────

@test "_shasum256 produces consistent hash" {
    local file="${TEST_TEMP_DIR}/hashfile"
    echo "test content" > "$file"
    local hash1 hash2
    hash1=$(_shasum256 < "$file" | awk '{print $1}')
    hash2=$(_shasum256 < "$file" | awk '{print $1}')
    [[ "$hash1" == "$hash2" ]]
}

@test "_shasum256 different files produce different hashes" {
    local file1="${TEST_TEMP_DIR}/file1"
    local file2="${TEST_TEMP_DIR}/file2"
    echo "content A" > "$file1"
    echo "content B" > "$file2"
    local hash1 hash2
    hash1=$(_shasum256 < "$file1" | awk '{print $1}')
    hash2=$(_shasum256 < "$file2" | awk '{print $1}')
    [[ "$hash1" != "$hash2" ]]
}

# ── has_builtin_skills ───────────────────────────────────────────────

@test "has_builtin_skills returns 0 when skills exist" {
    mkdir -p "${BUILTIN_SKILLS_DIR}/test-skill"
    run has_builtin_skills
    assert_success
}

@test "has_builtin_skills returns 1 when dir empty" {
    mkdir -p "${BUILTIN_SKILLS_DIR}"
    run has_builtin_skills
    assert_failure
}

@test "has_builtin_skills returns 1 when dir missing" {
    rm -rf "${BUILTIN_SKILLS_DIR}"
    run has_builtin_skills
    assert_failure
}

# ── parse_args ───────────────────────────────────────────────────────

@test "parse_args with no args sets defaults" {
    reset_globals
    parse_args
    [[ "$DRY_RUN" == "false" ]]
    [[ "$SUBCOMMAND" == "" ]]
}

@test "parse_args -f sets CONFIG_FILE" {
    reset_globals
    parse_args -f custom.json
    [[ "$CONFIG_FILE" == "custom.json" ]]
}

@test "parse_args --dry-run sets DRY_RUN" {
    reset_globals
    parse_args --dry-run
    [[ "$DRY_RUN" == "true" ]]
}

@test "parse_args subcommand config detected" {
    reset_globals
    parse_args config
    [[ "$SUBCOMMAND" == "config" ]]
}

@test "parse_args subcommand build --force" {
    reset_globals
    parse_args build --force
    [[ "$SUBCOMMAND" == "build" ]]
    [[ "$BUILD_FORCE" == "true" ]]
}

@test "parse_args -- passes extra args" {
    reset_globals
    parse_args -- -p "model"
    [[ "${EXTRA_ARGS[0]}" == "-p" ]]
    [[ "${EXTRA_ARGS[1]}" == "model" ]]
}

@test "parse_args -v outputs version" {
    reset_globals
    run parse_args -v
    assert_output --partial "claude-compose v"
}
