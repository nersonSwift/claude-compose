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
    echo "  claude-compose update [source]"
    echo "  claude-compose registries"
    echo "  claude-compose instructions"
    echo "  claude-compose doctor"
    echo "  claude-compose start [root-path]"
    echo "  claude-compose wrap <claude-binary> [args...]"
    echo "  claude-compose vscode [variant]"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo "  build         Build workspace from presets/workspaces/resources (auto on launch)"
    echo "  config        Create or manage claude-compose.json config"
    echo "  migrate       Copy Claude config from a project into this workspace"
    echo "  copy          Clone a workspace to a new location"
    echo "  update        Check and apply updates for GitHub presets"
    echo "  registries    List configured GitHub presets and their status"
    echo "  instructions  Show instructions for managing workspace resources"
    echo "  doctor        Diagnose and fix compose problems"
    echo "  start         Onboarding wizard — scan for projects and create workspaces"
    echo "  wrap          VS Code process wrapper mode (used internally by wrapper script)"
    echo "  vscode        Set up VS Code integration (wrapper + .code-workspace)"
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
    echo "  claude-compose build                        # Build presets explicitly"
    echo "  claude-compose config                       # Create or edit config"
    echo "  claude-compose config -y ~/Code/app         # Quick create with defaults"
    echo "  claude-compose migrate ~/Code/app           # Import config from project"
    echo "  claude-compose copy ~/ws/main ~/ws/feature  # Clone workspace"
    echo "  claude-compose doctor                        # Diagnose problems"
    echo "  claude-compose start ~/Code                  # Onboarding wizard"
    echo "  claude-compose vscode                        # Set up VS Code integration"
    echo "  claude-compose vscode cursor                 # Set up for Cursor editor"
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
    include_count=$(echo "$include_json" | jq -r 'length')

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
    done < <(echo "$include_json" | jq -r '.[]')

    if [[ "$included" == false ]]; then
        return 1
    fi

    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        # shellcheck disable=SC2053
        if [[ "$name" == $pattern ]]; then
            return 1
        fi
    done < <(echo "$exclude_json" | jq -r '.[]')

    return 0
}

# Merge parent and child preset filter JSON for recursive inheritance.
# exclude: union (accumulates down the tree)
# include: child overrides parent if child specifies; otherwise inherits parent's
# $1 = parent filter JSON, $2 = child filter JSON
# Prints: merged filter JSON
merge_preset_filters() {
    local parent="$1" child="$2"
    jq -n --argjson p "$parent" --argjson c "$child" '
        def merge_section($p; $c):
            {
                include: (if ($c | has("include")) then $c.include
                         elif ($p | has("include")) then $p.include
                         else null end),
                exclude: ([$p.exclude // [] | .[], $c.exclude // [] | .[]] | unique)
            } | with_entries(select(.value != null));
        {
            agents: merge_section($p.agents // {}; $c.agents // {}),
            skills: merge_section($p.skills // {}; $c.skills // {}),
            mcp: merge_section($p.mcp // {}; $c.mcp // {})
        } | with_entries(select(.value != {}))'
}

# ── Expand ~ safely ─────────────────────────────────────────────────
expand_path() {
    local path="$1"
    echo "${path/#\~/$HOME}"
}

# Check if a preset string should be treated as a path (not a name)
_is_preset_path() {
    [[ "$1" == */* || "$1" == ~* ]]
}

# Resolve a preset path to an absolute directory
# $1 = raw path string, $2 = base directory for relative resolution
resolve_preset_path() {
    local raw="$1" base_dir="$2"
    local expanded
    expanded=$(expand_path "$raw")
    if [[ "$expanded" != /* ]]; then
        expanded="$base_dir/$expanded"
    fi
    if [[ -d "$expanded" ]]; then
        expanded=$(cd "$expanded" && pwd -P)
    fi
    echo "$expanded"
}

# ── Parse CLI args ───────────────────────────────────────────────────
parse_args() {
    # Detect subcommand as first positional argument
    if [[ $# -gt 0 ]]; then
        case "$1" in
            config|build|migrate|copy|instructions|update|registries|doctor|start|wrap|vscode)
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
                    update)
                        if [[ -z "$UPDATE_SOURCE" && "$1" != -* ]]; then
                            UPDATE_SOURCE="$1"
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
                    vscode)
                        if [[ -z "$VSCODE_VARIANT" && "$1" != -* ]]; then
                            VSCODE_VARIANT="$1"
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

# ── Builtin skills check ───────────────────────────────────────────
has_builtin_skills() {
    [[ ! -d "$BUILTIN_SKILLS_DIR" ]] && return 1
    local _d
    for _d in "$BUILTIN_SKILLS_DIR"/*/; do
        [[ -d "$_d" ]] && return 0
    done
    return 1
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
    ws_dir="$(dirname "$config_file")"

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
        _release_lock ".compose-build.lock" 2>/dev/null || true
        _BUILD_LOCK_HELD=false
    fi

    local was_enabled="$DOCTOR_ENABLED"
    # shellcheck disable=SC2034
    DOCTOR_ENABLED=false

    if [[ "$was_enabled" == true && "$exit_code" -ne 0 && "$DRY_RUN" != true ]]; then
        launch_doctor "${DOCTOR_ERROR_MSG:-Unknown error (exit code $exit_code)}"
    fi
}

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
