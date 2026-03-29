# ── Process a single workspace source ───────────────────────────────
process_workspace_source() {
    local ws_json="$1"
    local base_dir="${2:-$CONFIG_DIR}"

    local raw_path
    raw_path=$(jq -r '.path' <<< "$ws_json")
    local ws_path
    ws_path=$(expand_path "$raw_path" "$base_dir")

    # If path points to a file, use its directory
    local ws_config_file=""
    if [[ -f "$ws_path" ]]; then
        ws_config_file="$ws_path"
        ws_path=$(dirname "$ws_path")
    elif [[ ! -d "$ws_path" ]]; then
        echo -e "${YELLOW}Warning: Workspace not found, skipping: ${raw_path}${NC}" >&2
        return
    fi

    # Resolve to absolute (handles symlinks)
    ws_path=$(cd "$ws_path" && pwd -P)

    # Skip self (cycle prevention)
    local self_dir
    self_dir=$(pwd -P)
    if [[ "$ws_path" == "$self_dir" ]]; then
        echo -e "${YELLOW}Warning: Skipping self: ${ws_path}${NC}" >&2
        return
    fi

    # Deduplication — skip if already processed
    for processed in "${PROCESSED_WORKSPACES[@]+"${PROCESSED_WORKSPACES[@]}"}"; do
        if [[ "$processed" == "$ws_path" ]]; then
            echo -e "${YELLOW}Warning: Workspace already processed, skipping: ${ws_path}${NC}" >&2
            return
        fi
    done
    PROCESSED_WORKSPACES+=("$ws_path")

    local ws_name
    ws_name=$(basename "$ws_path")
    echo -e "${CYAN}Processing workspace:${NC} ${ws_name} (${ws_path})" >&2

    # Build filter JSON from workspace config entry
    local filter_json
    filter_json=$(jq -c '{
        mcp: (.mcp // {}),
        agents: (.agents // {}),
        skills: (.skills // {}),
        plugins: (.plugins // {}),
        claude_md: (if .claude_md == null then true else .claude_md end)
    }' <<< "$ws_json")

    # Extract cascade values for claude_md
    local ws_claude_md ws_claude_md_overrides
    ws_claude_md=$(jq -r 'if .claude_md == null then "true" else (.claude_md | tostring) end' <<< "$ws_json")
    ws_claude_md_overrides=$(jq -c '.claude_md_overrides // {}' <<< "$ws_json")

    # Sync resources (MCP, agents, skills — no permissions)
    sync_source_dir "$ws_path" "$filter_json" "$(basename "$ws_path")"

    # Collect workspace's own projects (from its claude-compose.json)
    local ws_config="${ws_config_file:-$ws_path/claude-compose.json}"
    if [[ -f "$ws_config" ]]; then
        local ws_project_count
        ws_project_count=$(jq '.projects // [] | length' "$ws_config" 2>/dev/null || echo 0)
        if [[ "$ws_project_count" -gt 0 ]]; then
            local wpi
            for ((wpi = 0; wpi < ws_project_count; wpi++)); do
                local proj_path proj_claude_md proj_name
                proj_path=$(jq -r ".projects[$wpi].path" "$ws_config")
                proj_path=$(expand_path "$proj_path" "$ws_path")
                proj_name=$(jq -r ".projects[$wpi].name // empty" "$ws_config")
                [[ -z "$proj_name" ]] && proj_name=$(basename "$proj_path")
                proj_claude_md=$(jq -r ".projects[$wpi].claude_md // true" "$ws_config")

                if [[ ! -d "$proj_path" ]]; then
                    continue
                fi

                # Direct-wins: skip if this project is directly configured in root
                local _is_direct=false _dp
                for _dp in "${DIRECT_PROJECT_PATHS[@]+"${DIRECT_PROJECT_PATHS[@]}"}"; do
                    [[ "$_dp" == "$proj_path" ]] && _is_direct=true && break
                done
                if [[ "$_is_direct" == "true" ]]; then
                    echo -e "  ${YELLOW}skip project:${NC} $proj_name (directly configured)" >&2
                    continue
                fi

                # claude_md_overrides: per-project override from workspace entry
                local override_val
                override_val=$(jq -r --arg n "$proj_name" '.[$n] // empty' <<< "$ws_claude_md_overrides")
                if [[ -n "$override_val" ]]; then
                    proj_claude_md="$override_val"
                elif [[ "$ws_claude_md" == "false" ]]; then
                    # Cascade: workspace claude_md:false caps all projects
                    proj_claude_md="false"
                fi

                CURRENT_SOURCE_PROJECT_DIRS+=("${proj_path}|${proj_claude_md}")
                echo -e "  ${GREEN}+project:${NC} $proj_name (from workspace)" >&2
            done

            # Warn about unmatched claude_md_overrides keys (typo detection)
            if [[ "$ws_claude_md_overrides" != "{}" ]]; then
                local _cmo_keys
                _cmo_keys=$(jq -r 'keys[]' <<< "$ws_claude_md_overrides" 2>/dev/null || true)
                while IFS= read -r _cmo_key; do
                    [[ -z "$_cmo_key" ]] && continue
                    local _cmo_matched=false _cwpi
                    for ((_cwpi = 0; _cwpi < ws_project_count; _cwpi++)); do
                        local _cwp_name
                        _cwp_name=$(jq -r ".projects[$_cwpi].name // empty" "$ws_config")
                        [[ -z "$_cwp_name" ]] && _cwp_name=$(basename "$(jq -r ".projects[$_cwpi].path" "$ws_config")")
                        [[ "$_cwp_name" == "$_cmo_key" ]] && _cmo_matched=true && break
                    done
                    if [[ "$_cmo_matched" == "false" ]]; then
                        echo -e "  ${YELLOW}Warning: claude_md_overrides key \"$_cmo_key\" does not match any project in workspace${NC}" >&2
                    fi
                done <<< "$_cmo_keys"
            fi
        fi

        # Collect workspace plugins (with filter)
        collect_workspace_plugins "$ws_config" "$ws_path" "$filter_json"
    fi

    # Write manifest — use path as key (workspaces don't have global names)
    CURRENT_SOURCE_NAME="$(basename "$ws_path")"
    write_source_manifest "workspaces" "$ws_path"
}

# ── Process resources from a config file ───────────────────────────
# Args: [config_file] [base_dir] [label] [manifest_section] [manifest_key]
# Defaults preserve backward compatibility for local resources.
process_resources() {
    local config_file="${1:-$CONFIG_FILE}"
    local base_dir="${2:-$CONFIG_DIR}"
    local label="${3:-local}"
    local manifest_section="${4:-resources}"
    local manifest_key="${5:-local}"

    # Reset tracking (must happen before early return so callers see clean arrays)
    _reset_current_source

    local resources
    resources=$(jq -c '.resources // {}' "$config_file")
    if [[ "$resources" == "{}" || "$resources" == "null" ]]; then
        return
    fi

    echo -e "${CYAN}Processing ${label} resources${NC}" >&2

    # ── Sync agents (symlink or copy+rename) ──
    local agents
    agents=$(jq -r '.resources.agents // [] | .[]' "$config_file" 2>/dev/null || true)
    while IFS= read -r agent_path; do
        [[ -z "$agent_path" ]] && continue
        local abs_path="$base_dir/$agent_path"
        if [[ ! -f "$abs_path" ]]; then
            echo -e "  ${YELLOW}Warning: agent not found: ${agent_path}${NC}" >&2
            continue
        fi
        abs_path=$(cd "$(dirname "$abs_path")" && pwd -P)/$(basename "$abs_path")
        if ! _is_within_dir "$abs_path" "$base_dir"; then
            echo -e "  ${YELLOW}Warning: agent escapes base directory, skipping: ${agent_path}${NC}" >&2
            continue
        fi
        local agent_basename
        agent_basename=$(basename "$agent_path")
        local name_no_ext="${agent_basename%.md}"
        mkdir -p ".claude/agents"
        if [[ -f ".claude/agents/${agent_basename}" || -L ".claude/agents/${agent_basename}" ]]; then
            echo -e "  ${YELLOW}overwrite:${NC} .claude/agents/${agent_basename}" >&2
        fi
        ln -sf "$abs_path" ".claude/agents/${agent_basename}"
        CURRENT_SOURCE_AGENTS+=("$agent_basename")
        echo -e "  ${GREEN}+agent:${NC} ${name_no_ext} (${label})" >&2
    done <<< "$agents"

    # ── Sync skills (symlink or copy+rename) ──
    local skills
    skills=$(jq -r '.resources.skills // [] | .[]' "$config_file" 2>/dev/null || true)
    while IFS= read -r skill_path; do
        [[ -z "$skill_path" ]] && continue
        local abs_path="$base_dir/$skill_path"
        if [[ ! -d "$abs_path" ]]; then
            echo -e "  ${YELLOW}Warning: skill not found: ${skill_path}${NC}" >&2
            continue
        fi
        abs_path=$(cd "$abs_path" && pwd -P)
        if ! _is_within_dir "$abs_path" "$base_dir"; then
            echo -e "  ${YELLOW}Warning: skill escapes base directory, skipping: ${skill_path}${NC}" >&2
            continue
        fi
        local skill_basename
        skill_basename=$(basename "$skill_path")
        mkdir -p ".claude/skills"
        if [[ -L ".claude/skills/${skill_basename}" || -d ".claude/skills/${skill_basename}" ]]; then
            echo -e "  ${YELLOW}overwrite:${NC} .claude/skills/${skill_basename}/" >&2
            rm -f ".claude/skills/${skill_basename}" 2>/dev/null || rm -rf ".claude/skills/${skill_basename}"
        fi
        ln -sf "$abs_path" ".claude/skills/${skill_basename}"
        CURRENT_SOURCE_SKILLS+=("$skill_basename")
        echo -e "  ${GREEN}+skill:${NC} ${skill_basename} (${label})" >&2
    done <<< "$skills"

    # ── Merge MCP servers ──
    ensure_compose_dir
    if [[ ! -f "$COMPOSE_MCP" ]]; then
        atomic_write "$COMPOSE_MCP" "$_MCP_EMPTY"
    fi

    local mcp_batch='{}'
    local mcp_keys
    mcp_keys=$(jq -r '.resources.mcp // {} | keys[]' "$config_file" 2>/dev/null || true)
    while IFS= read -r server_name; do
        [[ -z "$server_name" ]] && continue
        local server_config
        server_config=$(jq -c --arg n "$server_name" '.resources.mcp[$n]' "$config_file")

        mcp_batch=$(jq --arg name "$server_name" --argjson config "$server_config" '.[$name] = $config' <<< "$mcp_batch")

        CURRENT_SOURCE_MCP_SERVERS+=("$server_name")
        echo -e "  ${GREEN}+mcp:${NC} ${server_name} (${label})" >&2
    done <<< "$mcp_keys"

    if [[ "$mcp_batch" != '{}' ]]; then
        local overwrites
        overwrites=$(jq -r --argjson batch "$mcp_batch" \
            '[.mcpServers // {} | keys[] as $k | select($batch | has($k)) | $k] | .[]' \
            "$COMPOSE_MCP" 2>/dev/null || true)
        while IFS= read -r ow; do
            [[ -z "$ow" ]] && continue
            echo -e "  ${YELLOW}overwrite mcp:${NC} $ow" >&2
        done <<< "$overwrites"
        local tmp
        tmp=$(jq --argjson batch "$mcp_batch" '.mcpServers += $batch' "$COMPOSE_MCP")
        atomic_write "$COMPOSE_MCP" "$tmp"
    fi

    write_source_manifest "$manifest_section" "$manifest_key"
}

# ── Process global config ────────────────────────────────────────────
process_global() {
    [[ ! -f "$GLOBAL_CONFIG" ]] && return

    echo -e "${CYAN}Processing global config${NC}" >&2

    process_resources "$GLOBAL_CONFIG" "$GLOBAL_CONFIG_DIR" "global" "global" "resources"

    # ── Global projects (top-level, not inside resources) ──
    local global_project_count
    global_project_count=$(jq '.projects // [] | length' "$GLOBAL_CONFIG" 2>/dev/null || echo 0)
    if [[ "$global_project_count" -gt 0 ]]; then
        _reset_current_source

        local gpi2
        for ((gpi2 = 0; gpi2 < global_project_count; gpi2++)); do
            local proj_path proj_claude_md
            proj_path=$(jq -r ".projects[$gpi2].path" "$GLOBAL_CONFIG")
            proj_path=$(expand_path "$proj_path" "$GLOBAL_CONFIG_DIR")
            proj_claude_md=$(jq -r ".projects[$gpi2].claude_md // true" "$GLOBAL_CONFIG")

            if [[ ! -d "$proj_path" ]]; then
                echo -e "  ${YELLOW}Warning: Global project path not found, skipping: ${proj_path}${NC}" >&2
                continue
            fi

            CURRENT_SOURCE_PROJECT_DIRS+=("${proj_path}|${proj_claude_md}")
            echo -e "  ${GREEN}+project:${NC} $(basename "$proj_path") (global)" >&2
        done

        CURRENT_SOURCE_NAME=""
        write_source_manifest "global" "projects"
    fi

    # ── Global workspaces ──
    local global_ws_count
    global_ws_count=$(jq '.workspaces // [] | length' "$GLOBAL_CONFIG" 2>/dev/null || echo 0)
    if [[ "$global_ws_count" -gt 0 ]]; then
        local gwi
        for ((gwi = 0; gwi < global_ws_count; gwi++)); do
            local ws_json
            ws_json=$(jq -c ".workspaces[$gwi]" "$GLOBAL_CONFIG")
            process_workspace_source "$ws_json" "$GLOBAL_CONFIG_DIR"
        done
    fi
}

# Build orchestrator
build() {
    local force="${1:-false}"

    if ! _has_anything_to_build; then
        echo -e "${CYAN}No workspaces or resources configured. Nothing to build.${NC}" >&2
        return
    fi

    local ws_count
    ws_count=$(jq '.workspaces // [] | length' "$CONFIG_FILE")

    if [[ "$force" != "true" ]] && ! needs_rebuild; then
        echo -e "${GREEN}Workspace is up to date. Use --force to rebuild.${NC}" >&2
        return
    fi

    # Ensure compose output directory exists (must be before _acquire_lock which uses mkdir without -p)
    ensure_compose_dir

    # Acquire build lock to prevent concurrent builds
    if ! _acquire_lock "$COMPOSE_LOCK"; then
        echo -e "${YELLOW}Warning: Another build is in progress, skipping.${NC}" >&2
        return
    fi
    # Release lock on normal return; also chain into EXIT trap for abnormal exit (die_doctor, etc.)
    # shellcheck disable=SC2064
    trap '_release_lock "$COMPOSE_LOCK"; _BUILD_LOCK_HELD=false' RETURN
    _BUILD_LOCK_HELD=true

    echo -e "${BOLD}Building workspace...${NC}" >&2

    # Compute hash BEFORE build to avoid TOCTOU: if a source file changes during
    # build, the stored hash will reflect pre-build state, triggering rebuild next time.
    local pre_build_hash
    pre_build_hash=$(compute_build_hash)

    # Clean old resources from all sections
    local old_manifest
    old_manifest=$(read_manifest)
    # Transitional: clean old builtin symlinks from pre-plugin versions
    clean_manifest_section "$old_manifest" "builtin"
    clean_manifest_section "$old_manifest" "global"
    clean_manifest_section "$old_manifest" "workspaces"
    clean_manifest_section "$old_manifest" "resources"

    # Reset state
    PROCESSED_WORKSPACES=()
    MANIFEST_JSON='{"global":{},"workspaces":{},"resources":{}}'

    # Pre-scan direct project paths for "direct wins" dedup
    DIRECT_PROJECT_PATHS=()
    local _dp_count
    _dp_count=$(jq '.projects // [] | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    local _dpi
    for ((_dpi = 0; _dpi < _dp_count; _dpi++)); do
        local _dp_raw _dp_resolved
        _dp_raw=$(jq -r ".projects[$_dpi].path" "$CONFIG_FILE")
        _dp_resolved=$(expand_path "$_dp_raw" "$CONFIG_DIR")
        [[ -d "$_dp_resolved" ]] && DIRECT_PROJECT_PATHS+=("$_dp_resolved")
    done

    # Process global config (resources, workspaces)
    process_global

    # Process workspaces
    if [[ "$ws_count" -gt 0 ]]; then
        local bwi
        for ((bwi = 0; bwi < ws_count; bwi++)); do
            local ws_json
            ws_json=$(jq -c ".workspaces[$bwi]" "$CONFIG_FILE")
            process_workspace_source "$ws_json"
        done
    fi

    # Process local resources
    process_resources

    # Resolve plugins (GitHub + local) — workspace plugins already collected above
    resolve_plugins "$CONFIG_FILE" "$CONFIG_DIR"
    [[ -f "$GLOBAL_CONFIG" ]] && resolve_plugins "$GLOBAL_CONFIG" "$GLOBAL_CONFIG_DIR"
    _PLUGINS_RESOLVED=true

    # Write manifest and hash
    ensure_compose_dir
    atomic_write "$COMPOSE_MANIFEST" "$(jq '.' <<< "$MANIFEST_JSON")"
    atomic_write "$COMPOSE_HASH" "$pre_build_hash"

    # Ensure _warning in mcp.json
    if [[ -f "$COMPOSE_MCP" ]]; then
        local tmp
        tmp=$(jq '._warning = "This file is managed by claude-compose. Do not edit directly."' "$COMPOSE_MCP")
        atomic_write "$COMPOSE_MCP" "$tmp"
    fi

    echo "" >&2
    echo -e "${GREEN}Build complete.${NC}" >&2
}

# Explicit build subcommand
cmd_build() {
    require_jq

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}Error: ${CONFIG_FILE} not found${NC}" >&2
        die_doctor "Config file not found: ${CONFIG_FILE}"
    fi

    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        local json_err
        json_err=$(jq empty "$CONFIG_FILE" 2>&1 | head -5)
        echo -e "${RED}Error: Invalid JSON in ${CONFIG_FILE}${NC}" >&2
        die_doctor "Invalid JSON in ${CONFIG_FILE}: ${json_err}"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${BOLD}── Dry Run (build) ──${NC}" >&2
        echo "" >&2

        if ! _has_anything_to_build; then
            echo -e "${CYAN}No workspaces or resources configured. Nothing to build.${NC}" >&2
            return
        fi

        if has_builtin_plugin; then
            echo -e "${CYAN}Built-in plugin:${NC} ${BUILTIN_PLUGIN_DIR}" >&2
            echo "" >&2
        fi

        if [[ -f "$GLOBAL_CONFIG" ]]; then
            echo -e "${CYAN}Global config:${NC} ${GLOBAL_CONFIG}" >&2
            local gw_count ghr
            gw_count=$(jq '.workspaces // [] | length' "$GLOBAL_CONFIG" 2>/dev/null || echo 0)
            ghr=$(jq 'has("resources") and (.resources | length > 0)' "$GLOBAL_CONFIG" 2>/dev/null || echo false)
            [[ "$ghr" == "true" ]] && echo "  resources: yes" >&2
            [[ "$gw_count" -gt 0 ]] && echo "  workspaces: $gw_count" >&2
            echo "" >&2
        fi

        local ws_count
        ws_count=$(jq '.workspaces // [] | length' "$CONFIG_FILE")
        if [[ "$ws_count" -gt 0 ]]; then
            echo -e "${CYAN}Workspaces to sync:${NC}" >&2
            local drwi
            for ((drwi = 0; drwi < ws_count; drwi++)); do
                local ws_path
                ws_path=$(jq -r ".workspaces[$drwi].path" "$CONFIG_FILE")
                local ws_expanded
                ws_expanded=$(expand_path "$ws_path" "$CONFIG_DIR")
                if [[ -f "$ws_expanded" ]]; then
                    ws_expanded=$(dirname "$ws_expanded")
                fi
                if [[ -d "$ws_expanded" ]]; then
                    echo -e "  - $(basename "$ws_expanded") (${ws_expanded})" >&2
                else
                    echo -e "  - $ws_path ${RED}(not found)${NC}" >&2
                fi
            done
            echo "" >&2
        fi

        if needs_rebuild || [[ "$BUILD_FORCE" == true ]]; then
            echo -e "${YELLOW}Rebuild needed.${NC}" >&2
        else
            echo -e "${GREEN}Workspace is up to date.${NC}" >&2
        fi
        echo "" >&2
        echo -e "${GREEN}No mutations performed (dry run).${NC}" >&2
        return
    fi

    build "$BUILD_FORCE"
}
