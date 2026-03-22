# ── Validate workspace ──────────────────────────────────────────────
validate() {
    require_jq
    require_claude

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

    [[ "$project_count" -eq 0 ]] && return
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

    # ── Validate resources section ──
    local resources_type
    resources_type=$(jq -r 'if has("resources") then .resources | type else "null" end' "$config_file")
    if [[ "$resources_type" == "null" ]]; then
        return
    fi
    if [[ "$resources_type" != "object" ]]; then
        echo "\"resources\" must be an object, got: ${resources_type}"
        return
    fi

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
