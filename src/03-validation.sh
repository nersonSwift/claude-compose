# ── Validate workspace ──────────────────────────────────────────────
validate() {
    require_jq
    require_claude

    # Check git availability if github presets are configured
    if [[ -f "$CONFIG_FILE" ]] && has_github_presets "$CONFIG_FILE"; then
        require_git
    fi
    if [[ -f "$GLOBAL_CONFIG" ]] && has_github_presets "$GLOBAL_CONFIG"; then
        require_git
    fi

    # Validate global config first (before workspace config check)
    validate_global_config

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}Error: Config not found: ${CONFIG_FILE}${NC}" >&2
        echo -e "${YELLOW}Launching Claude to create the config...${NC}" >&2
        local ws_dir
        ws_dir="$(dirname "$CONFIG_FILE")"
        local prompt
        prompt=$(compose_config_prompt "$CONFIG_FILE")
        (cd "$ws_dir" && claude --system-prompt "$prompt" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}")
        exit 0
    fi

    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        echo -e "${RED}Error: Invalid JSON in ${CONFIG_FILE}${NC}" >&2
        jq empty "$CONFIG_FILE" 2>&1 | head -5 >&2
        exit 1
    fi

    local semantic_error
    semantic_error=$(validate_config_semantics "$CONFIG_FILE")
    if [[ -n "$semantic_error" ]]; then
        echo -e "${RED}Config error: ${semantic_error}${NC}" >&2
        if [[ "$DRY_RUN" == true ]]; then
            exit 1
        fi
        echo -e "${YELLOW}Launching Claude to fix the config...${NC}" >&2
        local ws_dir
        ws_dir=$(dirname "$CONFIG_FILE")
        local prompt
        prompt=$(compose_fix_prompt "$CONFIG_FILE" "$semantic_error")
        (cd "$ws_dir" && claude --system-prompt "$prompt" -p "do it")
        exit 0
    fi
}

validate_config_semantics() {
    local config_file="$1"

    local projects_type
    projects_type=$(jq -r 'if has("projects") then .projects | type else "null" end' "$config_file")
    if [[ "$projects_type" != "null" && "$projects_type" != "array" ]]; then
        echo "\"projects\" must be an array, got: ${projects_type}"
        return
    fi

    local project_count
    project_count=$(jq '.projects // [] | length' "$config_file")

    if [[ "$project_count" -gt 0 ]]; then
        local missing=()
        for i in $(seq 0 $((project_count - 1))); do
            local name
            name=$(jq -r ".projects[$i].name // empty" "$config_file")
            if [[ -z "$name" ]]; then
                local path
                path=$(jq -r ".projects[$i].path // \"(unknown)\"" "$config_file")
                missing+=("projects[$i] (${path})")
            fi
        done

        if [[ ${#missing[@]} -gt 0 ]]; then
            local joined
            joined=$(IFS=', '; echo "${missing[*]}")
            echo "Each project must have a \"name\" field. Missing in: ${joined}"
            return
        fi
    fi

    # ── Validate resources section ──
    local resources_type
    resources_type=$(jq -r 'if has("resources") then .resources | type else "null" end' "$config_file")
    if [[ "$resources_type" != "null" && "$resources_type" != "object" ]]; then
        echo "\"resources\" must be an object, got: ${resources_type}"
        return
    fi

    if [[ "$resources_type" == "object" ]]; then
        # resources.agents — array of strings
        local agents_type
        agents_type=$(jq -r 'if .resources | has("agents") then .resources.agents | type else "null" end' "$config_file")
        if [[ "$agents_type" != "null" && "$agents_type" != "array" ]]; then
            echo "\"resources.agents\" must be an array, got: ${agents_type}"
            return
        fi
        if [[ "$agents_type" == "array" ]]; then
            local bad_agents
            bad_agents=$(jq -r '.resources.agents | to_entries[] | select((.value | type) != "string") | "resources.agents[\(.key)]: expected string, got \(.value | type)"' "$config_file" 2>/dev/null || true)
            if [[ -n "$bad_agents" ]]; then
                echo "$bad_agents"
                return
            fi
        fi

        # resources.skills — array of strings
        local skills_type
        skills_type=$(jq -r 'if .resources | has("skills") then .resources.skills | type else "null" end' "$config_file")
        if [[ "$skills_type" != "null" && "$skills_type" != "array" ]]; then
            echo "\"resources.skills\" must be an array, got: ${skills_type}"
            return
        fi
        if [[ "$skills_type" == "array" ]]; then
            local bad_skills
            bad_skills=$(jq -r '.resources.skills | to_entries[] | select((.value | type) != "string") | "resources.skills[\(.key)]: expected string, got \(.value | type)"' "$config_file" 2>/dev/null || true)
            if [[ -n "$bad_skills" ]]; then
                echo "$bad_skills"
                return
            fi
        fi

        # resources.mcp — object of objects
        local mcp_type
        mcp_type=$(jq -r 'if .resources | has("mcp") then .resources.mcp | type else "null" end' "$config_file")
        if [[ "$mcp_type" != "null" && "$mcp_type" != "object" ]]; then
            echo "\"resources.mcp\" must be an object, got: ${mcp_type}"
            return
        fi
        if [[ "$mcp_type" == "object" ]]; then
            local bad_mcp
            bad_mcp=$(jq -r '.resources.mcp | to_entries[] | select((.value | type) != "object") | "resources.mcp.\(.key): expected object, got \(.value | type)"' "$config_file" 2>/dev/null || true)
            if [[ -n "$bad_mcp" ]]; then
                echo "$bad_mcp"
                return
            fi
        fi

        # resources.env_files — array of strings
        local env_files_type
        env_files_type=$(jq -r 'if .resources | has("env_files") then .resources.env_files | type else "null" end' "$config_file")
        if [[ "$env_files_type" != "null" && "$env_files_type" != "array" ]]; then
            echo "\"resources.env_files\" must be an array, got: ${env_files_type}"
            return
        fi
        if [[ "$env_files_type" == "array" ]]; then
            local bad_env_files
            bad_env_files=$(jq -r '.resources.env_files | to_entries[] | select((.value | type) != "string") | "resources.env_files[\(.key)]: expected string, got \(.value | type)"' "$config_file" 2>/dev/null || true)
            if [[ -n "$bad_env_files" ]]; then
                echo "$bad_env_files"
                return
            fi
        fi
    fi

    # ── Validate update_interval ──
    local ui_type
    ui_type=$(jq -r 'if has("update_interval") then .update_interval | type else "null" end' "$config_file")
    if [[ "$ui_type" != "null" && "$ui_type" != "number" ]]; then
        echo "\"update_interval\" must be a number (hours), got: ${ui_type}"
        return
    fi
    if [[ "$ui_type" == "number" ]]; then
        local ui_val
        ui_val=$(jq '.update_interval' "$config_file")
        if jq -e '.update_interval < 0' "$config_file" &>/dev/null; then
            echo "\"update_interval\" must be >= 0, got: ${ui_val}"
            return
        fi
    fi

    # ── Validate presets array ──
    local presets_type
    presets_type=$(jq -r 'if has("presets") then .presets | type else "null" end' "$config_file")
    if [[ "$presets_type" != "null" && "$presets_type" != "array" ]]; then
        echo "\"presets\" must be an array, got: ${presets_type}"
        return
    fi
    if [[ "$presets_type" == "array" ]]; then
        local preset_count_v
        preset_count_v=$(jq '.presets | length' "$config_file")
        local i
        for i in $(seq 0 $((preset_count_v - 1))); do
            local entry_type
            entry_type=$(jq -r ".presets[$i] | type" "$config_file")
            case "$entry_type" in
                string)
                    # Local preset name — valid
                    ;;
                object)
                    # GitHub preset object — validate fields
                    local source_val
                    source_val=$(jq -r ".presets[$i].source // empty" "$config_file")
                    if [[ -z "$source_val" ]]; then
                        echo "presets[$i]: object entry must have a \"source\" field"
                        return
                    fi
                    if [[ "$source_val" != github:* ]]; then
                        echo "presets[$i].source must start with \"github:\", got: ${source_val}"
                        return
                    fi
                    # Validate github source has at least owner/repo with safe characters
                    local gh_rest="${source_val#github:}"
                    gh_rest="${gh_rest%%@*}"
                    if [[ "$gh_rest" != */* ]]; then
                        echo "presets[$i].source must contain at least owner/repo, got: ${source_val}"
                        return
                    fi
                    # Validate owner and repo contain only safe characters (no path traversal)
                    local gh_owner="${gh_rest%%/*}"
                    local gh_after="${gh_rest#*/}"
                    local gh_repo="${gh_after%%/*}"
                    if [[ ! "$gh_owner" =~ ^[a-zA-Z0-9._-]+$ ]] || [[ "$gh_owner" == "." ]] || [[ "$gh_owner" == ".." ]]; then
                        echo "presets[$i].source: invalid owner name: ${gh_owner}"
                        return
                    fi
                    if [[ ! "$gh_repo" =~ ^[a-zA-Z0-9._-]+$ ]] || [[ "$gh_repo" == "." ]] || [[ "$gh_repo" == ".." ]]; then
                        echo "presets[$i].source: invalid repo name: ${gh_repo}"
                        return
                    fi
                    # Validate path segments (no path traversal via ..)
                    local gh_path_part="${gh_rest#*/*/}"
                    if [[ "$gh_path_part" != "$gh_rest" && -n "$gh_path_part" ]]; then
                        local IFS='/'
                        local gh_seg
                        for gh_seg in $gh_path_part; do
                            if [[ "$gh_seg" == ".." || "$gh_seg" == "." ]]; then
                                echo "presets[$i].source: path contains invalid segment: ${gh_seg}"
                                return
                            fi
                        done
                        unset IFS
                    fi
                    # Validate prefix format if present
                    local prefix_val
                    prefix_val=$(jq -r ".presets[$i].prefix // empty" "$config_file")
                    if [[ -n "$prefix_val" ]]; then
                        if [[ ! "$prefix_val" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
                            echo "presets[$i].prefix must be lowercase alphanumeric with optional hyphens (no leading/trailing hyphens), got: ${prefix_val}"
                            return
                        fi
                    fi
                    # Validate env_files if present
                    local ef_type
                    ef_type=$(jq -r "if .presets[$i] | has(\"env_files\") then .presets[$i].env_files | type else \"null\" end" "$config_file")
                    if [[ "$ef_type" != "null" && "$ef_type" != "array" ]]; then
                        echo "presets[$i].env_files must be an array, got: ${ef_type}"
                        return
                    fi
                    # Validate rename if present
                    local rename_type
                    rename_type=$(jq -r "if .presets[$i] | has(\"rename\") then .presets[$i].rename | type else \"null\" end" "$config_file")
                    if [[ "$rename_type" != "null" && "$rename_type" != "object" ]]; then
                        echo "presets[$i].rename must be an object, got: ${rename_type}"
                        return
                    fi
                    ;;
                *)
                    echo "presets[$i]: expected string or object, got: ${entry_type}"
                    return
                    ;;
            esac
        done
    fi
}

validate_global_config() {
    [[ ! -f "$GLOBAL_CONFIG" ]] && return

    if ! jq empty "$GLOBAL_CONFIG" 2>/dev/null; then
        echo -e "${RED}Error: Invalid JSON in global config: ${GLOBAL_CONFIG}${NC}" >&2
        jq empty "$GLOBAL_CONFIG" 2>&1 | head -5 >&2
        exit 1
    fi

    local semantic_error
    semantic_error=$(validate_config_semantics "$GLOBAL_CONFIG")
    if [[ -n "$semantic_error" ]]; then
        echo -e "${RED}Global config error (${GLOBAL_CONFIG}): ${semantic_error}${NC}" >&2
        exit 1
    fi
}
