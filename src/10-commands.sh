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
    project_path=$(cd "$project_path" && pwd)

    local workspace
    if [[ -n "$MIGRATE_WORKSPACE" ]]; then
        workspace=$(expand_path "$MIGRATE_WORKSPACE")
        mkdir -p "$workspace"
        workspace=$(cd "$workspace" && pwd)
    else
        workspace="$ORIGINAL_CWD"
    fi

    local project_name
    project_name=$(basename "$project_path")

    echo -e "${BOLD}Migrating:${NC} ${project_name} → ${workspace}" >&2
    echo "" >&2

    # Scan project for Claude files
    local found_something=false
    local has_mcp=false has_agents=false has_skills=false has_settings=false has_claude_md=false

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

    # MCP: merge mcpServers
    if [[ "$has_mcp" == true ]]; then
        if [[ -f "$workspace/.mcp.json" ]]; then
            local tmp
            tmp=$(jq -s '.[0] * .[1] | .mcpServers = ((.[0].mcpServers // {}) * (.[1].mcpServers // {}))' \
                "$workspace/.mcp.json" "$project_path/.mcp.json")
            echo "$tmp" > "$workspace/.mcp.json"
            echo -e "${GREEN}Merged:${NC} .mcp.json" >&2
        else
            cp "$project_path/.mcp.json" "$workspace/.mcp.json"
            echo -e "${GREEN}Copied:${NC} .mcp.json" >&2
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
            echo "$tmp" > "$workspace/.claude/settings.local.json"
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
                echo -e "${GREEN}Appended:${NC} CLAUDE.md" >&2
            fi
        else
            cp "$project_path/CLAUDE.md" "$workspace/CLAUDE.md"
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
            tmp=$(jq --arg p "$rel_path" '.projects = ((.projects // []) + [{path: $p}])' "$config_path")
            echo "$tmp" > "$config_path"
            echo -e "${GREEN}Added to config:${NC} ${rel_path}" >&2
        fi
    else
        jq -n --arg p "$rel_path" '{projects: [{path: $p}]}' > "$config_path"
        echo -e "${GREEN}Created:${NC} ${CONFIG_FILE}" >&2
    fi

    # Delete originals if --delete
    if [[ "$MIGRATE_DELETE" == true ]]; then
        echo "" >&2
        echo -e "${CYAN}Removing originals...${NC}" >&2
        [[ "$has_mcp" == true ]] && rm -f "$project_path/.mcp.json" && echo -e "  ${RED}Deleted:${NC} .mcp.json" >&2
        [[ "$has_agents" == true ]] && rm -f "$project_path/.claude/agents/"*.md && echo -e "  ${RED}Deleted:${NC} .claude/agents/*.md" >&2
        [[ "$has_skills" == true ]] && rm -rf "$project_path/.claude/skills" && echo -e "  ${RED}Deleted:${NC} .claude/skills/" >&2
        [[ "$has_settings" == true ]] && rm -f "$project_path/.claude/settings.local.json" && echo -e "  ${RED}Deleted:${NC} .claude/settings.local.json" >&2
        [[ "$has_claude_md" == true ]] && rm -f "$project_path/CLAUDE.md" && echo -e "  ${RED}Deleted:${NC} CLAUDE.md" >&2
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
    source_path=$(cd "$source_path" && pwd)

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
    [[ -f "$source_path/.mcp.json" ]] && echo "  .mcp.json" >&2
    [[ -d "$source_path/.claude/agents" ]] && echo "  .claude/agents/" >&2
    [[ -d "$source_path/.claude/skills" ]] && echo "  .claude/skills/" >&2
    [[ -f "$source_path/.claude/settings.local.json" ]] && echo "  .claude/settings.local.json" >&2
    [[ -f "$source_path/CLAUDE.md" ]] && echo "  CLAUDE.md" >&2
    echo "" >&2
    echo -e "${CYAN}NOT copied (will rebuild):${NC}" >&2
    echo "  .compose-manifest.json" >&2
    echo "  .compose-hash" >&2
    echo "" >&2

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${GREEN}No mutations performed (dry run).${NC}" >&2
        return
    fi

    # Create dest and copy
    mkdir -p "$dest_path"

    cp "$source_path/$config_name" "$dest_path/$config_name"
    [[ -f "$source_path/.mcp.json" ]] && cp "$source_path/.mcp.json" "$dest_path/.mcp.json"
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

    # Launch Claude with compose-config for customization
    require_claude
    echo -e "${CYAN}Launching Claude for customization...${NC}" >&2
    local prompt
    prompt=$(compose_config_prompt "$dest_path/$config_name")
    (cd "$dest_path" && claude --system-prompt "$prompt" -p "do it")
}

# ── Instructions Command ─────────────────────────────────────────────
cmd_instructions() {
    require_jq

    local config_file="${CONFIG_FILE:-claude-compose.json}"
    if [[ ! -f "$config_file" ]]; then
        echo "No claude-compose.json found. Create one with: claude-compose config"
        return
    fi

    # Build dynamic workspace summary
    local summary=""
    local project_count preset_count ws_count
    project_count=$(jq '.projects // [] | length' "$config_file")
    preset_count=$(jq '.presets // [] | length' "$config_file")
    ws_count=$(jq '.workspaces // [] | length' "$config_file")
    local agent_count skill_count mcp_count env_count
    agent_count=$(jq '.resources.agents // [] | length' "$config_file")
    skill_count=$(jq '.resources.skills // [] | length' "$config_file")
    mcp_count=$(jq '.resources.mcp // {} | length' "$config_file")
    env_count=$(jq '.resources.env_files // [] | length' "$config_file")

    summary="## Current workspace"$'\n'
    summary+="- Projects: $project_count"$'\n'
    if [[ "$preset_count" -gt 0 ]]; then
        local preset_names
        preset_names=$(jq -r '.presets // [] | join(", ")' "$config_file")
        summary+="- Presets: $preset_names"$'\n'
    fi
    if [[ "$ws_count" -gt 0 ]]; then
        summary+="- Workspaces: $ws_count"$'\n'
    fi
    summary+="- Local resources: $agent_count agents, $skill_count skills, $mcp_count MCP servers, $env_count env files"

    if [[ "$preset_count" -gt 0 || "$ws_count" -gt 0 ]]; then
        summary+=$'\n'$'\n'"External resources are synced from presets/workspaces. Agents and skills"
        summary+=" are symlinked from source directories. MCP servers are merged into .mcp.json"
        summary+=" with env var prefixes to prevent conflicts."
    fi

    # Output prompt template with interpolated summary
    local prompt
    prompt=$(compose_instructions_prompt "$summary")
    echo "$prompt"
}

# ── Subcommand: config ───────────────────────────────────────────────
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
        if ! jq -n --arg p "$CONFIG_PATH" --arg n "$(basename "$CONFIG_PATH")" '{projects: [{path: $p, name: $n}]}' > "$tmp"; then
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
    claude --system-prompt "$prompt" -p "do it"
}

# ── Update Command ─────────────────────────────────────────────────────
cmd_update() {
    require_jq
    require_git

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}Error: ${CONFIG_FILE} not found${NC}" >&2
        exit 1
    fi

    echo -e "${BOLD}Checking for updates...${NC}" >&2
    echo "" >&2

    local updated=false

    # Collect github presets from config and global
    _update_presets_from_config() {
        local conf="$1"
        [[ ! -f "$conf" ]] && return

        local count
        count=$(jq '.presets // [] | length' "$conf" 2>/dev/null || echo 0)
        local i
        for i in $(seq 0 $((count - 1))); do
            local entry_type
            entry_type=$(jq -r ".presets[$i] | type" "$conf")
            [[ "$entry_type" != "object" ]] && continue

            local source
            source=$(jq -r ".presets[$i].source // empty" "$conf")
            [[ -z "$source" || "$source" != github:* ]] && continue

            # If specific source filter is set, skip non-matching
            if [[ -n "$UPDATE_SOURCE" && "$source" != *"$UPDATE_SOURCE"* ]]; then
                continue
            fi

            parse_github_source "$source"
            local owner="$_GH_OWNER" repo="$_GH_REPO" preset_path="$_GH_PATH" spec_str="$_GH_SPEC"

            local source_key="github:${owner}/${repo}"
            [[ -n "$preset_path" ]] && source_key+="/${preset_path}"

            local spec_parsed
            spec_parsed=$(parse_version_spec "$spec_str")
            local spec_type spec_major spec_minor spec_patch
            read -r spec_type spec_major spec_minor spec_patch <<< "$spec_parsed"

            # Read current lock
            local locked_version="" locked_tag=""
            local lock_data
            if lock_data=$(lock_read "$source_key"); then
                read -r locked_version locked_tag _ <<< "$lock_data"
            fi

            echo -e "${CYAN}${source_key}${NC}" >&2
            if [[ -n "$locked_version" ]]; then
                echo -e "  Current: v${locked_version} (spec: ${spec_str:-latest})" >&2
            else
                echo -e "  Current: (not installed)" >&2
            fi

            if [[ "$spec_type" == "exact" ]]; then
                echo -e "  ${YELLOW}Pinned at v${spec_major}.${spec_minor}.${spec_patch}${NC}" >&2
                continue
            fi

            # Fetch remote tags
            local remote_tags
            if ! remote_tags=$(registry_list_remote_tags "$owner" "$repo"); then
                echo -e "  ${RED}Failed to fetch tags${NC}" >&2
                continue
            fi

            local best_tag
            if ! best_tag=$(find_best_tag "$remote_tags" "$spec_type" "$spec_major" "$spec_minor" "$spec_patch"); then
                echo -e "  ${YELLOW}No matching tags found${NC}" >&2
                continue
            fi

            local best_parsed
            best_parsed=$(parse_tag_version "$best_tag")
            local best_major best_minor best_patch
            read -r best_major best_minor best_patch <<< "$best_parsed"
            local best_version="${best_major}.${best_minor}.${best_patch}"

            if [[ "$best_version" == "$locked_version" ]]; then
                echo -e "  ${GREEN}Already up to date (v${best_version})${NC}" >&2
                continue
            fi

            # Clone new version
            if ! registry_has_clone "$owner" "$repo" "$best_version"; then
                registry_clone_version "$owner" "$repo" "$best_tag" || continue
            fi

            if [[ -n "$locked_version" ]]; then
                if check_major_bump "$locked_version" "$best_version"; then
                    echo -e "  ${YELLOW}Major update:${NC} v${locked_version} → v${best_version}" >&2
                else
                    echo -e "  ${GREEN}Updated:${NC} v${locked_version} → v${best_version}" >&2
                fi
            else
                echo -e "  ${GREEN}Installed:${NC} v${best_version}" >&2
            fi

            lock_write "$source_key" "$best_version" "$best_tag" "$spec_str"
            updated=true
        done
    }

    _update_presets_from_config "$CONFIG_FILE"
    _update_presets_from_config "$GLOBAL_CONFIG"

    unset -f _update_presets_from_config

    echo "" >&2
    if [[ "$updated" == true ]]; then
        # Force rebuild
        rm -f ".compose-hash"
        echo -e "${GREEN}Updates applied. Rebuild will happen on next launch.${NC}" >&2
    else
        echo -e "${GREEN}All registries are up to date.${NC}" >&2
    fi
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
        root_path=$(cd "$root_path" && pwd)
    fi

    local prompt
    prompt=$(compose_start_prompt "$root_path")

    echo -e "${BOLD}claude-compose start${NC} — Onboarding wizard" >&2
    echo "" >&2

    if [[ -n "$root_path" ]]; then
        (cd "$root_path" && claude --system-prompt "$prompt")
    else
        claude --system-prompt "$prompt"
    fi
}

# ── Registries Command ─────────────────────────────────────────────────
cmd_registries() {
    require_jq

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}Error: ${CONFIG_FILE} not found${NC}" >&2
        exit 1
    fi

    echo -e "${BOLD}GitHub Presets${NC}" >&2
    echo "" >&2

    local found=false

    _list_presets_from_config() {
        local conf="$1" conf_label="$2"
        [[ ! -f "$conf" ]] && return

        local count
        count=$(jq '.presets // [] | length' "$conf" 2>/dev/null || echo 0)
        local i
        for i in $(seq 0 $((count - 1))); do
            local entry_type
            entry_type=$(jq -r ".presets[$i] | type" "$conf")
            [[ "$entry_type" != "object" ]] && continue

            local source
            source=$(jq -r ".presets[$i].source // empty" "$conf")
            [[ -z "$source" || "$source" != github:* ]] && continue

            found=true

            local prefix rename
            prefix=$(jq -r ".presets[$i].prefix // empty" "$conf")
            rename=$(jq -c ".presets[$i].rename // empty" "$conf")

            parse_github_source "$source"

            local source_key="github:${_GH_OWNER}/${_GH_REPO}"
            [[ -n "$_GH_PATH" ]] && source_key+="/${_GH_PATH}"

            echo -e "${CYAN}${source_key}${NC} (${conf_label})" >&2
            echo "  Source: ${source}" >&2
            echo "  Spec: ${_GH_SPEC:-latest}" >&2

            if [[ -n "$LOCK_FILE" && -f "$LOCK_FILE" ]]; then
                local locked_ver locked_tag
                locked_ver=$(jq -r --arg k "$source_key" '.registries[$k].resolved // empty' "$LOCK_FILE" 2>/dev/null || true)
                locked_tag=$(jq -r --arg k "$source_key" '.registries[$k].tag // empty' "$LOCK_FILE" 2>/dev/null || true)
                if [[ -n "$locked_ver" ]]; then
                    echo "  Locked: v${locked_ver} (${locked_tag})" >&2
                    local reg_dir
                    reg_dir=$(registry_preset_dir "$_GH_OWNER" "$_GH_REPO" "$locked_ver" "$_GH_PATH")
                    echo "  Path: ${reg_dir}" >&2
                else
                    echo "  Locked: (not installed)" >&2
                fi
            fi

            [[ -n "$prefix" ]] && echo "  Prefix: ${prefix}" >&2
            [[ -n "$rename" && "$rename" != "null" ]] && echo "  Rename: ${rename}" >&2
            echo "" >&2
        done
    }

    _list_presets_from_config "$CONFIG_FILE" "workspace"
    _list_presets_from_config "$GLOBAL_CONFIG" "global"

    unset -f _list_presets_from_config

    if [[ "$found" != true ]]; then
        echo -e "${YELLOW}No GitHub presets configured.${NC}" >&2
    fi
}
