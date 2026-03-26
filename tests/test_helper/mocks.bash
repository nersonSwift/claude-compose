#!/usr/bin/env bash

# Mock helpers for claude-compose bats tests

# Create an executable mock script that records calls
# $1 = command name, $2 = exit code (default 0), $3 = output (default "")
setup_mock() {
    local cmd="$1"
    local exit_code="${2:-0}"
    local output="${3:-}"
    local mock_dir="${TEST_TEMP_DIR}/mocks"

    mkdir -p "$mock_dir"

    cat > "${mock_dir}/${cmd}" <<MOCK_EOF
#!/usr/bin/env bash
echo "\$@" >> "${mock_dir}/${cmd}.calls"
${output:+echo "${output}"}
exit ${exit_code}
MOCK_EOF
    chmod +x "${mock_dir}/${cmd}"

    # Prepend mock dir to PATH
    export PATH="${mock_dir}:${PATH}"
}

# Specialized git mock for ls-remote (returns tags) and clone (creates dirs)
# $1 = tags output (newline-separated, e.g. "refs/tags/v1.0.0\nrefs/tags/v2.0.0")
mock_git_ls_remote() {
    local tags_output="$1"
    local mock_dir="${TEST_TEMP_DIR}/mocks"

    mkdir -p "$mock_dir"

    cat > "${mock_dir}/git" <<MOCK_EOF
#!/usr/bin/env bash
echo "\$@" >> "${mock_dir}/git.calls"
case "\$1" in
    ls-remote)
        while IFS= read -r tag; do
            [[ -z "\$tag" ]] && continue
            echo "abc123def456\t\$tag"
        done <<< "${tags_output}"
        ;;
    clone)
        # Find the target directory (last argument)
        local target="\${@: -1}"
        mkdir -p "\$target"
        ;;
    *)
        ;;
esac
exit 0
MOCK_EOF
    chmod +x "${mock_dir}/git"
    export PATH="${mock_dir}:${PATH}"
}

# Assert mock was called with specific args (substring match)
# $1 = command name, $2 = expected args substring
assert_mock_called_with() {
    local cmd="$1"
    local expected="$2"
    local calls_file="${TEST_TEMP_DIR}/mocks/${cmd}.calls"

    assert_file_exists "$calls_file"
    run grep -F -- "$expected" "$calls_file"
    assert_success
}

# Assert mock was never called
# $1 = command name
assert_mock_not_called() {
    local cmd="$1"
    local calls_file="${TEST_TEMP_DIR}/mocks/${cmd}.calls"

    assert_file_not_exists "$calls_file"
}
