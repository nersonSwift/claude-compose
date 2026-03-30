# ── Migrate Command ─────────────────────────────────────────────────
cmd_migrate() {
    require_jq

    if [[ -z "$MIGRATE_PATH" ]]; then
        echo -e "${RED}Error: Project path required. Usage: claude-compose migrate <project-path>${NC}" >&2
        exit 1
    fi

    local project_path
    project_path=$(expand_path "$MIGRATE_PATH")
    if [[ ! -d "$project_path" ]]; then
        echo -e "${RED}Error: Project directory not found: ${project_path}${NC}" >&2
        exit 1
    fi
    # Resolve to absolute path
    project_path=$(cd "$project_path" && pwd -P)

    local workspace
    if [[ -n "$MIGRATE_WORKSPACE" ]]; then
        workspace=$(expand_path "$MIGRATE_WORKSPACE")
        if [[ "$DRY_RUN" != true ]]; then
            mkdir -p "$workspace"
        fi
        if [[ -d "$workspace" ]]; then
            workspace=$(cd "$workspace" && pwd -P)
        fi
    else
        workspace="$WORKSPACE_DIR"
    fi

    local project_name
    project_name=$(basename "$project_path")

    echo -e "${BOLD}Migrating:${NC} ${project_name} → ${workspace}" >&2
    echo "" >&2

    # Scan project for Claude files
    local found_something=false
    local has_mcp=false has_agents=false has_skills=false has_settings=false has_claude_md=false
    local -a copied_agents=() copied_skills=()
    local copied_claude_md=false

    [[ -f "$project_path/.mcp.json" ]] && has_mcp=true && found_something=true
    [[ -d "$project_path/.claude/agents" ]] && ls "$project_path/.claude/agents/"*.md &>/dev/null 2>&1 && has_agents=true && found_something=true
    [[ -d "$project_path/.claude/skills" ]] && ls -d "$project_path/.claude/skills"/*/ &>/dev/null 2>&1 && has_skills=true && found_something=true
    [[ -f "$project_path/.claude/settings.local.json" ]] && has_settings=true && found_something=true
    [[ -f "$project_path/CLAUDE.md" ]] && has_claude_md=true && found_something=true

    if [[ "$found_something" == false ]]; then
        echo -e "${YELLOW}No Claude configuration files found in ${project_path}${NC}" >&2
        return
    fi

    echo -e "${CYAN}Discovered:${NC}" >&2
    [[ "$has_mcp" == true ]] && echo "  .mcp.json" >&2
    [[ "$has_agents" == true ]] && echo "  .claude/agents/*.md" >&2
    [[ "$has_skills" == true ]] && echo "  .claude/skills/*/" >&2
    [[ "$has_settings" == true ]] && echo "  .claude/settings.local.json" >&2
    [[ "$has_claude_md" == true ]] && echo "  CLAUDE.md" >&2
    echo "" >&2

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${GREEN}No mutations performed (dry run).${NC}" >&2
        return
    fi

    # ── Perform migration ──

    # MCP: merge mcpServers (source is project's native .mcp.json, destination is $COMPOSE_MCP)
    if [[ "$has_mcp" == true ]]; then
        mkdir -p "$workspace/$COMPOSE_DIR"
        if [[ -f "$workspace/$COMPOSE_MCP" ]]; then
            local tmp
            tmp=$(jq -s '.[0] * .[1] | .mcpServers = ((.[0].mcpServers // {}) * (.[1].mcpServers // {}))' \
                "$workspace/$COMPOSE_MCP" "$project_path/.mcp.json")
            atomic_write "$workspace/$COMPOSE_MCP" "$tmp"
            echo -e "${GREEN}Merged:${NC} ${COMPOSE_MCP}" >&2
        else
            cp "$project_path/.mcp.json" "$workspace/$COMPOSE_MCP"
            echo -e "${GREEN}Copied:${NC} ${COMPOSE_MCP}" >&2
        fi
    fi

    # Agents: copy (warn and skip on conflict)
    if [[ "$has_agents" == true ]]; then
        mkdir -p "$workspace/.claude/agents"
        for agent_file in "$project_path/.claude/agents/"*.md; do
            [[ -f "$agent_file" ]] || continue
            local agent_name
            agent_name=$(basename "$agent_file")
            if [[ -f "$workspace/.claude/agents/${agent_name}" ]]; then
                echo -e "${YELLOW}Skip (exists):${NC} .claude/agents/${agent_name}" >&2
            else
                cp "$agent_file" "$workspace/.claude/agents/${agent_name}"
                copied_agents+=("$agent_file")
                echo -e "${GREEN}Copied:${NC} .claude/agents/${agent_name}" >&2
            fi
        done
    fi

    # Skills: copy (warn and skip on conflict)
    if [[ "$has_skills" == true ]]; then
        mkdir -p "$workspace/.claude/skills"
        for skill_path in "$project_path/.claude/skills"/*/; do
            [[ -d "$skill_path" ]] || continue
            local skill_name
            skill_name=$(basename "$skill_path")
            if [[ -d "$workspace/.claude/skills/${skill_name}" ]]; then
                echo -e "${YELLOW}Skip (exists):${NC} .claude/skills/${skill_name}/" >&2
            else
                cp -R "$skill_path" "$workspace/.claude/skills/${skill_name}"
                copied_skills+=("$skill_path")
                echo -e "${GREEN}Copied:${NC} .claude/skills/${skill_name}/" >&2
            fi
        done
    fi

    # Permissions: merge allow arrays (deduplicate)
    if [[ "$has_settings" == true ]]; then
        mkdir -p "$workspace/.claude"
        if [[ -f "$workspace/.claude/settings.local.json" ]]; then
            local tmp
            tmp=$(jq -s '
                .[0] as $a | .[1] as $b |
                ($a * $b) | .permissions.allow = (($a.permissions.allow // []) + ($b.permissions.allow // []) | unique)
            ' "$workspace/.claude/settings.local.json" "$project_path/.claude/settings.local.json")
            atomic_write "$workspace/.claude/settings.local.json" "$tmp"
            echo -e "${GREEN}Merged:${NC} .claude/settings.local.json" >&2
        else
            cp "$project_path/.claude/settings.local.json" "$workspace/.claude/settings.local.json"
            echo -e "${GREEN}Copied:${NC} .claude/settings.local.json" >&2
        fi
    fi

    # CLAUDE.md: append with separator (check for duplicate marker)
    if [[ "$has_claude_md" == true ]]; then
        local marker="# --- Migrated from ${project_name} ---"
        if [[ -f "$workspace/CLAUDE.md" ]]; then
            if grep -qF "$marker" "$workspace/CLAUDE.md" 2>/dev/null; then
                echo -e "${YELLOW}Skip (already migrated):${NC} CLAUDE.md" >&2
            else
                {
                    echo ""
                    echo "$marker"
                    echo ""
                    cat "$project_path/CLAUDE.md"
                } >> "$workspace/CLAUDE.md"
                copied_claude_md=true
                echo -e "${GREEN}Appended:${NC} CLAUDE.md" >&2
            fi
        else
            cp "$project_path/CLAUDE.md" "$workspace/CLAUDE.md"
            copied_claude_md=true
            echo -e "${GREEN}Copied:${NC} CLAUDE.md" >&2
        fi
    fi

    # Create/update claude-compose.json
    local config_name
    config_name=$(basename "$CONFIG_FILE")
    local config_path="$workspace/$config_name"
    local rel_path="$MIGRATE_PATH"
    if [[ -f "$config_path" ]]; then
        # Check if path already exists
        local already_exists
        already_exists=$(jq --arg p "$rel_path" '.projects // [] | map(select(.path == $p)) | length' "$config_path")
        if [[ "$already_exists" -gt 0 ]]; then
            echo -e "${YELLOW}Project already in config:${NC} ${rel_path}" >&2
        else
            local tmp
            tmp=$(jq --arg p "$rel_path" --arg n "$project_name" '.projects = ((.projects // []) + [{path: $p, name: $n}])' "$config_path")
            atomic_write "$config_path" "$tmp"
            echo -e "${GREEN}Added to config:${NC} ${rel_path}" >&2
        fi
    else
        atomic_write "$config_path" "$(jq -n --arg ws "$(basename "$workspace")" --arg p "$rel_path" --arg n "$project_name" '{name: $ws, projects: [{path: $p, name: $n}]}')"
        echo -e "${GREEN}Created:${NC} ${CONFIG_FILE}" >&2
    fi

    # Delete originals if --delete (only files that were actually copied, not skipped)
    if [[ "$MIGRATE_DELETE" == true ]]; then
        echo "" >&2
        echo -e "${CYAN}Removing originals...${NC}" >&2
        [[ "$has_mcp" == true ]] && rm -f "$project_path/.mcp.json" && echo -e "  ${RED}Deleted:${NC} .mcp.json" >&2
        for f in "${copied_agents[@]}"; do
            rm -f "$f" && echo -e "  ${RED}Deleted:${NC} $(basename "$f")" >&2
        done
        for d in "${copied_skills[@]}"; do
            rm -rf "$d" && echo -e "  ${RED}Deleted:${NC} $(basename "$d")/" >&2
        done
        [[ "$has_settings" == true ]] && rm -f "$project_path/.claude/settings.local.json" && echo -e "  ${RED}Deleted:${NC} .claude/settings.local.json" >&2
        [[ "$copied_claude_md" == true ]] && rm -f "$project_path/CLAUDE.md" && echo -e "  ${RED}Deleted:${NC} CLAUDE.md" >&2
    fi

    echo "" >&2
    echo -e "${GREEN}Migration complete.${NC}" >&2
}

# ── Copy Command ─────────────────────────────────────────────────────
cmd_copy() {
    require_jq

    if [[ -z "$COPY_SOURCE" ]]; then
        echo -e "${RED}Error: Source workspace required. Usage: claude-compose copy <source> [dest]${NC}" >&2
        exit 1
    fi

    local source_path
    source_path=$(expand_path "$COPY_SOURCE")
    if [[ ! -d "$source_path" ]]; then
        echo -e "${RED}Error: Source directory not found: ${source_path}${NC}" >&2
        exit 1
    fi
    source_path=$(cd "$source_path" && pwd -P)

    local config_name
    config_name=$(basename "$CONFIG_FILE")

    if [[ ! -f "$source_path/$config_name" ]]; then
        echo -e "${RED}Error: Source is not a workspace (no ${config_name}): ${source_path}${NC}" >&2
        exit 1
    fi

    local dest_path
    if [[ -n "$COPY_DEST" ]]; then
        dest_path=$(expand_path "$COPY_DEST")
    else
        dest_path="$ORIGINAL_CWD"
    fi

    echo -e "${BOLD}Copying workspace:${NC} ${source_path} → ${dest_path}" >&2
    echo "" >&2

    # List what will be copied
    echo -e "${CYAN}Files to copy:${NC}" >&2
    echo "  $config_name" >&2
    local _src_mcp="$source_path/$COMPOSE_MCP"
    [[ -f "$_src_mcp" ]] && echo "  ${_src_mcp#"$source_path"/}" >&2
    [[ -d "$source_path/.claude/agents" ]] && echo "  .claude/agents/" >&2
    [[ -d "$source_path/.claude/skills" ]] && echo "  .claude/skills/" >&2
    [[ -f "$source_path/.claude/settings.local.json" ]] && echo "  .claude/settings.local.json" >&2
    [[ -f "$source_path/CLAUDE.md" ]] && echo "  CLAUDE.md" >&2
    [[ -f "$source_path/${config_name%.json}.lock.json" ]] && echo "  ${config_name%.json}.lock.json" >&2
    echo "" >&2
    echo -e "${CYAN}NOT copied (will rebuild):${NC}" >&2
    echo "  ${COMPOSE_MANIFEST}" >&2
    echo "  ${COMPOSE_HASH}" >&2
    echo "" >&2

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${GREEN}No mutations performed (dry run).${NC}" >&2
        return
    fi

    # Create dest and copy
    mkdir -p "$dest_path"

    cp "$source_path/$config_name" "$dest_path/$config_name"
    local lock_name="${config_name%.json}.lock.json"
    [[ -f "$source_path/$lock_name" ]] && cp "$source_path/$lock_name" "$dest_path/$lock_name"
    if [[ -f "$_src_mcp" ]]; then
        mkdir -p "$dest_path/$COMPOSE_DIR"
        cp "$_src_mcp" "$dest_path/$COMPOSE_MCP"
    fi
    [[ -f "$source_path/CLAUDE.md" ]] && cp "$source_path/CLAUDE.md" "$dest_path/CLAUDE.md"

    if [[ -d "$source_path/.claude/agents" ]]; then
        mkdir -p "$dest_path/.claude/agents"
        cp "$source_path/.claude/agents/"*.md "$dest_path/.claude/agents/" 2>/dev/null || true
    fi
    if [[ -d "$source_path/.claude/skills" ]]; then
        mkdir -p "$dest_path/.claude/skills"
        cp -R "$source_path/.claude/skills/"* "$dest_path/.claude/skills/" 2>/dev/null || true
    fi
    if [[ -f "$source_path/.claude/settings.local.json" ]]; then
        mkdir -p "$dest_path/.claude"
        cp "$source_path/.claude/settings.local.json" "$dest_path/.claude/settings.local.json"
    fi

    echo -e "${GREEN}Workspace copied.${NC}" >&2
    echo "" >&2

    # Offer to launch Claude for customization
    if [[ -t 0 ]]; then
        local reply=""
        echo -n "Launch Claude for customization? [y/N] " >&2
        read -r reply
        if [[ "$reply" =~ ^[Yy]$ ]]; then
            require_claude
            local prompt
            prompt=$(compose_config_prompt "$dest_path/$config_name")
            (cd "$dest_path" && claude --system-prompt "$prompt" "do it")
        fi
    else
        echo -e "${CYAN}Run 'claude-compose config' in ${dest_path} to customize.${NC}" >&2
    fi
}

# ── Subcommand: config ──────────────────────��────────────────────────
cmd_config() {
    require_jq

    # --check: validate config via dry-run pipeline
    if [[ "$CONFIG_CHECK" == true ]]; then
        if [[ ! -f "$CONFIG_FILE" ]]; then
            echo -e "${RED}Error: ${CONFIG_FILE} not found${NC}" >&2
            exit 1
        fi
        exec "$0" --dry-run -f "$CONFIG_FILE"
    fi

    # -y: quick create (pure bash, no Claude)
    if [[ "$CONFIG_YES" == true ]]; then
        if [[ -f "$CONFIG_FILE" ]]; then
            echo -e "${RED}Error: ${CONFIG_FILE} already exists. Run 'config' to edit.${NC}" >&2
            exit 1
        fi
        if [[ -z "$CONFIG_PATH" ]]; then
            echo -e "${RED}Error: Path required. Usage: claude-compose config -y <path>${NC}" >&2
            exit 1
        fi
        local tmp
        tmp=$(mktemp "${CONFIG_FILE}.XXXXXX")
        if ! jq -n --arg ws "$(basename "$WORKSPACE_DIR")" --arg p "$CONFIG_PATH" --arg n "$(basename "$CONFIG_PATH")" '{name: $ws, projects: [{path: $p, name: $n}]}' > "$tmp"; then
            rm -f "$tmp"
            echo -e "${RED}Error: Failed to create config${NC}" >&2
            exit 1
        fi
        mv "$tmp" "$CONFIG_FILE"
        echo -e "${GREEN}Created ${CONFIG_FILE}${NC}" >&2
        return
    fi

    # Interactive: launch Claude with compose-config prompt
    require_claude

    # Validate existing config JSON (but don't block if file is absent — prompt handles create mode)
    if [[ -f "$CONFIG_FILE" ]] && ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        echo -e "${RED}Error: Invalid JSON in ${CONFIG_FILE}${NC}" >&2
        exit 1
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${CYAN}Config not found. Entering create mode.${NC}" >&2
    fi

    local prompt
    prompt=$(compose_config_prompt "$CONFIG_FILE")
    claude --system-prompt "$prompt" "do it"
}

# ── Doctor Command ─────────────────────────────────────────────────────
cmd_doctor() {
    require_jq
    require_claude
    launch_doctor ""
}

# ── Start Command ──────────────────────────────────────────────────────
cmd_start() {
    require_claude

    local root_path=""
    if [[ -n "$START_PATH" ]]; then
        root_path=$(expand_path "$START_PATH")
        if [[ ! -d "$root_path" ]]; then
            echo -e "${RED}Error: Directory not found: ${root_path}${NC}" >&2
            exit 1
        fi
        root_path=$(cd "$root_path" && pwd -P)
    fi

    local prompt
    prompt=$(compose_start_prompt "$root_path")

    echo -e "${BOLD}claude-compose start${NC} — Onboarding wizard" >&2
    echo "" >&2

    if [[ -n "$root_path" ]]; then
        (cd "$root_path" && claude --system-prompt "$prompt" "do it")
    else
        claude --system-prompt "$prompt" "do it"
    fi
}

# ── Wrap Doctor Helper ─────────────────────────────────────────────────
# Launch doctor session through the IDE's claude binary, preserving all IDE flags.
# Replaces --append-system-prompt with doctor --system-prompt.
# Injects initial "fix it" message via stdin pipe (stream-json format).
_wrap_launch_doctor() {
    local error_msg="${1:-Config validation failed}"
    local ws_dir="${WORKSPACE_DIR:-$(dirname "$CONFIG_FILE")}"

    local prompt
    prompt=$(compose_doctor_prompt "$CONFIG_FILE" "$ws_dir" "$error_msg")

    # Keep all IDE flags except --append-system-prompt (replaced by --system-prompt).
    # ALL other flags (--input-format, --output-format, --verbose, -p) stay intact.
    local doctor_args=()
    local i=0
    while [[ $i -lt ${#WRAP_PASSTHROUGH_ARGS[@]} ]]; do
        case "${WRAP_PASSTHROUGH_ARGS[$i]}" in
            --append-system-prompt)
                i=$((i + 1))  # skip value
                ;;
            *)
                doctor_args+=("${WRAP_PASSTHROUGH_ARGS[$i]}")
                ;;
        esac
        i=$((i + 1))
    done

    doctor_args+=("--system-prompt" "$prompt")
    doctor_args+=("--name" "compose-doctor")

    # Inject initial "fix it" message via stdin in stream-json format,
    # then forward remaining IDE stdin via cat.
    # Cannot use exec here because we need to prepend to stdin.
    # Foreground pipeline: cat inherits real stdin (IDE), signals propagate naturally.
    {
        printf '{"type":"user","message":{"role":"user","content":"fix it"}}\n'
        cat
    } | "$WRAP_CLAUDE_BIN" "${doctor_args[@]}"
    exit $?
}

# ── Wrap Command (IDE process wrapper) ────────────────────────────────
cmd_wrap() {
    # 1. Validate claude binary exists and is executable
    if [[ ! -x "$WRAP_CLAUDE_BIN" ]]; then
        echo "claude-compose wrap: claude binary not found or not executable: $WRAP_CLAUDE_BIN" >&2
        exit 1
    fi

    # 2. Resolve CONFIG_FILE to absolute path
    if [[ -f "$CONFIG_FILE" ]]; then
        CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd -P)/$(basename "$CONFIG_FILE")"
    fi

    # 3. No config → passthrough (no compose workspace here)
    if [[ ! -f "$CONFIG_FILE" ]]; then
        exec "$WRAP_CLAUDE_BIN" "${WRAP_PASSTHROUGH_ARGS[@]+"${WRAP_PASSTHROUGH_ARGS[@]}"}"
    fi

    # 3a. Invalid JSON → launch doctor in IDE
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        local _json_err
        _json_err=$(jq empty "$CONFIG_FILE" 2>&1 || true)
        _wrap_launch_doctor "Invalid JSON in ${CONFIG_FILE}: ${_json_err}"
    fi

    # 4. Resolve workspace directory (sets CONFIG_DIR, WORKSPACE_DIR, cd to WORKSPACE_DIR)
    _resolve_workspace_dir

    # 6. Disable trap-based doctor (wrap uses _wrap_launch_doctor instead)
    DOCTOR_ENABLED=false

    # 7. Validate — on failure, launch doctor in IDE
    local _validate_err=""
    _validate_err=$(DRY_RUN=true validate 2>&1 >/dev/null) || {
        _wrap_launch_doctor "${_validate_err:-Config validation failed}"
    }


    # 8. Ensure built-in plugin is extracted
    ensure_builtin_plugin

    # 9. Auto-build if needed (suppress stderr — no banners in wrap mode)
    local project_count
    project_count=$(jq '.projects // [] | length' "$CONFIG_FILE")

    if [[ "$project_count" -eq 0 ]] && ! _has_anything_to_build; then
        # Nothing to compose — passthrough
        exec "$WRAP_CLAUDE_BIN" "${WRAP_PASSTHROUGH_ARGS[@]+"${WRAP_PASSTHROUGH_ARGS[@]}"}"
    fi

    if _has_anything_to_build && needs_rebuild; then
        # On failure: launch doctor in IDE
        local _build_err=""
        _build_err=$(build "false" 2>&1 >/dev/null) || {
            # Release lock (subshell can't clean up — _BUILD_LOCK_HELD lost)
            _release_lock "$COMPOSE_LOCK" 2>/dev/null || true
            _wrap_launch_doctor "${_build_err:-Build failed}"
        }

        # Update .code-workspace if it already exists (keep in sync after rebuild)
        local _ws_name _ws_file
        _ws_name=$(jq -r '.name // empty' "$CONFIG_FILE" 2>/dev/null)
        [[ -z "$_ws_name" ]] && _ws_name="$(basename "$PWD")"
        _ws_file="${PWD}/${_ws_name}.code-workspace"
        if [[ -f "$_ws_file" ]]; then
            _generate_code_workspace "$PWD" 2>/dev/null || true
        fi
    fi

    # 10. Load env files
    load_global_env_files
    load_env_files
    load_all_source_env_files

    # 11. Collect compose args using shared helpers (see src/08a-collect.sh)
    _collect_project_args "false"
    _init_system_prompt
    _collect_manifest_args "false"
    _build_settings "false" "true"

    # --mcp-config with ABSOLUTE path (wrap-only: CWD may differ from workspace)
    if [[ -f "$COMPOSE_MCP" ]]; then
        CLAUDE_ARGS+=("--mcp-config" "$(pwd -P)/$COMPOSE_MCP")
    fi

    # Plugin dirs
    _collect_plugin_args "false" "$CONFIG_DIR"

    # Check for critical warnings from arg collection phase
    _wrap_check_warnings

    # 12. Merge --append-system-prompt from VS Code and compose

    # Extract IDE's --append-system-prompt from WRAP_PASSTHROUGH_ARGS
    local ide_system_prompt=""
    local filtered_passthrough=()
    local i=0
    while [[ $i -lt ${#WRAP_PASSTHROUGH_ARGS[@]} ]]; do
        if [[ "${WRAP_PASSTHROUGH_ARGS[$i]}" == "--append-system-prompt" ]]; then
            i=$((i + 1))
            [[ $i -lt ${#WRAP_PASSTHROUGH_ARGS[@]} ]] && ide_system_prompt="${WRAP_PASSTHROUGH_ARGS[$i]}"
        else
            filtered_passthrough+=("${WRAP_PASSTHROUGH_ARGS[$i]}")
        fi
        i=$((i + 1))
    done

    # Extract compose's --append-system-prompt from CLAUDE_ARGS
    local compose_system_prompt=""
    local final_args=()
    i=0
    while [[ $i -lt ${#CLAUDE_ARGS[@]} ]]; do
        if [[ "${CLAUDE_ARGS[$i]}" == "--append-system-prompt" ]]; then
            i=$((i + 1))
            [[ $i -lt ${#CLAUDE_ARGS[@]} ]] && compose_system_prompt="${CLAUDE_ARGS[$i]}"
        else
            final_args+=("${CLAUDE_ARGS[$i]}")
        fi
        i=$((i + 1))
    done

    # Merge: compose context first, then VS Code context
    local merged_prompt=""
    [[ -n "$compose_system_prompt" ]] && merged_prompt="$compose_system_prompt"
    if [[ -n "$ide_system_prompt" ]]; then
        [[ -n "$merged_prompt" ]] && merged_prompt+=$'\n\n'
        merged_prompt+="$ide_system_prompt"
    fi
    [[ -n "$merged_prompt" ]] && final_args+=("--append-system-prompt" "$merged_prompt")

    # 13. Add filtered passthrough args (VS Code args minus extracted --append-system-prompt)
    if [[ ${#filtered_passthrough[@]} -gt 0 ]]; then
        final_args+=("${filtered_passthrough[@]}")
    fi

    # 14. Set CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD if needed
    if [[ "$HAS_ANY_ADD_DIR" == true ]]; then
        export CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1
    fi

    # 15. exec claude — replaces process, preserves stream-json stdin/stdout pipe
    exec "$WRAP_CLAUDE_BIN" "${final_args[@]+"${final_args[@]}"}"
}

# ── .code-workspace Generation ────────────────────────────────────────
_generate_code_workspace() {
    local ws_dir="$1"
    local ws_name config_file manifest_file ws_file
    config_file="$ws_dir/claude-compose.json"
    ws_name=$(jq -r '.name // empty' "$config_file" 2>/dev/null)
    if [[ -z "$ws_name" ]]; then
        ws_name="$(basename "$ws_dir")"
    fi
    manifest_file="$ws_dir/$COMPOSE_MANIFEST"
    ws_file="$ws_dir/${ws_name}.code-workspace"

    if [[ ! -f "$config_file" ]]; then
        return
    fi

    # 1. Collect folders as JSON array: [{path, name, prefix}]
    local folders_json='[]'

    # 1a. Workspace dir itself
    folders_json=$(jq -n --arg name "$ws_name" '[{path: ".", name: $name, prefix: "MainWS"}]')

    # 1b. Projects from config
    local projects_json
    projects_json=$(jq '[
        .projects // [] | .[] |
        {
            path: .path,
            name: (.name // (.path | split("/") | last)),
            prefix: "Project"
        }
    ]' "$config_file")
    folders_json=$(jq --argjson p "$projects_json" '. + $p' <<< "$folders_json")

    # 1c. Build path→name map from all reachable compose configs (for project alias lookup)
    local path_name_map='{}'
    # Main config projects
    path_name_map=$(jq --arg home "$HOME" '[
        .projects // [] | .[] |
        select(.name) |
        {key: (.path | sub("^~"; $home)), value: .name}
    ] | from_entries' "$config_file")
    # Workspace configs referenced in manifest
    if [[ -f "$manifest_file" ]]; then
        local ws_key
        while IFS= read -r ws_key; do
            [[ -z "$ws_key" ]] && continue
            local nested_config="$ws_key/claude-compose.json"
            [[ ! -f "$nested_config" ]] && continue
            local nested_map
            nested_map=$(jq --arg home "$HOME" '[
                .projects // [] | .[] |
                select(.name) |
                {key: (.path | sub("^~"; $home)), value: .name}
            ] | from_entries' "$nested_config")
            path_name_map=$(jq --argjson n "$nested_map" '. + $n' <<< "$path_name_map")
        done < <(jq -r '[.global, .workspaces, .resources] | map(keys? // []) | add | .[]' "$manifest_file" 2>/dev/null)
    fi

    # 1d. add_dirs + project_dirs from manifest sections
    if [[ -f "$manifest_file" ]]; then
        local section prefix
        for section in global workspaces resources; do
            case "$section" in
                global)     prefix="Global" ;;
                workspaces) prefix="Workspace" ;;
                resources)  prefix="Local" ;;
                *)          prefix="Source" ;;
            esac
            local section_dirs
            # add_dirs: use source_name for display name
            section_dirs=$(jq --arg s "$section" --arg pfx "$prefix" '[
                .[$s] // {} | to_entries[] |
                .value.source_name as $sname |
                (.value.add_dirs // []) |
                [.[] | if type == "object" then .path else . end] | .[] |
                {path: ., name: (if ($sname | length) > 0 then $sname else (. | split("/") | last) end), prefix: $pfx}
            ]' "$manifest_file")
            folders_json=$(jq --argjson d "$section_dirs" '. + $d' <<< "$folders_json")
            # project_dirs: look up alias from path_name_map, fall back to basename
            section_dirs=$(jq --arg s "$section" --arg pfx "Project" --argjson names "$path_name_map" '[
                .[$s] // {} | to_entries[] |
                (.value.project_dirs // []) |
                [.[] | if type == "object" then .path else . end] | .[] |
                {path: ., name: ($names[.] // (. | split("/") | last)), prefix: $pfx}
            ]' "$manifest_file")
            folders_json=$(jq --argjson d "$section_dirs" '. + $d' <<< "$folders_json")
        done
    fi

    # 2. Expand ~ and resolve relative paths, then deduplicate (first wins)
    folders_json=$(jq --arg ws "$ws_dir" --arg home "$HOME" '
        reduce .[] as $entry ([];
            ($entry.path | sub("^~"; $home)) as $expanded |
            (if $expanded | startswith("/") then $expanded
             else ($ws + "/" + $expanded) end) as $abs |
            if any(.[]; ._abs == $abs) then .
            else . + [$entry + {_abs: $abs} + (if $entry.path == "." then {} else {path: $abs} end)]
            end
        ) | [.[] | del(._abs)]
    ' <<< "$folders_json")

    # 3. Sort: Workspace first, then Project, then Preset
    folders_json=$(jq '
        sort_by(if .prefix == "MainWS" then 0 elif .prefix == "Workspace" then 1 elif .prefix == "Project" then 2 else 3 end)
    ' <<< "$folders_json")

    # 4. Convert to VS Code format: [{path, name: "Prefix / name"}]
    local managed_folders
    managed_folders=$(jq '[.[] | {path: .path, name: (.prefix + " / " + .name)}]' <<< "$folders_json")

    # 5. Merge with existing file
    local result
    if [[ -f "$ws_file" ]] && jq empty "$ws_file" 2>/dev/null; then
        result=$(jq --argjson managed "$managed_folders" '
            ((.folders // []) | [.[] | select(
                (.name // "") |
                (startswith("MainWS / ") or startswith("Workspace / ") or startswith("Project / ") or startswith("Preset / ")) | not
            )]) as $user |
            . + {folders: ($user + $managed)}
        ' "$ws_file")
    else
        result=$(jq '{folders: ., settings: {}}' <<< "$managed_folders")
    fi

    # 6. Write and report
    atomic_write "$ws_file" "$result"
    echo -e "${GREEN}Generated:${NC} ${ws_file}" >&2
}

# ── IDE Setup Command ─────────────────────────────────────────────────
cmd_ide() {
    require_jq

    local variant="${IDE_VARIANT:-code}"

    # 1. Determine settings.json location per OS and variant
    local settings_dir
    case "$(uname)" in
        Darwin)
            case "$variant" in
                code)     settings_dir="$HOME/Library/Application Support/Code/User" ;;
                insiders) settings_dir="$HOME/Library/Application Support/Code - Insiders/User" ;;
                cursor)   settings_dir="$HOME/Library/Application Support/Cursor/User" ;;
                *)
                    echo -e "${RED}Error: Unknown variant: ${variant}. Use: code, insiders, cursor${NC}" >&2
                    exit 1
                    ;;
            esac
            ;;
        Linux)
            case "$variant" in
                code)     settings_dir="$HOME/.config/Code/User" ;;
                insiders) settings_dir="$HOME/.config/Code - Insiders/User" ;;
                cursor)   settings_dir="$HOME/.config/Cursor/User" ;;
                *)
                    echo -e "${RED}Error: Unknown variant: ${variant}. Use: code, insiders, cursor${NC}" >&2
                    exit 1
                    ;;
            esac
            ;;
        *)
            echo -e "${RED}Error: Unsupported OS: $(uname). Only macOS and Linux are supported.${NC}" >&2
            exit 1
            ;;
    esac

    local settings_file="$settings_dir/settings.json"

    # 2. Find wrapper script (shipped alongside binary)
    local wrapper_path=""
    local self_path self_dir
    self_path="$(command -v claude-compose 2>/dev/null || echo "$0")"
    # Resolve to absolute path if relative (ensures wrapper_path works from any CWD)
    if [[ "$self_path" != /* ]]; then
        self_path="$(cd "$(dirname "$self_path")" && pwd -P)/$(basename "$self_path")"
    fi
    self_dir="$(dirname "$self_path")"

    if [[ -x "$self_dir/claude-compose-wrapper" ]]; then
        wrapper_path="$(cd "$self_dir" && pwd -P)/claude-compose-wrapper"
    elif command -v claude-compose-wrapper &>/dev/null; then
        wrapper_path="$(command -v claude-compose-wrapper)"
    fi

    if [[ -z "$wrapper_path" ]]; then
        echo -e "${RED}Error: claude-compose-wrapper not found.${NC}" >&2
        echo "It should be installed alongside claude-compose." >&2
        echo "Reinstall claude-compose or place claude-compose-wrapper in your PATH." >&2
        exit 1
    fi

    # 3. Update VS Code settings.json
    if [[ ! -d "$settings_dir" ]]; then
        echo "" >&2
        echo -e "${YELLOW}Settings directory not found:${NC} ${settings_dir}" >&2
        echo "" >&2
        echo "Add this to your VS Code settings.json manually:" >&2
        echo "  \"claudeCode.claudeProcessWrapper\": \"${wrapper_path}\"" >&2
        return
    fi

    if [[ ! -f "$settings_file" ]]; then
        atomic_write "$settings_file" "{}"
    fi

    if ! jq empty "$settings_file" 2>/dev/null; then
        echo "" >&2
        echo -e "${RED}Error: Invalid JSON in ${settings_file}${NC}" >&2
        echo "" >&2
        echo "Add this to your VS Code settings.json manually:" >&2
        echo "  \"claudeCode.claudeProcessWrapper\": \"${wrapper_path}\"" >&2
        return
    fi

    local updated
    updated=$(jq --arg w "$wrapper_path" '."claudeCode.claudeProcessWrapper" = $w' "$settings_file")
    atomic_write "$settings_file" "$updated"

    echo -e "${GREEN}Updated:${NC} ${settings_file}" >&2
    echo "  claudeCode.claudeProcessWrapper = ${wrapper_path}" >&2

    # ── Generate .code-workspace ─────────────────────────────────────
    if [[ -f "$CONFIG_FILE" ]]; then
        # Ensure manifest is up-to-date
        (cd "$WORKSPACE_DIR" && {
            if needs_rebuild; then
                build "false"
            fi
        })

        _generate_code_workspace "$WORKSPACE_DIR"
    else
        echo "" >&2
        echo -e "${YELLOW}No claude-compose.json found. Skipping .code-workspace generation.${NC}" >&2
        echo "  Run 'claude-compose config' first, then 'claude-compose ide' again." >&2
    fi

    # ── Success message ──────────────────────────────────────────────
    echo "" >&2
    echo -e "${BOLD}IDE integration configured!${NC}" >&2
    echo "" >&2
    echo "Next steps:" >&2
    if [[ -f "$CONFIG_FILE" ]]; then
        local ws_name
        ws_name=$(jq -r '.name // empty' "$CONFIG_FILE" 2>/dev/null)
        [[ -z "$ws_name" ]] && ws_name="$(basename "$WORKSPACE_DIR")"
        echo "  Open ${ws_name}.code-workspace in your IDE (File → Open Workspace from File)" >&2
    else
        echo "  1. Run 'claude-compose config' to create a config" >&2
        echo "  2. Run 'claude-compose ide' again to generate .code-workspace" >&2
    fi
    echo "" >&2
    echo "To remove: delete claudeCode.claudeProcessWrapper from your IDE settings" >&2
    echo "(VS Code: Cmd+Shift+P → Preferences: Open Settings (JSON))." >&2
}

