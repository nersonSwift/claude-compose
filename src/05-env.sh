# Validate env key: POSIX identifier, not in blocklist
# $1 = key, $2 = source label (for error messages)
_validate_env_key() {
    local key="$1" source_label="${2:-}"
    # Reject non-POSIX identifiers (must start with letter/underscore, contain only alnum/underscore)
    case "$key" in
        [!a-zA-Z_]*|*[!a-zA-Z0-9_]*)
            echo -e "${RED}Warning: invalid env key '${key}' in ${source_label} — skipped${NC}" >&2
            return 1
            ;;
    esac
    # Blocklist dangerous variables
    case "$key" in
        PATH|HOME|SHELL|USER|LOGNAME|LD_PRELOAD|LD_LIBRARY_PATH|DYLD_*|IFS|CDPATH|BASH_ENV|ENV|TMPDIR|LD_AUDIT|LD_CONFIG|BASH_FUNC_*|PROMPT_COMMAND|GLOBIGNORE|HISTFILE|PYTHONPATH|NODE_PATH|RUBYLIB|PERL5LIB|GIT_SSH_COMMAND|GIT_EXEC_PATH|GIT_CONFIG_GLOBAL|GIT_DIR|GIT_WORK_TREE|GIT_AUTHOR_*|GIT_COMMITTER_*|GCONV_PATH|OPENAI_*|EDITOR|VISUAL|http_proxy|https_proxy|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|no_proxy|NO_PROXY|SSL_CERT_FILE|SSL_CERT_DIR|CURL_CA_BUNDLE|REQUESTS_CA_BUNDLE|NODE_EXTRA_CA_CERTS|NODE_OPTIONS|JAVA_TOOL_OPTIONS|_JAVA_OPTIONS|ANTHROPIC_*|CLAUDE_*|XDG_CONFIG_HOME|XDG_DATA_HOME)
            echo -e "${RED}Warning: dangerous env key '${key}' in ${source_label} — skipped${NC}" >&2
            return 1
            ;;
    esac
    return 0
}

# Check if a path contains traversal sequences
_has_path_traversal() {
    [[ "$1" == *"/.."* || "$1" == ".."* ]]
}

# Verify resolved path stays within expected directory
# $1 = file path (absolute), $2 = base directory (absolute)
# Uses cd+pwd approach for macOS compatibility (no realpath -m)
_is_within_dir() {
    local target="$1" base="$2"
    # Normalize: resolve .. and . components via shell
    # First strip trailing slashes for consistent comparison
    base="${base%/}"
    # For the target, resolve the directory part (must exist) + keep basename
    local target_dir target_base
    target_dir=$(dirname "$target")
    target_base=$(basename "$target")
    local resolved_dir
    resolved_dir=$(cd "$target_dir" 2>/dev/null && pwd -P) || return 1
    local resolved="${resolved_dir}/${target_base}"
    local resolved_base
    resolved_base=$(cd "$base" 2>/dev/null && pwd -P) || return 1
    [[ "$resolved" == "$resolved_base/"* ]]
}

# Load JSON env files from resources.env_files at launch time
load_env_files() {
    local env_files
    env_files=$(jq -r '.resources.env_files // [] | .[]' "$CONFIG_FILE" 2>/dev/null || true)
    while IFS= read -r env_file; do
        [[ -z "$env_file" ]] && continue
        local abs_path="$CONFIG_DIR/$env_file"
        if ! _is_within_dir "$abs_path" "$CONFIG_DIR"; then
            echo -e "${YELLOW}Warning: env file escapes base directory, skipping: ${env_file}${NC}" >&2
            continue
        fi
        if [[ ! -f "$abs_path" ]]; then
            echo -e "${YELLOW}Warning: env file not found: ${env_file}${NC}" >&2
            continue
        fi
        if ! jq empty "$abs_path" 2>/dev/null; then
            echo -e "${RED}Error: invalid JSON in env file: ${env_file}${NC}" >&2
            continue
        fi
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local key value
            key=$(echo "$line" | jq -r '.key')
            value=$(echo "$line" | jq -r '.value')
            _validate_env_key "$key" "$env_file" || continue
            export "$key=$value"
        done < <(jq -c 'to_entries[] | {key, value: (.value | tostring)}' "$abs_path")
        local var_count
        var_count=$(jq 'length' "$abs_path")
        echo -e "  ${GREEN}Loaded:${NC} ${env_file} (${var_count} vars)" >&2
    done <<< "$env_files"
}

# Load global env files (no prefix — intended to be available directly)
load_global_env_files() {
    [[ ! -f "$GLOBAL_CONFIG" ]] && return

    local env_files
    env_files=$(jq -r '.resources.env_files // [] | .[]' "$GLOBAL_CONFIG" 2>/dev/null || true)
    while IFS= read -r env_file; do
        [[ -z "$env_file" ]] && continue
        local abs_path="$GLOBAL_CONFIG_DIR/$env_file"
        if ! _is_within_dir "$abs_path" "$GLOBAL_CONFIG_DIR"; then
            echo -e "${YELLOW}Warning: env file escapes base directory, skipping: ${env_file}${NC}" >&2
            continue
        fi
        if [[ ! -f "$abs_path" ]]; then
            echo -e "${YELLOW}Warning: global env file not found: ${env_file}${NC}" >&2
            continue
        fi
        if ! jq empty "$abs_path" 2>/dev/null; then
            echo -e "${RED}Error: invalid JSON in global env file: ${env_file}${NC}" >&2
            continue
        fi
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local key value
            key=$(echo "$line" | jq -r '.key')
            value=$(echo "$line" | jq -r '.value')
            _validate_env_key "$key" "$env_file" || continue
            export "$key=$value"
        done < <(jq -c 'to_entries[] | {key, value: (.value | tostring)}' "$abs_path")
        local var_count
        var_count=$(jq 'length' "$abs_path")
        echo -e "  ${GREEN}Loaded:${NC} ${env_file} (${var_count} vars, global)" >&2
    done <<< "$env_files"
}

# Load env files from a source directory with prefixed keys (launch-time)
load_source_env_files() {
    local source_dir="$1" source_name="$2" config_filename="${3:-claude-compose.json}"
    local source_config="$source_dir/$config_filename"
    [[ ! -f "$source_config" ]] && return

    local prefix
    prefix=$(compute_source_prefix "$source_name" "$source_dir")

    local env_files
    env_files=$(jq -r '.resources.env_files // [] | .[]' "$source_config" 2>/dev/null || true)
    while IFS= read -r env_file; do
        [[ -z "$env_file" ]] && continue
        local abs_path="$source_dir/$env_file"
        if ! _is_within_dir "$abs_path" "$source_dir"; then
            echo -e "${YELLOW}Warning: env file escapes base directory, skipping: ${source_name}/${env_file}${NC}" >&2
            continue
        fi
        if [[ ! -f "$abs_path" ]]; then
            continue
        fi
        if ! jq empty "$abs_path" 2>/dev/null; then
            echo -e "${YELLOW}Warning: invalid JSON in source env file: ${source_name}/${env_file}${NC}" >&2
            continue
        fi
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local key value
            key=$(echo "$line" | jq -r '.key')
            value=$(echo "$line" | jq -r '.value')
            _validate_env_key "$key" "${source_name}/${env_file}" || continue
            export "${prefix}${key}=${value}"
        done < <(jq -c 'to_entries[] | {key, value: (.value | tostring)}' "$abs_path")
    done <<< "$env_files"
}

# Load env files from all external sources (workspaces) at launch time
load_all_source_env_files() {
    [[ ! -f "$COMPOSE_MANIFEST" ]] && return

    local source_names
    source_names=$(jq -r '.workspaces // {} | keys[]' "$COMPOSE_MANIFEST" 2>/dev/null || true)
    while IFS= read -r sname; do
        [[ -z "$sname" ]] && continue
        local source_dir="$sname"  # workspaces use absolute path as key
        [[ ! -d "$source_dir" ]] && continue
        local source_name
        source_name=$(jq -r --arg n "$sname" '.workspaces[$n].source_name // empty' "$COMPOSE_MANIFEST" 2>/dev/null || true)
        [[ -z "$source_name" ]] && source_name="$(basename "$source_dir")"
        load_source_env_files "$source_dir" "$source_name"
    done <<< "$source_names"
}
