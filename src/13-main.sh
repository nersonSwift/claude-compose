# ── Main ─────────────────────────────────────────────────────────────
main() {
    parse_args "$@"

    # Wrap mode: dispatched immediately because parse_args returned early
    # and CONFIG_FILE is not yet resolved to absolute path
    if [[ "$SUBCOMMAND" == "wrap" ]]; then
        cmd_wrap
        return
    fi

    # Ensure built-in skills are extracted
    ensure_builtin_skills

    # Resolve CONFIG_FILE to absolute path (before any cd)
    local config_dir
    config_dir="$(dirname "$CONFIG_FILE")"
    if [[ -d "$config_dir" ]]; then
        CONFIG_FILE="$(cd "$config_dir" && pwd -P)/$(basename "$CONFIG_FILE")"
    fi

    # Set lock file path next to config
    LOCK_FILE="${CONFIG_FILE%.json}.lock.json"

    # Set up doctor traps (must be after parse_args so DOCTOR_ENABLED is correct)
    # ERR trap captures context (command, line, function) for unexpected set -e failures
    trap '_doctor_err_trap' ERR
    trap '_doctor_trap' EXIT

    # Dispatch subcommands before validate (they have own validation)
    case "$SUBCOMMAND" in
        config) cmd_config; return ;;
        build) cmd_build; return ;;
        migrate) cmd_migrate; return ;;
        copy) cmd_copy; return ;;
        instructions) cmd_instructions; return ;;
        update) cmd_update; return ;;
        registries) cmd_registries; return ;;
        doctor) cmd_doctor; return ;;
        start) cmd_start; return ;;
        vscode) cmd_vscode; return ;;
    esac

    validate

    echo -e "${BOLD}claude-compose${NC} v${VERSION}" >&2
    echo -e "Config: ${CONFIG_FILE}" >&2
    if [[ -f "$GLOBAL_CONFIG" ]]; then
        echo -e "Global: ${GLOBAL_CONFIG}" >&2
    fi
    echo "" >&2

    # Read project and preset counts
    local project_count preset_count ws_count has_resources
    project_count=$(jq '.projects // [] | length' "$CONFIG_FILE")
    preset_count=$(jq '.presets // [] | length' "$CONFIG_FILE")
    ws_count=$(jq '.workspaces // [] | length' "$CONFIG_FILE")
    has_resources=$(jq 'has("resources") and (.resources | length > 0)' "$CONFIG_FILE")

    local has_global_config=false
    [[ -f "$GLOBAL_CONFIG" ]] && has_global_config=true

    if [[ "$project_count" -eq 0 && "$preset_count" -eq 0 && "$ws_count" -eq 0 && "$has_resources" != "true" && "$has_global_config" != "true" ]] && ! has_builtin_skills; then
        echo -e "${YELLOW}No projects, presets, workspaces, or resources defined in config. Launching plain claude.${NC}" >&2
        claude "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
        return
    fi

    # Auto-build from presets/workspaces/resources/built-in skills if needed
    if [[ "$DRY_RUN" != true ]]; then
        if [[ "$preset_count" -gt 0 || "$ws_count" -gt 0 || "$has_resources" == "true" || "$has_global_config" == "true" ]] || has_builtin_skills; then
            if needs_rebuild; then
                build "false"
            fi
        fi
    fi

    # Load global env files (no prefix, before local so local wins)
    load_global_env_files
    # Load env files from resources.env_files (local)
    load_env_files
    # Load env files from external sources with prefixed keys
    load_all_source_env_files

    # Collect args using shared helpers (see src/08a-collect.sh)
    _collect_project_args "true"
    _init_system_prompt
    _collect_manifest_args "true"
    _build_settings "true" "false"

    # Extra args
    if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
        CLAUDE_ARGS+=("${EXTRA_ARGS[@]}")
    fi

    echo "" >&2

    # ── Dry run ──
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${BOLD}── Dry Run ──${NC}" >&2
        echo "" >&2

        if [[ "$preset_count" -gt 0 ]]; then
            echo -e "${CYAN}Active presets:${NC}" >&2
            local dri_m
            for ((dri_m = 0; dri_m < preset_count; dri_m++)); do
                local drm_type
                drm_type=$(jq -r ".presets[$dri_m] | type" "$CONFIG_FILE")
                if [[ "$drm_type" == "string" ]]; then
                    local drm_name
                    drm_name=$(jq -r ".presets[$dri_m]" "$CONFIG_FILE")
                    echo "  - $drm_name" >&2
                elif [[ "$drm_type" == "object" ]]; then
                    local drm_source drm_prefix
                    drm_source=$(jq -r ".presets[$dri_m].source // empty" "$CONFIG_FILE")
                    drm_prefix=$(jq -r ".presets[$dri_m].prefix // empty" "$CONFIG_FILE")
                    echo -n "  - ${drm_source}" >&2
                    [[ -n "$drm_prefix" ]] && echo -n " (prefix: ${drm_prefix})" >&2
                    if [[ -n "$LOCK_FILE" && -f "$LOCK_FILE" ]]; then
                        parse_github_source "$drm_source"
                        local drm_sk="github:${_GH_OWNER}/${_GH_REPO}"
                        [[ -n "$_GH_PATH" ]] && drm_sk+="/${_GH_PATH}"
                        local drm_ver
                        drm_ver=$(jq -r --arg k "$drm_sk" '.registries[$k].resolved // empty' "$LOCK_FILE" 2>/dev/null || true)
                        [[ -n "$drm_ver" ]] && echo -n " [v${drm_ver}]" >&2
                    fi
                    echo "" >&2
                fi
            done
            echo "" >&2
        fi

        if [[ "$ws_count" -gt 0 ]]; then
            echo -e "${CYAN}Active workspaces:${NC}" >&2
            local mwi
            for ((mwi = 0; mwi < ws_count; mwi++)); do
                local ws_path
                ws_path=$(jq -r ".workspaces[$mwi].path" "$CONFIG_FILE")
                echo "  - $ws_path" >&2
            done
            echo "" >&2
        fi

        if [[ -f "$GLOBAL_CONFIG" ]]; then
            echo -e "${CYAN}Global config:${NC} ${GLOBAL_CONFIG}" >&2
            echo "" >&2
        fi

        if [[ -f ".compose-manifest.json" ]]; then
            local has_synced_resources=false
            local section
            for section in global presets workspaces resources; do
                local section_keys
                section_keys=$(jq -r --arg s "$section" '.[$s] // {} | keys[]' ".compose-manifest.json" 2>/dev/null || true)
                while IFS= read -r skey; do
                    [[ -z "$skey" ]] && continue
                    has_synced_resources=true
                done <<< "$section_keys"
            done
            if [[ "$has_synced_resources" == true ]]; then
                echo -e "${CYAN}Synced resources (from manifest):${NC}" >&2
                for section in global presets workspaces resources; do
                    jq -r --arg s "$section" '.[$s] // {} | to_entries[] | (
                        (.value.agents // [] | map("  agent: " + .)),
                        (.value.skills // [] | map("  skill: " + .)),
                        (.value.mcp_servers // [] | map("  mcp: " + .)),
                        (.value.add_dirs // [] | map(if type == "object" then "  add_dir: " + .path + (if .claude_md then "" else " (claude_md: false)" end) else "  add_dir: " + . end))
                    ) | .[]' ".compose-manifest.json" 2>/dev/null | while read -r line; do
                        echo "  $line" >&2
                    done
                done
                echo "" >&2
            fi
        fi

        if [[ -n "${_PROJECT_ALIASES:-}" ]]; then
            echo -e "${CYAN}Project aliases (--append-system-prompt):${NC}" >&2
            while IFS= read -r alias_line; do
                [[ -n "$alias_line" ]] && echo "  $alias_line" >&2
            done <<< "${_PROJECT_ALIASES%$'\n'}"
            echo "" >&2
        fi

        # Show env files info
        local env_files_list
        env_files_list=$(jq -r '.resources.env_files // [] | .[]' "$CONFIG_FILE" 2>/dev/null || true)
        if [[ -n "$env_files_list" ]]; then
            echo -e "${CYAN}Env files:${NC}" >&2
            while IFS= read -r ef; do
                [[ -z "$ef" ]] && continue
                local ef_abs="$PWD/$ef"
                if [[ -f "$ef_abs" ]]; then
                    local vc
                    vc=$(jq 'length' "$ef_abs" 2>/dev/null || echo "?")
                    echo "  $ef ($vc vars)" >&2
                else
                    echo "  $ef (not found)" >&2
                fi
            done <<< "$env_files_list"
            echo "" >&2
        fi

        if [[ -f "$GLOBAL_CONFIG" ]]; then
            local global_env_list
            global_env_list=$(jq -r '.resources.env_files // [] | .[]' "$GLOBAL_CONFIG" 2>/dev/null || true)
            if [[ -n "$global_env_list" ]]; then
                echo -e "${CYAN}Global env files:${NC}" >&2
                while IFS= read -r ef; do
                    [[ -z "$ef" ]] && continue
                    local ef_abs="$GLOBAL_CONFIG_DIR/$ef"
                    if [[ -f "$ef_abs" ]]; then
                        local vc
                        vc=$(jq 'length' "$ef_abs" 2>/dev/null || echo "?")
                        echo "  $ef ($vc vars)" >&2
                    else
                        echo "  $ef (not found)" >&2
                    fi
                done <<< "$global_env_list"
                echo "" >&2
            fi
        fi

        if [[ "$HAS_ANY_ADD_DIR" == true ]]; then
            echo -e "${CYAN}Environment:${NC}" >&2
            echo "  CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1" >&2
            echo "" >&2
        fi

        if [[ "$_COMPOSE_SETTINGS" != '{}' ]]; then
            echo -e "${CYAN}Settings (--settings .compose-settings.json):${NC}" >&2
            echo "$_COMPOSE_SETTINGS" | jq '.' >&2
            echo "" >&2
        fi

        echo -e "${CYAN}Directories (--add-dir):${NC}" >&2
        for ((arg_idx = 0; arg_idx < ${#CLAUDE_ARGS[@]}; arg_idx++)); do
            if [[ "${CLAUDE_ARGS[$arg_idx]}" == "--add-dir" && "$arg_idx" -lt $((${#CLAUDE_ARGS[@]} - 1)) ]]; then
                local dir_val="${CLAUDE_ARGS[$((arg_idx + 1))]}"
                echo "  - $dir_val" >&2
            fi
        done
        echo "" >&2

        # Show workspace config files
        echo -e "${CYAN}Workspace files:${NC}" >&2
        [[ -f ".mcp.json" ]] && echo "  .mcp.json ($(jq '.mcpServers | length' .mcp.json 2>/dev/null || echo 0) servers)" >&2
        [[ -d ".claude/agents" ]] && echo "  .claude/agents/ ($(find .claude/agents -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ') agents)" >&2
        [[ -d ".claude/skills" ]] && echo "  .claude/skills/ ($(find .claude/skills -maxdepth 1 -mindepth 1 \( -type d -o -type l \) 2>/dev/null | wc -l | tr -d ' ') skills)" >&2
        [[ -f ".claude/settings.local.json" ]] && echo "  .claude/settings.local.json" >&2
        [[ -f "CLAUDE.md" ]] && echo "  CLAUDE.md" >&2
        echo "" >&2

        echo -e "${GREEN}No mutations performed (dry run).${NC}" >&2
        return
    fi

    # ── Launch ──
    echo -e "${BOLD}Launching claude...${NC}" >&2
    echo "" >&2

    if [[ "$HAS_ANY_ADD_DIR" == true ]]; then
        export CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1
    fi

    claude "${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"}"
}

main "$@"
