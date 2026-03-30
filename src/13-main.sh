# ── Main ─────────────────────────────────────────────────────────────
main() {
    parse_args "$@"

    # Wrap mode: dispatched immediately because parse_args returned early
    # and CONFIG_FILE is not yet resolved to absolute path
    if [[ "$SUBCOMMAND" == "wrap" ]]; then
        cmd_wrap
        return
    fi

    # Ensure built-in plugin is extracted
    ensure_builtin_plugin

    # Resolve CONFIG_FILE to absolute path (before any cd)
    local config_dir
    config_dir="$(dirname "$CONFIG_FILE")"
    if [[ -d "$config_dir" ]]; then
        CONFIG_FILE="$(cd "$config_dir" && pwd -P)/$(basename "$CONFIG_FILE")"
    fi

    # Resolve workspace directory (sets CONFIG_DIR, WORKSPACE_DIR, cd to WORKSPACE_DIR)
    _resolve_workspace_dir

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
        doctor) cmd_doctor; return ;;
        start) cmd_start; return ;;
        ide) cmd_ide; return ;;
    esac

    validate

    echo -e "${BOLD}claude-compose${NC} v${VERSION}" >&2
    echo -e "Config: ${CONFIG_FILE}" >&2
    if [[ -f "$GLOBAL_CONFIG" ]]; then
        echo -e "Global: ${GLOBAL_CONFIG}" >&2
    fi
    echo "" >&2

    local project_count
    project_count=$(jq '.projects // [] | length' "$CONFIG_FILE")

    if [[ "$project_count" -eq 0 ]] && ! _has_anything_to_build; then
        echo -e "${YELLOW}No projects, workspaces, or resources defined in config. Launching plain claude.${NC}" >&2
        claude "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
        return
    fi

    # Auto-build if needed
    if [[ "$DRY_RUN" != true ]] && _has_anything_to_build && needs_rebuild; then
        build "false"
    fi

    # Clear build-phase warnings (already reported by build)
    _WARNINGS_CRITICAL=()
    _WARNINGS_INFO=()

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

    # --mcp-config (compose uses $COMPOSE_MCP which Claude won't auto-discover)
    if [[ -f "$COMPOSE_MCP" ]]; then
        CLAUDE_ARGS+=("--mcp-config" "$COMPOSE_MCP")
    fi

    # Collect plugin dirs
    _collect_plugin_args "true" "$CONFIG_DIR"

    # Check for warnings from arg collection phase
    _check_warnings_and_report

    # Extra args
    if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
        CLAUDE_ARGS+=("${EXTRA_ARGS[@]}")
    fi

    echo "" >&2

    # ── Dry run ──
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${BOLD}── Dry Run ──${NC}" >&2
        echo "" >&2

        local ws_count
        ws_count=$(jq '.workspaces // [] | length' "$CONFIG_FILE")
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

        if [[ -f "$COMPOSE_MANIFEST" ]]; then
            local has_synced_resources=false
            local section
            for section in global workspaces resources; do
                local section_keys
                section_keys=$(jq -r --arg s "$section" '.[$s] // {} | keys[]' "$COMPOSE_MANIFEST" 2>/dev/null || true)
                while IFS= read -r skey; do
                    [[ -z "$skey" ]] && continue
                    has_synced_resources=true
                done <<< "$section_keys"
            done
            if [[ "$has_synced_resources" == true ]]; then
                echo -e "${CYAN}Synced resources (from manifest):${NC}" >&2
                for section in global workspaces resources; do
                    jq -r --arg s "$section" '.[$s] // {} | to_entries[] | (
                        (.value.agents // [] | map("  agent: " + .)),
                        (.value.skills // [] | map("  skill: " + .)),
                        (.value.mcp_servers // [] | map("  mcp: " + .)),
                        (.value.add_dirs // [] | map(if type == "object" then "  add_dir: " + .path + (if .claude_md then "" else " (claude_md: false)" end) else "  add_dir: " + . end))
                    ) | .[]' "$COMPOSE_MANIFEST" 2>/dev/null | while read -r line; do
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
                local ef_abs="$CONFIG_DIR/$ef"
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
            echo -e "${CYAN}Settings (--settings ${COMPOSE_SETTINGS}):${NC}" >&2
            jq '.' >&2 <<< "$_COMPOSE_SETTINGS"
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
        [[ -f "$COMPOSE_MCP" ]] && echo "  ${COMPOSE_MCP} ($(jq '.mcpServers | length' "$COMPOSE_MCP" 2>/dev/null || echo 0) servers)" >&2
        [[ -d ".claude/agents" ]] && echo "  .claude/agents/ ($(find .claude/agents -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ') agents)" >&2
        [[ -d ".claude/skills" ]] && echo "  .claude/skills/ ($(find .claude/skills -maxdepth 1 -mindepth 1 \( -type d -o -type l \) 2>/dev/null | wc -l | tr -d ' ') skills)" >&2
        [[ -f ".claude/settings.local.json" ]] && echo "  .claude/settings.local.json" >&2
        [[ -f "CLAUDE.md" ]] && echo "  CLAUDE.md" >&2
        echo "" >&2

        if [[ ${#PLUGIN_DIRS[@]} -gt 0 ]]; then
            echo -e "${CYAN}Plugins:${NC}" >&2
            for pdir in "${PLUGIN_DIRS[@]+"${PLUGIN_DIRS[@]}"}"; do
                echo "  --plugin-dir $pdir" >&2
            done
            echo "" >&2
        fi

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
