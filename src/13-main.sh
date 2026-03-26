# ── Main ─────────────────────────────────────────────────────────────
main() {
    parse_args "$@"

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

    if [[ "$project_count" -eq 0 && "$preset_count" -eq 0 && "$ws_count" -eq 0 && "$has_resources" != "true" && "$has_global_config" != "true" ]]; then
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

    # Collect --add-dir args from projects
    local project_aliases=""
    if [[ "$project_count" -gt 0 ]]; then
        local mpi
        for ((mpi = 0; mpi < project_count; mpi++)); do
            local raw_path project_path claude_md project_name
            raw_path=$(jq -r ".projects[$mpi].path" "$CONFIG_FILE")
            project_path=$(expand_path "$raw_path")
            claude_md=$(jq -r ".projects[$mpi].claude_md // true" "$CONFIG_FILE")
            project_name=$(jq -r ".projects[$mpi].name // empty" "$CONFIG_FILE")

            if [[ ! -d "$project_path" ]]; then
                echo -e "${YELLOW}Warning: Project path not found, skipping: ${raw_path}${NC}" >&2
                continue
            fi

            CLAUDE_ARGS+=("--add-dir" "$project_path")
            echo -e "${CYAN}Project:${NC} $(basename "$project_path") (${project_path})" >&2

            HAS_ANY_ADD_DIR=true
            if [[ "$claude_md" != "true" ]]; then
                COMPOSE_CLAUDE_MD_EXCLUDES+=("$project_path")
            fi

            if [[ -n "$project_name" ]]; then
                project_aliases+="- ${project_name}: ${project_path}"$'\n'
            fi
        done
    fi

    # Build system prompt — always injected when compose is active
    local system_prompt
    system_prompt=$(compose_system_prompt)

    if [[ -n "$project_aliases" ]]; then
        system_prompt+=$'\n'"Projects in this workspace:"$'\n'"${project_aliases%$'\n'}"
        system_prompt+=$'\n'"Use name:// to reference files in a project (e.g. project://path/to/file)."
    fi

    # Settings accumulator (preset/workspace settings merged first, then global/local)
    local compose_settings='{}'

    # Add --add-dir from manifest (global + presets + workspaces + resources: add_dirs and project_dirs)
    if [[ -f ".compose-manifest.json" ]]; then
        local section
        for section in global presets workspaces resources; do
            local source_names
            source_names=$(jq -r --arg s "$section" '.[$s] // {} | keys[]' ".compose-manifest.json" 2>/dev/null || true)
            while IFS= read -r sname; do
                [[ -z "$sname" ]] && continue

                # add_dirs: new format is [{path, claude_md}], old format was ["path"]
                local add_dir_entries
                add_dir_entries=$(jq -c --arg s "$section" --arg n "$sname" '.[$s][$n].add_dirs // [] | .[]' ".compose-manifest.json" 2>/dev/null || true)
                while IFS= read -r entry; do
                    [[ -z "$entry" ]] && continue
                    local dir cm_flag
                    if echo "$entry" | jq -e '.path' >/dev/null 2>&1; then
                        # New object format
                        dir=$(echo "$entry" | jq -r '.path')
                        cm_flag=$(echo "$entry" | jq -r '.claude_md // true')
                    else
                        # Old string format (backward compat)
                        dir=$(echo "$entry" | jq -r '.')
                        cm_flag="true"
                    fi
                    [[ -z "$dir" || ! -d "$dir" ]] && continue
                    CLAUDE_ARGS+=("--add-dir" "$dir")
                    HAS_ANY_ADD_DIR=true
                    if [[ "$cm_flag" != "true" ]]; then
                        COMPOSE_CLAUDE_MD_EXCLUDES+=("$dir")
                    fi
                done <<< "$add_dir_entries"

                # project_dirs: transitive projects
                local proj_dirs
                proj_dirs=$(jq -c --arg s "$section" --arg n "$sname" '.[$s][$n].project_dirs // [] | .[]' ".compose-manifest.json" 2>/dev/null || true)
                while IFS= read -r proj_entry; do
                    [[ -z "$proj_entry" ]] && continue
                    local proj_path proj_cmd
                    proj_path=$(echo "$proj_entry" | jq -r '.path')
                    proj_cmd=$(echo "$proj_entry" | jq -r '.claude_md')
                    if [[ -d "$proj_path" ]]; then
                        CLAUDE_ARGS+=("--add-dir" "$proj_path")
                        HAS_ANY_ADD_DIR=true
                        if [[ "$proj_cmd" != "true" ]]; then
                            COMPOSE_CLAUDE_MD_EXCLUDES+=("$proj_path")
                        fi
                    fi
                done <<< "$proj_dirs"

                # system_prompt_files from manifest (presets/workspaces only)
                local spf_list
                spf_list=$(jq -r --arg s "$section" --arg n "$sname" '.[$s][$n].system_prompt_files // [] | .[]' ".compose-manifest.json" 2>/dev/null || true)
                while IFS= read -r spf; do
                    [[ -z "$spf" || ! -f "$spf" ]] && continue
                    system_prompt+=$'\n\n'"$(cat "$spf")"
                done <<< "$spf_list"

                # settings_files from manifest (presets/workspaces only)
                local sf_list
                sf_list=$(jq -r --arg s "$section" --arg n "$sname" '.[$s][$n].settings_files // [] | .[]' ".compose-manifest.json" 2>/dev/null || true)
                while IFS= read -r sf; do
                    [[ -z "$sf" || ! -f "$sf" ]] && continue
                    if jq empty "$sf" 2>/dev/null; then
                        compose_settings=$(merge_compose_settings "$compose_settings" "$(cat "$sf")")
                    fi
                done <<< "$sf_list"
            done <<< "$source_names"
        done
    fi

    # Append contents from resources.append_system_prompt_files (global first, then local)
    if [[ -f "$GLOBAL_CONFIG" ]]; then
        local global_aspf
        global_aspf=$(jq -r '.resources.append_system_prompt_files // [] | .[]' "$GLOBAL_CONFIG" 2>/dev/null || true)
        while IFS= read -r aspf; do
            [[ -z "$aspf" ]] && continue
            local abs_aspf="$GLOBAL_CONFIG_DIR/$aspf"
            if [[ -f "$abs_aspf" ]]; then
                system_prompt+=$'\n\n'"$(cat "$abs_aspf")"
            else
                echo -e "${YELLOW}Warning: global system prompt file not found: ${aspf}${NC}" >&2
            fi
        done <<< "$global_aspf"
    fi

    local local_aspf
    local_aspf=$(jq -r '.resources.append_system_prompt_files // [] | .[]' "$CONFIG_FILE" 2>/dev/null || true)
    while IFS= read -r aspf; do
        [[ -z "$aspf" ]] && continue
        local abs_aspf="$ORIGINAL_CWD/$aspf"
        if [[ -f "$abs_aspf" ]]; then
            system_prompt+=$'\n\n'"$(cat "$abs_aspf")"
        else
            echo -e "${YELLOW}Warning: system prompt file not found: ${aspf}${NC}" >&2
        fi
    done <<< "$local_aspf"

    CLAUDE_ARGS+=("--append-system-prompt" "$system_prompt")

    # Build claudeMdExcludes from collected paths
    if [[ ${#COMPOSE_CLAUDE_MD_EXCLUDES[@]} -gt 0 ]]; then
        local excludes_json="[]"
        for exc_path in "${COMPOSE_CLAUDE_MD_EXCLUDES[@]}"; do
            excludes_json=$(echo "$excludes_json" | jq --arg p "$exc_path" '. + [$p + "/CLAUDE.md", $p + "/.claude/CLAUDE.md", $p + "/.claude/rules/*.md"]')
        done
        compose_settings=$(echo "$compose_settings" | jq --argjson exc "$excludes_json" '.claudeMdExcludes = $exc')
    fi

    # Merge with user settings (global → local → compose-generated)
    if [[ -f "$GLOBAL_CONFIG" ]]; then
        local global_sp
        global_sp=$(jq -r '.resources.settings // empty' "$GLOBAL_CONFIG" 2>/dev/null || true)
        if [[ -n "$global_sp" ]]; then
            local abs_gs="$GLOBAL_CONFIG_DIR/$global_sp"
            if [[ -f "$abs_gs" ]] && jq empty "$abs_gs" 2>/dev/null; then
                compose_settings=$(merge_compose_settings "$compose_settings" "$(cat "$abs_gs")")
            else
                echo -e "${YELLOW}Warning: global settings file not found or invalid: ${global_sp}${NC}" >&2
            fi
        fi
    fi

    local local_sp
    local_sp=$(jq -r '.resources.settings // empty' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ -n "$local_sp" ]]; then
        local abs_ls="$ORIGINAL_CWD/$local_sp"
        if [[ -f "$abs_ls" ]] && jq empty "$abs_ls" 2>/dev/null; then
            compose_settings=$(merge_compose_settings "$compose_settings" "$(cat "$abs_ls")")
        else
            echo -e "${YELLOW}Warning: settings file not found or invalid: ${local_sp}${NC}" >&2
        fi
    fi

    # Write and pass --settings if non-empty
    if [[ "$compose_settings" != '{}' ]]; then
        if [[ "$DRY_RUN" != true ]]; then
            atomic_write ".compose-settings.json" "$(echo "$compose_settings" | jq '.')"
        fi
        CLAUDE_ARGS+=("--settings" ".compose-settings.json")
    else
        # Clean up stale file if no longer needed
        rm -f ".compose-settings.json" 2>/dev/null || true
    fi

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

        if [[ -n "${project_aliases:-}" ]]; then
            echo -e "${CYAN}Project aliases (--append-system-prompt):${NC}" >&2
            while IFS= read -r alias_line; do
                [[ -n "$alias_line" ]] && echo "  $alias_line" >&2
            done <<< "${project_aliases%$'\n'}"
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

        if [[ "$compose_settings" != '{}' ]]; then
            echo -e "${CYAN}Settings (--settings .compose-settings.json):${NC}" >&2
            echo "$compose_settings" | jq '.' >&2
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
