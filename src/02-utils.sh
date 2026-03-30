# ── Usage ────────────────────────────────────────────────────────────
usage() {
    echo -e "${BOLD}claude-compose${NC} v${VERSION} — Multi-project Claude Code launcher"
    echo ""
    echo -e "${BOLD}Usage:${NC}"
    echo "  claude-compose [options] [-- claude-args...]"
    echo "  claude-compose build [--force]"
    echo "  claude-compose config [-y <path>] [--check] [-f <file>]"
    echo "  claude-compose migrate <project-path> [--delete] [--workspace <path>]"
    echo "  claude-compose copy <source-workspace> [dest-path]"
    echo "  claude-compose doctor"
    echo "  claude-compose start [root-path]"
    echo "  claude-compose wrap <claude-binary> [args...]"
    echo "  claude-compose ide [variant]"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo "  build         Build workspace from workspaces/resources/plugins (auto on launch)"
    echo "  config        Create or manage claude-compose.json config"
    echo "  migrate       Copy Claude config from a project into this workspace"
    echo "  copy          Clone a workspace to a new location"
    echo "  doctor        Diagnose and fix compose problems"
    echo "  start         Onboarding wizard — scan for projects and create workspaces"
    echo "  wrap          VS Code process wrapper mode (used internally by wrapper script)"
    echo "  ide           Set up IDE integration (wrapper + .code-workspace)"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  -f <file>     Config file (default: claude-compose.json)"
    echo "  --dry-run     Show what would happen without executing"
    echo "  --force       Force rebuild even if up to date (build only)"
    echo "  --delete      Remove originals after migration (migrate only)"
    echo "  --workspace   Target workspace directory (migrate only, default: CWD)"
    echo "  -y, --yes     Skip prompts, use defaults (config only)"
    echo "  --check       Validate config via dry-run (config only)"
    echo "  -h, --help    Show this help"
    echo "  -v, --version Show version"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  claude-compose                              # Launch from workspace"
    echo "  claude-compose build                        # Build workspace explicitly"
    echo "  claude-compose config                       # Create or edit config"
    echo "  claude-compose config -y ~/Code/app         # Quick create with defaults"
    echo "  claude-compose migrate ~/Code/app           # Import config from project"
    echo "  claude-compose copy ~/ws/main ~/ws/feature  # Clone workspace"
    echo "  claude-compose doctor                        # Diagnose problems"
    echo "  claude-compose start ~/Code                  # Onboarding wizard"
    echo "  claude-compose ide                           # Set up IDE integration"
    echo "  claude-compose ide cursor                    # Set up for Cursor editor"
    echo "  claude-compose --dry-run                    # Preview mode"
    echo "  claude-compose -- -p \"explain arch\"         # Pass args to claude"
}

# ── Glob matching ────────────────────────────────────────────────────
# Returns 0 if $1 matches any pattern in the include list AND
# does not match any pattern in the exclude list.
# $1 = name, $2 = include JSON array, $3 = exclude JSON array
matches_filter() {
    local name="$1"
    local include_json="$2"
    local exclude_json="$3"

    local include_count
    include_count=$(jq -r 'length' <<< "$include_json")

    if [[ "$include_count" -eq 0 ]]; then
        return 1
    fi

    local included=false
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        # shellcheck disable=SC2053
        if [[ "$name" == $pattern ]]; then
            included=true
            break
        fi
    done < <(jq -r '.[]' <<< "$include_json")

    if [[ "$included" == false ]]; then
        return 1
    fi

    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        # shellcheck disable=SC2053
        if [[ "$name" == $pattern ]]; then
            return 1
        fi
    done < <(jq -r '.[]' <<< "$exclude_json")

    return 0
}

# ── Expand ~ safely + resolve relative paths ──────────────────────────
# $1 = path, $2 = optional base_dir for relative path resolution
expand_path() {
    local path="$1"
    local base_dir="${2:-}"
    path="${path/#\~/$HOME}"
    if [[ "$path" == /* ]]; then
        printf '%s\n' "$path"
    elif [[ -n "$base_dir" ]]; then
        printf '%s\n' "${base_dir}/${path}"
    else
        printf '%s\n' "$path"
    fi
}

# ── Parse CLI args ───────────────────────────────────────────────────
parse_args() {
    # Detect subcommand as first positional argument
    if [[ $# -gt 0 ]]; then
        case "$1" in
            config|build|migrate|copy|doctor|start|wrap|ide)
                SUBCOMMAND="$1"
                shift
                ;;
        esac
    fi

    # Wrap mode: capture all remaining args verbatim (no compose flag parsing)
    # VS Code passes args like --output-format stream-json that would collide with compose flags
    if [[ "$SUBCOMMAND" == "wrap" ]]; then
        if [[ $# -lt 1 ]]; then
            echo -e "${RED}Error: wrap requires claude binary path${NC}" >&2
            echo "Usage: claude-compose wrap /path/to/claude [args...]" >&2
            exit 1
        fi
        WRAP_CLAUDE_BIN="$1"
        shift
        WRAP_PASSTHROUGH_ARGS=("$@")
        # shellcheck disable=SC2034
        WRAP_MODE=true
        CONFIG_FILE="claude-compose.json"
        return
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f)
                if [[ $# -lt 2 ]]; then
                    echo -e "${RED}Error: -f requires an argument${NC}" >&2
                    exit 1
                fi
                shift
                CONFIG_FILE="$1"
                ;;
            --dry-run)
                DRY_RUN=true
                ;;
            --force)
                BUILD_FORCE=true
                ;;
            --check)
                CONFIG_CHECK=true
                ;;
            --delete)
                MIGRATE_DELETE=true
                ;;
            --workspace)
                if [[ $# -lt 2 ]]; then
                    echo -e "${RED}Error: --workspace requires an argument${NC}" >&2
                    exit 1
                fi
                shift
                MIGRATE_WORKSPACE="$1"
                ;;
            -y|--yes)
                CONFIG_YES=true
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -v|--version)
                echo "claude-compose v${VERSION}"
                exit 0
                ;;
            --)
                shift
                EXTRA_ARGS=("$@")
                break
                ;;
            *)
                # Handle positional args per subcommand
                case "$SUBCOMMAND" in
                    config)
                        if [[ -z "$CONFIG_PATH" && "$1" != -* ]]; then
                            CONFIG_PATH="$1"
                        else
                            echo -e "${RED}Unknown option: $1${NC}" >&2
                            usage >&2
                            exit 1
                        fi
                        ;;
                    migrate)
                        if [[ -z "$MIGRATE_PATH" && "$1" != -* ]]; then
                            MIGRATE_PATH="$1"
                        else
                            echo -e "${RED}Unknown option: $1${NC}" >&2
                            usage >&2
                            exit 1
                        fi
                        ;;
                    copy)
                        if [[ -z "$COPY_SOURCE" && "$1" != -* ]]; then
                            COPY_SOURCE="$1"
                        elif [[ -z "$COPY_DEST" && "$1" != -* ]]; then
                            COPY_DEST="$1"
                        else
                            echo -e "${RED}Unknown option: $1${NC}" >&2
                            usage >&2
                            exit 1
                        fi
                        ;;
                    start)
                        if [[ -z "$START_PATH" && "$1" != -* ]]; then
                            START_PATH="$1"
                        else
                            echo -e "${RED}Unknown option: $1${NC}" >&2
                            usage >&2
                            exit 1
                        fi
                        ;;
                    ide)
                        if [[ -z "$IDE_VARIANT" && "$1" != -* ]]; then
                            IDE_VARIANT="$1"
                        else
                            echo -e "${RED}Unknown option: $1${NC}" >&2
                            usage >&2
                            exit 1
                        fi
                        ;;
                    *)
                        echo -e "${RED}Unknown option: $1${NC}" >&2
                        usage >&2
                        exit 1
                        ;;
                esac
                ;;
        esac
        shift
    done

    # Default config file
    if [[ -z "$CONFIG_FILE" ]]; then
        CONFIG_FILE="claude-compose.json"
    fi

    # Validate flag combinations
    if [[ "$CONFIG_YES" == true && "$SUBCOMMAND" != "config" ]]; then
        echo -e "${RED}Error: -y/--yes can only be used with 'config'${NC}" >&2
        exit 1
    fi
    if [[ "$CONFIG_CHECK" == true && "$SUBCOMMAND" != "config" ]]; then
        echo -e "${RED}Error: --check can only be used with 'config'${NC}" >&2
        exit 1
    fi
    if [[ "$BUILD_FORCE" == true && "$SUBCOMMAND" != "build" ]]; then
        echo -e "${RED}Error: --force can only be used with 'build'${NC}" >&2
        exit 1
    fi
    if [[ "$MIGRATE_DELETE" == true && "$SUBCOMMAND" != "migrate" ]]; then
        echo -e "${RED}Error: --delete can only be used with 'migrate'${NC}" >&2
        exit 1
    fi
    if [[ -n "$MIGRATE_WORKSPACE" && "$SUBCOMMAND" != "migrate" ]]; then
        echo -e "${RED}Error: --workspace can only be used with 'migrate'${NC}" >&2
        exit 1
    fi
}

# ── Merge compose settings ──────────────────────────────────────────
# Merge compose-generated settings with user settings.
# User settings take precedence; array keys (claudeMdExcludes) are concatenated.
# $1 = compose JSON, $2 = user JSON
merge_compose_settings() {
    local base="$1" overlay="$2"
    jq -n --argjson base "$base" --argjson overlay "$overlay" '
        $base * $overlay +
        (if ($base.claudeMdExcludes // null) != null and ($overlay.claudeMdExcludes // null) != null
         then {claudeMdExcludes: (($base.claudeMdExcludes + $overlay.claudeMdExcludes) | unique)}
         elif ($base.claudeMdExcludes // null) != null
         then {claudeMdExcludes: $base.claudeMdExcludes}
         else {} end)
    '
}

# ── SHA tool detection (portability: macOS=shasum, Linux=sha256sum) ──
# _SHASUM_CMD: used for file fingerprinting via xargs (SHA-1 on macOS, SHA-256 on Linux)
# _shasum256: used for final content hash only
if command -v shasum &>/dev/null; then
    _SHASUM_CMD="shasum"
    _shasum256() { shasum -a 256 "$@"; }
elif command -v sha256sum &>/dev/null; then
    _SHASUM_CMD="sha256sum"
    # shellcheck disable=SC2120
    _shasum256() { sha256sum "$@"; }
else
    _SHASUM_CMD="false"
    # shellcheck disable=SC2120
    _shasum256() { echo "error: no shasum or sha256sum found" >&2; return 1; }
fi

# ── Require tools ────────────────────────────────────────────────────
require_jq() {
    if ! command -v jq &>/dev/null; then
        echo -e "${RED}Error: jq is required but not installed.${NC}" >&2
        if [[ "$(uname)" == "Darwin" ]]; then
            echo "  Install: brew install jq" >&2
        else
            echo "  Install: sudo apt install jq" >&2
        fi
        # shellcheck disable=SC2034
        DOCTOR_ENABLED=false
        exit 1
    fi
}

require_claude() {
    if ! command -v claude &>/dev/null; then
        echo -e "${RED}Error: claude CLI not found in PATH.${NC}" >&2
        echo "  Install: https://claude.ai/code" >&2
        # shellcheck disable=SC2034
        DOCTOR_ENABLED=false
        exit 1
    fi
}

# ── Builtin plugin check ───────────────────────────────────────────
has_builtin_plugin() {
    [[ -d "$BUILTIN_PLUGIN_DIR/.claude-plugin" ]]
}

# ── Doctor helpers ──────────────────────────────────────────────────
die_doctor() {
    DOCTOR_ERROR_MSG="${1:-Unknown error}"
    exit 1
}

launch_doctor() {
    local error_msg="$1"
    local config_file="${CONFIG_FILE:-claude-compose.json}"
    local ws_dir
    ws_dir="${WORKSPACE_DIR:-$(dirname "$config_file")}"

    local prompt
    prompt=$(compose_doctor_prompt "$config_file" "$ws_dir" "$error_msg")

    echo -e "${YELLOW}Launching doctor...${NC}" >&2

    if [[ -n "$error_msg" ]]; then
        (cd "$ws_dir" && claude --system-prompt "$prompt" "fix it")
    else
        (cd "$ws_dir" && claude --system-prompt "$prompt")
    fi
}

# ERR trap: capture context of unexpected failures for doctor.
# Saves failing command, line number, stack trace into DOCTOR_ERROR_MSG.
_doctor_err_trap() {
    # Capture BASH_COMMAND/LINENO immediately — they change on any statement
    local _err_cmd=${BASH_COMMAND} _err_line=${BASH_LINENO[0]}
    local _err_func=${FUNCNAME[1]:-main} _err_script=${BASH_SOURCE[0]:-$0}

    # Skip if already captured (die_doctor or previous ERR)
    case "${DOCTOR_ERROR_MSG:-}" in ?*) return 0 ;; esac

    # Build stack trace
    local _trace="" _i
    for (( _i=1; _i < ${#FUNCNAME[@]}; _i++ )); do
        _trace+="  ${FUNCNAME[$_i]}() at line ${BASH_LINENO[$((_i-1))]}"$'\n'
    done

    # Read the failing source line from the script
    local _src_line=""
    _src_line=$(sed -n "${_err_line}p" "$_err_script" 2>/dev/null) || true

    DOCTOR_ERROR_MSG="Unexpected error in ${_err_func}() at line ${_err_line}
Command: ${_err_cmd}
Source:  ${_src_line:-(unable to read)}

Stack trace:
${_trace}"
}

_doctor_trap() {
    local exit_code=$?
    # Remove traps to prevent recursion
    trap - EXIT ERR

    # Release build lock if held (RETURN trap doesn't fire on exit)
    if [[ "${_BUILD_LOCK_HELD:-}" == true ]]; then
        _release_lock "$COMPOSE_LOCK" 2>/dev/null || true
        _BUILD_LOCK_HELD=false
    fi

    local was_enabled="$DOCTOR_ENABLED"
    # shellcheck disable=SC2034
    DOCTOR_ENABLED=false

    if [[ "$was_enabled" == true && "$exit_code" -ne 0 && "$DRY_RUN" != true ]]; then
        launch_doctor "${DOCTOR_ERROR_MSG:-Unknown error (exit code $exit_code)}"
    fi
}

# ── Resolve workspace directory from config ──────────────────────────
# Sets globals: CONFIG_DIR, WORKSPACE_DIR, ORIGINAL_CWD.
# Prerequisite: CONFIG_FILE must be an absolute path.
# Side effect: cd to WORKSPACE_DIR.
_resolve_workspace_dir() {
    # Follow symlink to resolve real config location (e.g. when launched from workspace_path dir)
    if [[ -L "$CONFIG_FILE" ]]; then
        local _link_target
        _link_target=$(readlink "$CONFIG_FILE")
        if [[ "$_link_target" == /* ]]; then
            CONFIG_FILE="$_link_target"
        else
            CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd -P)/$_link_target"
        fi
        # Re-resolve to absolute (link target may contain ../)
        local _resolved_dir
        _resolved_dir="$(cd "$(dirname "$CONFIG_FILE")" && pwd -P)"
        CONFIG_FILE="${_resolved_dir}/$(basename "$CONFIG_FILE")"
    fi
    CONFIG_DIR="$(dirname "$CONFIG_FILE")"
    ORIGINAL_CWD="$CONFIG_DIR"
    WORKSPACE_DIR="$CONFIG_DIR"
    if [[ -f "$CONFIG_FILE" ]] && jq empty "$CONFIG_FILE" 2>/dev/null; then
        local raw_ws_path
        raw_ws_path=$(jq -r '.workspace_path // empty' "$CONFIG_FILE" 2>/dev/null || true)
        if [[ -n "$raw_ws_path" ]]; then
            WORKSPACE_DIR=$(expand_path "$raw_ws_path" "$CONFIG_DIR")
            mkdir -p "$WORKSPACE_DIR"
            WORKSPACE_DIR=$(cd "$WORKSPACE_DIR" && pwd -P)
            if [[ "$WORKSPACE_DIR" != "$CONFIG_DIR" ]]; then
                local ws_config="$WORKSPACE_DIR/claude-compose.json"
                if [[ ! -e "$ws_config" ]] || [[ -L "$ws_config" ]]; then
                    ln -sf "$CONFIG_FILE" "$ws_config"
                elif [[ -f "$ws_config" ]]; then
                    warn_info "workspace" "workspace_path contains its own claude-compose.json, skipping symlink"
                fi
            fi
        fi
    fi
    cd "$WORKSPACE_DIR"
}

# Ensure compose output directory exists
ensure_compose_dir() { mkdir -p "$COMPOSE_DIR"; }

# Atomic file write: writes content to a temp file, then moves it into place.
# Usage: atomic_write "destination_path" "content"
atomic_write() {
    local dest="$1" content="$2"
    local tmp
    tmp=$(mktemp "${dest}.XXXXXX")
    if printf '%s\n' "$content" > "$tmp"; then
        mv "$tmp" "$dest"
    else
        rm -f "$tmp"
        return 1
    fi
}

# Rewrite name: in YAML frontmatter safely (no sed metachar injection)
# $1 = input file, $2 = output file, $3 = new name
rewrite_frontmatter_name() {
    local input="$1" output="$2" new_name="$3"
    # Pass name via environment to avoid awk -v interpreting backslash escapes
    _AWK_NEW_NAME="$new_name" awk '
        BEGIN { in_fm = 0; fm_count = 0; done = 0 }
        /^---$/ { fm_count++; in_fm = (fm_count == 1) ? 1 : 0 }
        in_fm && !done && /^name:/ { print "name: " ENVIRON["_AWK_NEW_NAME"]; done = 1; next }
        { print }
    ' "$input" > "$output"
}

# ── Check if there are any resources to build ────────────────────────
_has_anything_to_build() {
    local ws_count has_resources has_global
    ws_count=$(jq '.workspaces // [] | length' "$CONFIG_FILE")
    has_resources=$(jq 'has("resources") and (.resources | length > 0)' "$CONFIG_FILE")
    has_global=false; [[ -f "$GLOBAL_CONFIG" ]] && has_global=true
    [[ "$ws_count" -gt 0 || "$has_resources" == "true" || "$has_global" == "true" ]] || has_builtin_plugin
}

# ── Reset source tracking arrays ──────────────────────────────────────
_reset_current_source() {
    CURRENT_SOURCE_AGENTS=()
    CURRENT_SOURCE_SKILLS=()
    CURRENT_SOURCE_MCP_SERVERS=()
    CURRENT_SOURCE_ADD_DIRS=()
    CURRENT_SOURCE_PROJECT_DIRS=()
    CURRENT_SOURCE_NAME=""
}

# ── Warning collection helpers ────────────────────────────────────────
# Record a critical warning (will trigger doctor at end of build).
# $1 = source label, $2 = message, $3 = verbose (default "true")
warn_critical() {
    local source="$1" msg="$2" verbose="${3:-true}"
    _WARNINGS_CRITICAL+=("${source}|${msg}")
    if [[ "$verbose" == "true" ]]; then
        echo -e "  ${YELLOW}Warning: ${msg}${NC}" >&2
    fi
}

# Record an informational warning (display only, no doctor).
# $1 = source label, $2 = message, $3 = verbose (default "true")
warn_info() {
    local source="$1" msg="$2" verbose="${3:-true}"
    _WARNINGS_INFO+=("${source}|${msg}")
    if [[ "$verbose" == "true" ]]; then
        echo -e "  ${YELLOW}Warning: ${msg}${NC}" >&2
    fi
}

# Format all collected warnings as structured text.
_format_warning_summary() {
    local summary=""
    if [[ ${#_WARNINGS_CRITICAL[@]} -gt 0 ]]; then
        summary+="Critical warnings (${#_WARNINGS_CRITICAL[@]}):"$'\n'
        local w
        for w in "${_WARNINGS_CRITICAL[@]}"; do
            summary+="  [${w%%|*}] ${w#*|}"$'\n'
        done
    fi
    if [[ ${#_WARNINGS_INFO[@]} -gt 0 ]]; then
        [[ -n "$summary" ]] && summary+=$'\n'
        summary+="Informational warnings (${#_WARNINGS_INFO[@]}):"$'\n'
        local w
        for w in "${_WARNINGS_INFO[@]}"; do
            summary+="  [${w%%|*}] ${w#*|}"$'\n'
        done
    fi
    echo "$summary"
}

# Check warnings and trigger doctor if critical ones exist.
# Always prints summary (regardless of verbose).
_check_warnings_and_report() {
    local total=$(( ${#_WARNINGS_CRITICAL[@]} + ${#_WARNINGS_INFO[@]} ))
    [[ "$total" -eq 0 ]] && return 0

    echo "" >&2
    echo -e "${BOLD}── Warning Summary ──${NC}" >&2
    _format_warning_summary >&2

    if [[ ${#_WARNINGS_CRITICAL[@]} -gt 0 ]]; then
        local summary
        summary=$(_format_warning_summary)
        die_doctor "Build completed with critical warnings:"$'\n'"${summary}"
    fi
}

# Wrap-mode variant: check warnings and launch wrap doctor if critical.
# Uses _wrap_launch_doctor instead of die_doctor (no EXIT trap in wrap mode).
_wrap_check_warnings() {
    [[ ${#_WARNINGS_CRITICAL[@]} -eq 0 ]] && return 0

    echo "" >&2
    echo -e "${BOLD}── Warning Summary ──${NC}" >&2
    _format_warning_summary >&2

    local summary
    summary=$(_format_warning_summary)
    _wrap_launch_doctor "Critical warnings during workspace preparation:"$'\n'"${summary}"
}

# Acquire a directory-based lock (POSIX-portable, no flock needed)
# $1 = lock dir path
_acquire_lock() {
    local lock_dir="$1"
    local attempts=0 stale_retries=0
    while ! mkdir "$lock_dir" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [[ "$attempts" -ge 25 ]]; then
            # Check if lock holder is still alive
            local lock_pid=""
            [[ -f "$lock_dir/pid" ]] && lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || true)
            if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
                echo -e "${YELLOW}Warning: Lock ${lock_dir} held by active process ${lock_pid}${NC}" >&2
                return 1
            fi
            # Stale lock — force-remove and retry the loop
            stale_retries=$((stale_retries + 1))
            if [[ "$stale_retries" -ge 3 ]]; then
                echo -e "${YELLOW}Warning: Failed to acquire lock ${lock_dir} after stale retries${NC}" >&2
                return 1
            fi
            rm -rf "$lock_dir"
            attempts=0
            continue
        fi
        sleep 0.2
    done
    echo "$$" > "$lock_dir/pid"
}

# Release a directory-based lock
# $1 = lock dir path
_release_lock() {
    rm -rf "$1" 2>/dev/null || true
}
