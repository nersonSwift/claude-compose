# ── Validate workspace ──────────────────────────────────────────────
validate() {
    require_jq
    if [[ "$DRY_RUN" != true ]]; then
        require_claude
    fi

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
        if [[ "$DRY_RUN" == true ]]; then
            exit 1
        fi
        echo -e "${YELLOW}Launching Claude to create the config...${NC}" >&2
        local ws_dir
        ws_dir="$(dirname "$CONFIG_FILE")"
        local prompt
        prompt=$(compose_config_prompt "$CONFIG_FILE")
        (cd "$ws_dir" && claude --system-prompt "$prompt" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}")
        exit 0
    fi

    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        local json_err
        json_err=$(jq empty "$CONFIG_FILE" 2>&1 | head -5)
        echo -e "${RED}Error: Invalid JSON in ${CONFIG_FILE}${NC}" >&2
        echo "$json_err" >&2
        die_doctor "Invalid JSON in ${CONFIG_FILE}: ${json_err}"
    fi

    local semantic_error
    semantic_error=$(validate_config_semantics "$CONFIG_FILE")
    if [[ -n "$semantic_error" ]]; then
        echo -e "${RED}Config error: ${semantic_error}${NC}" >&2
        if [[ "$DRY_RUN" == true ]]; then
            exit 1
        fi
        die_doctor "Config validation error: ${semantic_error}"
    fi
}

_validate_projects() {
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
        local missing_name=()
        local missing_path=()
        for ((i = 0; i < project_count; i++)); do
            local name path
            name=$(jq -r ".projects[$i].name // empty" "$config_file")
            path=$(jq -r ".projects[$i].path // empty" "$config_file")
            if [[ -z "$name" ]]; then
                missing_name+=("projects[$i] (${path:-unknown})")
            fi
            if [[ -z "$path" ]]; then
                missing_path+=("projects[$i] (${name:-unknown})")
            fi
        done

        if [[ ${#missing_path[@]} -gt 0 ]]; then
            local joined
            joined=$(IFS=', '; echo "${missing_path[*]}")
            echo "Each project must have a \"path\" field. Missing in: ${joined}"
            return
        fi

        if [[ ${#missing_name[@]} -gt 0 ]]; then
            local joined
            joined=$(IFS=', '; echo "${missing_name[*]}")
            echo "Each project must have a \"name\" field. Missing in: ${joined}"
            return
        fi

        # Check for duplicate project names
        if [[ "$project_count" -gt 1 ]]; then
            local dup_names
            dup_names=$(jq -r '[.projects[].name // empty] | group_by(.) | map(select(length > 1)) | .[0][0] // empty' "$config_file")
            if [[ -n "$dup_names" ]]; then
                echo "Duplicate project name: \"${dup_names}\". Each project must have a unique name."
                return
            fi
        fi
    fi
}

_validate_resources() {
    local config_file="$1"

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

        # resources.append_system_prompt_files — array of strings
        local aspf_type
        aspf_type=$(jq -r 'if .resources | has("append_system_prompt_files") then .resources.append_system_prompt_files | type else "null" end' "$config_file")
        if [[ "$aspf_type" != "null" && "$aspf_type" != "array" ]]; then
            echo "\"resources.append_system_prompt_files\" must be an array, got: ${aspf_type}"
            return
        fi
        if [[ "$aspf_type" == "array" ]]; then
            local bad_aspf
            bad_aspf=$(jq -r '.resources.append_system_prompt_files | to_entries[] | select((.value | type) != "string") | "resources.append_system_prompt_files[\(.key)]: expected string, got \(.value | type)"' "$config_file" 2>/dev/null || true)
            if [[ -n "$bad_aspf" ]]; then
                echo "$bad_aspf"
                return
            fi
        fi

        # resources.settings — string
        local settings_type
        settings_type=$(jq -r 'if .resources | has("settings") then .resources.settings | type else "null" end' "$config_file")
        if [[ "$settings_type" != "null" && "$settings_type" != "string" ]]; then
            echo "\"resources.settings\" must be a string, got: ${settings_type}"
            return
        fi
    fi
}

_validate_update_interval() {
    local config_file="$1"

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
}

_validate_workspaces() {
    local config_file="$1"

    local workspaces_type
    workspaces_type=$(jq -r 'if has("workspaces") then .workspaces | type else "null" end' "$config_file")
    if [[ "$workspaces_type" != "null" && "$workspaces_type" != "array" ]]; then
        echo "\"workspaces\" must be an array, got: ${workspaces_type}"
        return
    fi
    if [[ "$workspaces_type" == "array" ]]; then
        local ws_count_v
        ws_count_v=$(jq '.workspaces | length' "$config_file")
        local wi
        for ((wi = 0; wi < ws_count_v; wi++)); do
            local ws_entry_type
            ws_entry_type=$(jq -r ".workspaces[$wi] | type" "$config_file")
            if [[ "$ws_entry_type" != "object" ]]; then
                echo "workspaces[$wi]: expected object, got: ${ws_entry_type}"
                return
            fi
            local ws_path_val
            ws_path_val=$(jq -r ".workspaces[$wi].path // empty" "$config_file")
            if [[ -z "$ws_path_val" ]]; then
                echo "workspaces[$wi]: must have a \"path\" field"
                return
            fi
            # Validate filter fields if present
            local filter_field
            for filter_field in mcp agents skills; do
                local ff_type
                ff_type=$(jq -r "if .workspaces[$wi] | has(\"$filter_field\") then .workspaces[$wi].$filter_field | type else \"null\" end" "$config_file")
                if [[ "$ff_type" != "null" && "$ff_type" != "object" ]]; then
                    echo "workspaces[$wi].$filter_field must be an object, got: ${ff_type}"
                    return
                fi
            done
        done
    fi
}

_validate_presets() {
    local config_file="$1"

    local presets_type
    presets_type=$(jq -r 'if has("presets") then .presets | type else "null" end' "$config_file")
    if [[ "$presets_type" != "null" && "$presets_type" != "array" ]]; then
        echo "\"presets\" must be an array, got: ${presets_type}"
        return
    fi
    if [[ "$presets_type" == "array" ]]; then
        local preset_count_v
        preset_count_v=$(jq '.presets | length' "$config_file")
        if [[ "$preset_count_v" -gt 0 ]]; then
        local i
        for ((i = 0; i < preset_count_v; i++)); do
            local entry_type
            entry_type=$(jq -r ".presets[$i] | type" "$config_file")
            case "$entry_type" in
                string)
                    # Local preset name or path — validate names, allow paths
                    local str_val
                    str_val=$(jq -r ".presets[$i]" "$config_file")
                    if ! _is_preset_path "$str_val"; then
                        if [[ "$str_val" == *..* || "$str_val" == */* ]]; then
                            echo "presets[$i]: invalid preset name: ${str_val}"
                            return
                        fi
                    fi
                    ;;
                object)
                    # Preset object — validate fields (GitHub source, local name, or path)
                    local source_val name_val path_val
                    source_val=$(jq -r ".presets[$i].source // empty" "$config_file")
                    name_val=$(jq -r ".presets[$i].name // empty" "$config_file")
                    path_val=$(jq -r ".presets[$i].path // empty" "$config_file")

                    local field_count=0
                    [[ -n "$source_val" ]] && ((field_count++)) || true
                    [[ -n "$name_val" ]] && ((field_count++)) || true
                    [[ -n "$path_val" ]] && ((field_count++)) || true

                    if [[ "$field_count" -eq 0 ]]; then
                        echo "presets[$i]: object entry must have \"source\", \"name\", or \"path\" field"
                        return
                    fi
                    if [[ "$field_count" -gt 1 ]]; then
                        echo "presets[$i]: \"source\", \"name\", and \"path\" are mutually exclusive"
                        return
                    fi

                    if [[ -n "$source_val" ]]; then
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
                            local _remaining="$gh_path_part" gh_seg
                            while [[ -n "$_remaining" ]]; do
                                gh_seg="${_remaining%%/*}"
                                if [[ "$gh_seg" == ".." || "$gh_seg" == "." ]]; then
                                    echo "presets[$i].source: path contains invalid segment: ${gh_seg}"
                                    return
                                fi
                                [[ "$_remaining" == */* ]] && _remaining="${_remaining#*/}" || _remaining=""
                            done
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
                    elif [[ -n "$path_val" ]]; then
                        # Path preset — no additional validation needed
                        :
                    elif [[ -n "$name_val" ]]; then
                        if [[ "$name_val" == *..* || "$name_val" == */* ]]; then
                            echo "presets[$i].name: invalid preset name: ${name_val}"
                            return
                        fi
                    fi

                    # Validate filter fields (common to both source and name objects)
                    local filter_type
                    for filter_type in agents skills mcp; do
                        local ft
                        ft=$(jq -r "if .presets[$i] | has(\"$filter_type\") then .presets[$i].${filter_type} | type else \"null\" end" "$config_file")
                        if [[ "$ft" != "null" && "$ft" != "object" ]]; then
                            echo "presets[$i].${filter_type} must be an object, got: ${ft}"
                            return
                        fi
                        if [[ "$ft" == "object" ]]; then
                            local arr_field
                            for arr_field in include exclude; do
                                local af
                                af=$(jq -r "if .presets[$i].${filter_type} | has(\"$arr_field\") then .presets[$i].${filter_type}.${arr_field} | type else \"null\" end" "$config_file")
                                if [[ "$af" != "null" && "$af" != "array" ]]; then
                                    echo "presets[$i].${filter_type}.${arr_field} must be an array, got: ${af}"
                                    return
                                fi
                            done
                        fi
                    done
                    ;;
                *)
                    echo "presets[$i]: expected string or object, got: ${entry_type}"
                    return
                    ;;
            esac
        done
        fi
    fi
}

validate_config_semantics() {
    local config_file="$1"

    # Warn on unknown top-level keys
    local known_keys='["projects","presets","workspaces","resources","update_interval"]'
    local unknown_keys
    unknown_keys=$(jq -r --argjson known "$known_keys" 'keys | map(select(. as $k | $known | index($k) | not)) | .[]' "$config_file" 2>/dev/null || true)
    if [[ -n "$unknown_keys" ]]; then
        while IFS= read -r uk; do
            [[ -z "$uk" ]] && continue
            echo -e "${YELLOW}Warning: unknown config key \"${uk}\" in $(basename "$config_file")${NC}" >&2
        done <<< "$unknown_keys"
    fi

    local err
    err=$(_validate_projects "$config_file"); [[ -n "$err" ]] && { echo "$err"; return; }
    err=$(_validate_resources "$config_file"); [[ -n "$err" ]] && { echo "$err"; return; }
    err=$(_validate_update_interval "$config_file"); [[ -n "$err" ]] && { echo "$err"; return; }
    err=$(_validate_workspaces "$config_file"); [[ -n "$err" ]] && { echo "$err"; return; }
    err=$(_validate_presets "$config_file"); [[ -n "$err" ]] && { echo "$err"; return; }
    return 0
}

validate_global_config() {
    [[ ! -f "$GLOBAL_CONFIG" ]] && return

    if ! jq empty "$GLOBAL_CONFIG" 2>/dev/null; then
        local json_err
        json_err=$(jq empty "$GLOBAL_CONFIG" 2>&1 | head -5)
        echo -e "${RED}Error: Invalid JSON in global config: ${GLOBAL_CONFIG}${NC}" >&2
        echo "$json_err" >&2
        die_doctor "Invalid JSON in global config ${GLOBAL_CONFIG}: ${json_err}"
    fi

    local semantic_error
    semantic_error=$(validate_config_semantics "$GLOBAL_CONFIG")
    if [[ -n "$semantic_error" ]]; then
        echo -e "${RED}Global config error (${GLOBAL_CONFIG}): ${semantic_error}${NC}" >&2
        die_doctor "Global config error: ${semantic_error}"
    fi
}
