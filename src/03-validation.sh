# ── Validate workspace ──────────────────────────────────────────────
validate() {
    require_jq
    if [[ "$DRY_RUN" != true ]]; then
        require_claude
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
            printf -v joined '%s, ' "${missing_path[@]}"; joined="${joined%, }"
            echo "Each project must have a \"path\" field. Missing in: ${joined}"
            return
        fi

        if [[ ${#missing_name[@]} -gt 0 ]]; then
            local joined
            printf -v joined '%s, ' "${missing_name[@]}"; joined="${joined%, }"
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

# Validate a resources sub-field is an array of strings
# $1 = config file, $2 = field name under resources
_validate_string_array() {
    local config_file="$1" field="$2"
    local field_type
    field_type=$(jq -r --arg f "$field" 'if .resources | has($f) then .resources[$f] | type else "null" end' "$config_file")
    if [[ "$field_type" != "null" && "$field_type" != "array" ]]; then
        echo "\"resources.${field}\" must be an array, got: ${field_type}"; return
    fi
    if [[ "$field_type" == "array" ]]; then
        local bad
        bad=$(jq -r --arg f "$field" '.resources[$f] | to_entries[] | select((.value | type) != "string") | "resources.\($f)[\(.key)]: expected string, got \(.value | type)"' "$config_file" 2>/dev/null || true)
        [[ -n "$bad" ]] && { echo "$bad"; return; }
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
        local err
        err=$(_validate_string_array "$config_file" "agents"); [[ -n "$err" ]] && { echo "$err"; return; }
        err=$(_validate_string_array "$config_file" "skills"); [[ -n "$err" ]] && { echo "$err"; return; }

        # resources.mcp — object of objects (special case, not string array)
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

        err=$(_validate_string_array "$config_file" "env_files"); [[ -n "$err" ]] && { echo "$err"; return; }
        err=$(_validate_string_array "$config_file" "append_system_prompt_files"); [[ -n "$err" ]] && { echo "$err"; return; }

        # resources.settings — string
        local settings_type
        settings_type=$(jq -r 'if .resources | has("settings") then .resources.settings | type else "null" end' "$config_file")
        if [[ "$settings_type" != "null" && "$settings_type" != "string" ]]; then
            echo "\"resources.settings\" must be a string, got: ${settings_type}"
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
            for filter_field in mcp agents skills plugins; do
                local ff_type
                ff_type=$(jq -r "if .workspaces[$wi] | has(\"$filter_field\") then .workspaces[$wi].$filter_field | type else \"null\" end" "$config_file")
                if [[ "$ff_type" != "null" && "$ff_type" != "object" ]]; then
                    echo "workspaces[$wi].$filter_field must be an object, got: ${ff_type}"
                    return
                fi
            done
            # Validate claude_md_overrides if present
            local cmo_type
            cmo_type=$(jq -r "if .workspaces[$wi] | has(\"claude_md_overrides\") then .workspaces[$wi].claude_md_overrides | type else \"null\" end" "$config_file")
            if [[ "$cmo_type" != "null" && "$cmo_type" != "object" ]]; then
                echo "workspaces[$wi].claude_md_overrides must be an object, got: ${cmo_type}"
                return
            fi
            if [[ "$cmo_type" == "object" ]]; then
                local bad_cmo
                bad_cmo=$(jq -r ".workspaces[$wi].claude_md_overrides | to_entries[] | select((.value | type) != \"boolean\") | \"workspaces[$wi].claude_md_overrides.\(.key): expected boolean, got \(.value | type)\"" "$config_file" 2>/dev/null | head -1)
                if [[ -n "$bad_cmo" ]]; then
                    echo "$bad_cmo"
                    return
                fi
            fi
        done
    fi
}

_validate_workspace_path() {
    local config_file="$1"
    local wp_type
    wp_type=$(jq -r 'if has("workspace_path") then .workspace_path | type else "null" end' "$config_file")
    if [[ "$wp_type" != "null" && "$wp_type" != "string" ]]; then
        echo "\"workspace_path\" must be a string, got: ${wp_type}"
        return
    fi
    if [[ "$wp_type" == "string" ]]; then
        local wp_val
        wp_val=$(jq -r '.workspace_path' "$config_file")
        if [[ -z "$wp_val" ]]; then
            echo "\"workspace_path\" must not be empty"
            return
        fi
    fi
}

_validate_plugins() {
    local config_file="$1"
    local plugins_type
    plugins_type=$(jq -r 'if has("plugins") then .plugins | type else "null" end' "$config_file")
    [[ "$plugins_type" == "null" ]] && return
    if [[ "$plugins_type" != "array" ]]; then
        echo "\"plugins\" must be an array, got: ${plugins_type}"
        return
    fi
    local plugin_count
    plugin_count=$(jq '.plugins | length' "$config_file")
    local pi
    for ((pi = 0; pi < plugin_count; pi++)); do
        local entry_type
        entry_type=$(jq -r ".plugins[$pi] | type" "$config_file")
        case "$entry_type" in
            string)
                local str_val
                str_val=$(jq -r ".plugins[$pi]" "$config_file")
                if [[ -z "$str_val" ]]; then
                    echo "plugins[$pi]: empty string"
                    return
                fi
                # Local path (./,~/,/) or marketplace name (alphanumeric + hyphens + optional @marketplace)
                if [[ "$str_val" != ./* && "$str_val" != ~* && "$str_val" != /* ]]; then
                    # Marketplace name: validate format
                    if [[ ! "$str_val" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?(@[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?)?$ ]]; then
                        echo "plugins[$pi]: invalid marketplace plugin name: ${str_val}"
                        return
                    fi
                fi
                ;;
            object)
                local p_path p_name
                p_path=$(jq -r ".plugins[$pi].path // empty" "$config_file")
                p_name=$(jq -r ".plugins[$pi].name // empty" "$config_file")
                if [[ -z "$p_path" && -z "$p_name" ]]; then
                    echo "plugins[$pi]: object entry must have \"name\" or \"path\" field"
                    return
                fi
                if [[ -n "$p_path" && -n "$p_name" ]]; then
                    echo "plugins[$pi]: \"name\" and \"path\" are mutually exclusive"
                    return
                fi
                if [[ -n "$p_name" ]]; then
                    # Validate marketplace name format
                    if [[ ! "$p_name" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?(@[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?)?$ ]]; then
                        echo "plugins[$pi].name: invalid marketplace plugin name: ${p_name}"
                        return
                    fi
                fi
                # Validate config field if present
                local config_type
                config_type=$(jq -r "if .plugins[$pi] | has(\"config\") then .plugins[$pi].config | type else \"null\" end" "$config_file")
                if [[ "$config_type" != "null" && "$config_type" != "object" ]]; then
                    echo "plugins[$pi].config must be an object, got: ${config_type}"
                    return
                fi
                if [[ "$config_type" == "object" ]]; then
                    # All config values must be strings
                    local bad_config
                    bad_config=$(jq -r ".plugins[$pi].config | to_entries[] | select((.value | type) != \"string\") | \"plugins[$pi].config.\(.key): expected string, got \(.value | type)\"" "$config_file" 2>/dev/null || true)
                    if [[ -n "$bad_config" ]]; then
                        echo "$bad_config"
                        return
                    fi
                fi
                # Only allow valid keys: name, path, config
                local unknown_plugin_keys
                unknown_plugin_keys=$(jq -r ".plugins[$pi] | keys | map(select(. != \"name\" and . != \"path\" and . != \"config\")) | .[]" "$config_file" 2>/dev/null || true)
                if [[ -n "$unknown_plugin_keys" ]]; then
                    local first_uk
                    first_uk=$(echo "$unknown_plugin_keys" | head -1)
                    echo "plugins[$pi]: unknown key \"${first_uk}\". Allowed keys: name, path, config"
                    return
                fi
                ;;
            *)
                echo "plugins[$pi]: expected string or object, got: ${entry_type}"
                return
                ;;
        esac
    done
}

_validate_marketplaces() {
    local config_file="$1"
    local mkts_type
    mkts_type=$(jq -r 'if has("marketplaces") then .marketplaces | type else "null" end' "$config_file")
    [[ "$mkts_type" == "null" ]] && return
    if [[ "$mkts_type" != "object" ]]; then
        echo "\"marketplaces\" must be an object, got: ${mkts_type}"
        return
    fi
    local mkt_keys
    mkt_keys=$(jq -r '.marketplaces | keys[]' "$config_file" 2>/dev/null || true)
    while IFS= read -r mkt_name; do
        [[ -z "$mkt_name" ]] && continue
        local mkt_type
        mkt_type=$(jq -r --arg n "$mkt_name" '.marketplaces[$n] | type' "$config_file")
        if [[ "$mkt_type" != "object" ]]; then
            echo "marketplaces.${mkt_name}: must be an object, got: ${mkt_type}"
            return
        fi
        local mkt_source
        mkt_source=$(jq -r --arg n "$mkt_name" '.marketplaces[$n].source // empty' "$config_file")
        if [[ -z "$mkt_source" ]]; then
            echo "marketplaces.${mkt_name}: must have a \"source\" field"
            return
        fi
        local mkt_repo
        mkt_repo=$(jq -r --arg n "$mkt_name" '.marketplaces[$n].repo // empty' "$config_file")
        if [[ -z "$mkt_repo" ]]; then
            echo "marketplaces.${mkt_name}: must have a \"repo\" field"
            return
        fi
    done <<< "$mkt_keys"
}

_validate_name() {
    local config_file="$1"
    local name
    name=$(jq -r '.name // empty' "$config_file")
    if [[ -z "$name" ]]; then
        echo "Required field \"name\" is missing. Example: \"name\": \"my-project\""
        return
    fi
    local name_type
    name_type=$(jq -r '.name | type' "$config_file")
    if [[ "$name_type" != "string" ]]; then
        echo "\"name\" must be a string, got: ${name_type}"
        return
    fi
    # Validate filesystem-safe characters (no spaces)
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        echo "\"name\" contains invalid characters. Use: letters, digits, dots, hyphens, underscores. Must start with letter or digit."
        return
    fi
}

validate_config_semantics() {
    local config_file="$1"
    local is_global="${2:-false}"

    # Warn on unknown top-level keys
    local known_keys='["name","projects","workspaces","resources","plugins","marketplaces","workspace_path"]'
    local unknown_keys
    unknown_keys=$(jq -r --argjson known "$known_keys" 'keys | map(select(. as $k | $known | index($k) | not)) | .[]' "$config_file" 2>/dev/null || true)
    if [[ -n "$unknown_keys" ]]; then
        while IFS= read -r uk; do
            [[ -z "$uk" ]] && continue
            warn_info "config" "Unknown config key \"${uk}\" in $(basename "$config_file")"
        done <<< "$unknown_keys"
    fi

    local err
    # name is required only for workspace configs, not global
    if [[ "$is_global" != "true" ]]; then
        err=$(_validate_name "$config_file"); [[ -n "$err" ]] && { echo "$err"; return; }
    fi
    err=$(_validate_projects "$config_file"); [[ -n "$err" ]] && { echo "$err"; return; }
    err=$(_validate_resources "$config_file"); [[ -n "$err" ]] && { echo "$err"; return; }
    err=$(_validate_workspace_path "$config_file"); [[ -n "$err" ]] && { echo "$err"; return; }
    err=$(_validate_workspaces "$config_file"); [[ -n "$err" ]] && { echo "$err"; return; }
    err=$(_validate_plugins "$config_file"); [[ -n "$err" ]] && { echo "$err"; return; }
    err=$(_validate_marketplaces "$config_file"); [[ -n "$err" ]] && { echo "$err"; return; }
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
    semantic_error=$(validate_config_semantics "$GLOBAL_CONFIG" "true")
    if [[ -n "$semantic_error" ]]; then
        echo -e "${RED}Global config error (${GLOBAL_CONFIG}): ${semantic_error}${NC}" >&2
        die_doctor "Global config error: ${semantic_error}"
    fi
}
