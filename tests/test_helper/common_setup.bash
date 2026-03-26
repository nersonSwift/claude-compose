#!/usr/bin/env bash

# Common test setup for claude-compose bats tests

_common_setup() {
    # Load bats helper libraries
    load '../lib/bats-support/load'
    load '../lib/bats-assert/load'
    load '../lib/bats-file/load'

    # Determine project root
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"

    # Create isolated temp directory for this test
    TEST_TEMP_DIR="$(mktemp -d)"

    # Source the test library with relaxed error handling
    # (source file has set -eEuo pipefail)
    set +eEu +o pipefail
    source "${PROJECT_ROOT}/tests/test_helper/claude-compose-functions.sh"
    set -eEu

    # Stub extract_embedded_skills (stripped from test lib)
    extract_embedded_skills() { :; }

    # Override HOME-based globals to use isolated temp dirs
    PRESETS_DIR="${TEST_TEMP_DIR}/presets"
    BUILTIN_SKILLS_DIR="${TEST_TEMP_DIR}/builtin_skills"
    GLOBAL_CONFIG="${TEST_TEMP_DIR}/global.json"
    GLOBAL_CONFIG_DIR="${TEST_TEMP_DIR}"
    REGISTRIES_DIR="${TEST_TEMP_DIR}/registries"
    ORIGINAL_CWD="${TEST_TEMP_DIR}/workspace"
    CONFIG_FILE="${TEST_TEMP_DIR}/workspace/claude-compose.json"
    LOCK_FILE="${TEST_TEMP_DIR}/workspace/claude-compose.lock.json"

    # Create workspace directory
    mkdir -p "${TEST_TEMP_DIR}/workspace"
    mkdir -p "${PRESETS_DIR}"

    # Disable colors
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    BOLD=''
    NC=''

    # Disable doctor mode
    DOCTOR_ENABLED=false
}

_common_teardown() {
    if [[ -n "${TEST_TEMP_DIR:-}" && -d "${TEST_TEMP_DIR:-}" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# Reset all mutable globals from 01-globals.sh to their defaults
reset_globals() {
    CONFIG_FILE="${TEST_TEMP_DIR}/workspace/claude-compose.json"
    LOCK_FILE="${TEST_TEMP_DIR}/workspace/claude-compose.lock.json"
    DRY_RUN=false
    EXTRA_ARGS=()
    ORIGINAL_CWD="${TEST_TEMP_DIR}/workspace"
    CLAUDE_ARGS=()
    COMPOSE_CLAUDE_MD_EXCLUDES=()
    HAS_ANY_ADD_DIR=false
    SUBCOMMAND=""
    CONFIG_YES=false
    CONFIG_PATH=""
    CONFIG_CHECK=false
    BUILD_FORCE=false
    MIGRATE_DELETE=false
    MIGRATE_WORKSPACE=""
    MIGRATE_PATH=""
    COPY_SOURCE=""
    COPY_DEST=""
    UPDATE_SOURCE=""
    START_PATH=""
    DOCTOR_ERROR_MSG=""
    DOCTOR_ENABLED=false
    PROCESSED_PRESETS=()
    PROCESSED_WORKSPACES=()
    MANIFEST_JSON='{"builtin":{},"global":{},"presets":{},"workspaces":{},"resources":{}}'
    CURRENT_SOURCE_AGENTS=()
    CURRENT_SOURCE_SKILLS=()
    CURRENT_SOURCE_MCP_SERVERS=()
    CURRENT_SOURCE_ADD_DIRS=()
    CURRENT_SOURCE_PROJECT_DIRS=()
    CURRENT_SOURCE_SYSTEM_PROMPT_FILES=()
    CURRENT_SOURCE_SETTINGS_FILES=()
    CURRENT_PRESET_PREFIX=""
    CURRENT_PRESET_RENAME='{}'
    CURRENT_SOURCE_NAME=""
    _BUILD_LOCK_HELD=false
}
