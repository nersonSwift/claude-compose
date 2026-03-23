# Load JSON env files from resources.env_files at launch time
load_env_files() {
    local env_files
    env_files=$(jq -r '.resources.env_files // [] | .[]' "$CONFIG_FILE" 2>/dev/null || true)
    while IFS= read -r env_file; do
        [[ -z "$env_file" ]] && continue
        local abs_path="$PWD/$env_file"
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
            export "$key=$value"
        done < <(jq -c 'to_entries[] | {key, value: (.value | tostring)}' "$abs_path")
        local var_count
        var_count=$(jq 'length' "$abs_path")
        echo -e "  ${GREEN}Loaded:${NC} ${env_file} (${var_count} vars, global)" >&2
    done <<< "$env_files"
}

# Load env files from a source directory with prefixed keys (launch-time)
load_source_env_files() {
    local source_dir="$1" source_name="$2"
    local source_config="$source_dir/claude-compose.json"
    [[ ! -f "$source_config" ]] && return

    local prefix
    prefix=$(compute_source_prefix "$source_name" "$source_dir")

    local env_files
    env_files=$(jq -r '.resources.env_files // [] | .[]' "$source_config" 2>/dev/null || true)
    while IFS= read -r env_file; do
        [[ -z "$env_file" ]] && continue
        local abs_path="$source_dir/$env_file"
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
            export "${prefix}${key}=${value}"
        done < <(jq -c 'to_entries[] | {key, value: (.value | tostring)}' "$abs_path")
    done <<< "$env_files"
}

# Load env files from all external sources (presets + workspaces) at launch time
load_all_source_env_files() {
    [[ ! -f ".compose-manifest.json" ]] && return

    local section
    for section in presets workspaces; do
        local source_names
        source_names=$(jq -r --arg s "$section" '.[$s] // {} | keys[]' ".compose-manifest.json" 2>/dev/null || true)
        while IFS= read -r sname; do
            [[ -z "$sname" ]] && continue
            local source_dir
            if [[ "$section" == "presets" ]]; then
                if [[ "$sname" == github:* ]]; then
                    # GitHub preset: resolve dir from lock file
                    source_dir=$(resolve_locked_preset_dir "$sname" 2>/dev/null || true)
                    [[ -z "$source_dir" ]] && continue
                else
                    source_dir="$PRESETS_DIR/$sname"
                fi
            else
                source_dir="$sname"  # workspaces use absolute path as key
            fi
            [[ ! -d "$source_dir" ]] && continue
            load_source_env_files "$source_dir" "$(basename "$source_dir")"
        done <<< "$source_names"
    done
}
