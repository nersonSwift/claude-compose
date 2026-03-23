# ── Main ─────────────────────────────────────────────────────────────
main() {
    parse_args "$@"

    # Ensure built-in skills are extracted
    ensure_builtin_skills

    # Resolve CONFIG_FILE to absolute path (before any cd)
    local config_dir
    config_dir="$(dirname "$CONFIG_FILE")"
    if [[ -d "$config_dir" ]]; then
        CONFIG_FILE="$(cd "$config_dir" && pwd)/$(basename "$CONFIG_FILE")"
    fi

    # Set lock file path next to config
    LOCK_FILE="${CONFIG_FILE%.json}.lock.json"

    # Dispatch subcommands before validate (they have own validation)
    case "$SUBCOMMAND" in
        config) cmd_config; return ;;
        build) cmd_build; return ;;
        migrate) cmd_migrate; return ;;
        copy) cmd_copy; return ;;
        instructions) cmd_instructions; return ;;
        update) cmd_update; return ;;
        registries) cmd_registries; return ;;
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
    local has_builtin_skills=false
    if [[ -d "$BUILTIN_SKILLS_DIR" ]]; then
        for _d in "$BUILTIN_SKILLS_DIR"/*/; do
            [[ -d "$_d" ]] && has_builtin_skills=true && break
        done
    fi

    if [[ "$preset_count" -gt 0 || "$ws_count" -gt 0 || "$has_resources" == "true" || "$has_builtin_skills" == "true" || "$has_global_config" == "true" ]]; then
        if needs_rebuild; then
            build "false"
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
        for i in $(seq 0 $((project_count - 1))); do
            local raw_path project_path claude_md project_name
            raw_path=$(jq -r ".projects[$i].path" "$CONFIG_FILE")
            project_path=$(expand_path "$raw_path")
            claude_md=$(jq -r ".projects[$i].claude_md // true" "$CONFIG_FILE")
            project_name=$(jq -r ".projects[$i].name // empty" "$CONFIG_FILE")

            if [[ ! -d "$project_path" ]]; then
                echo -e "${YELLOW}Warning: Project path not found, skipping: ${raw_path}${NC}" >&2
                continue
            fi

            CLAUDE_ARGS+=("--add-dir" "$project_path")
            echo -e "${CYAN}Project:${NC} $(basename "$project_path") (${project_path})" >&2

            if [[ "$claude_md" == "true" ]]; then
                NEED_CLAUDE_MD_ENV=true
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

    CLAUDE_ARGS+=("--append-system-prompt" "$system_prompt")

    # Add --add-dir from manifest (global + presets + workspaces + resources: add_dirs and project_dirs)
    if [[ -f ".compose-manifest.json" ]]; then
        local section
        for section in global presets workspaces resources; do
            local source_names
            source_names=$(jq -r --arg s "$section" '.[$s] // {} | keys[]' ".compose-manifest.json" 2>/dev/null || true)
            while IFS= read -r sname; do
                [[ -z "$sname" ]] && continue

                # add_dirs: preset/workspace dirs for CLAUDE.md
                local add_dirs
                add_dirs=$(jq -r --arg s "$section" --arg n "$sname" '.[$s][$n].add_dirs // [] | .[]' ".compose-manifest.json" 2>/dev/null || true)
                while IFS= read -r dir; do
                    [[ -z "$dir" ]] && continue
                    CLAUDE_ARGS+=("--add-dir" "$dir")
                    NEED_CLAUDE_MD_ENV=true
                done <<< "$add_dirs"

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
                        if [[ "$proj_cmd" == "true" ]]; then
                            NEED_CLAUDE_MD_ENV=true
                        fi
                    fi
                done <<< "$proj_dirs"
            done <<< "$source_names"
        done
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
            for dri_m in $(seq 0 $((preset_count - 1))); do
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
            for i in $(seq 0 $((ws_count - 1))); do
                local ws_path
                ws_path=$(jq -r ".workspaces[$i].path" "$CONFIG_FILE")
                echo "  - $ws_path" >&2
            done
            echo "" >&2
        fi

        if [[ -f "$GLOBAL_CONFIG" ]]; then
            echo -e "${CYAN}Global config:${NC} ${GLOBAL_CONFIG}" >&2
            echo "" >&2
        fi

        if [[ -f ".compose-manifest.json" ]]; then
            local has_resources=false
            local section
            for section in global presets workspaces resources; do
                local section_keys
                section_keys=$(jq -r --arg s "$section" '.[$s] // {} | keys[]' ".compose-manifest.json" 2>/dev/null || true)
                while IFS= read -r skey; do
                    [[ -z "$skey" ]] && continue
                    has_resources=true
                done <<< "$section_keys"
            done
            if [[ "$has_resources" == true ]]; then
                echo -e "${CYAN}Synced resources (from manifest):${NC}" >&2
                for section in global presets workspaces resources; do
                    jq -r --arg s "$section" '.[$s] // {} | to_entries[] | (
                        (.value.agents // [] | map("  agent: " + .)),
                        (.value.skills // [] | map("  skill: " + .)),
                        (.value.mcp_servers // [] | map("  mcp: " + .)),
                        (.value.add_dirs // [] | map("  add_dir: " + .))
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

        if [[ "$NEED_CLAUDE_MD_ENV" == true ]]; then
            echo -e "${CYAN}Environment:${NC}" >&2
            echo "  CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1" >&2
            echo "" >&2
        fi

        echo -e "${CYAN}Directories (--add-dir):${NC}" >&2
        for arg_idx in $(seq 0 $((${#CLAUDE_ARGS[@]} - 1))); do
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

    if [[ "$NEED_CLAUDE_MD_ENV" == true ]]; then
        export CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1
    fi

    claude "${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"}"
}

main "$@"
