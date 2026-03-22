# ── Process a single preset ─────────────────────────────────────────
process_preset() {
    local preset_name="$1"

    # Cycle detection
    for processed in "${PROCESSED_PRESETS[@]+"${PROCESSED_PRESETS[@]}"}"; do
        if [[ "$processed" == "$preset_name" ]]; then
            echo -e "${YELLOW}Warning: Preset already processed, skipping: ${preset_name}${NC}" >&2
            return
        fi
    done
    PROCESSED_PRESETS+=("$preset_name")

    local preset_dir="$PRESETS_DIR/$preset_name"
    if [[ ! -d "$preset_dir" ]]; then
        echo -e "${RED}Error: Preset not found: ${preset_name} (~/.claude-compose/presets/${preset_name}/)${NC}" >&2
        exit 1
    fi

    local preset_config="$preset_dir/claude-compose.json"
    if [[ ! -f "$preset_config" ]]; then
        if [[ -f "$preset_dir/preset.json" || -d "$preset_dir/.claude" ]]; then
            echo -e "${RED}Error: Preset '${preset_name}' uses old format (preset.json / .claude/ structure).${NC}" >&2
            echo -e "${RED}Migrate to claude-compose.json with explicit resources. See: claude-compose instructions${NC}" >&2
        else
            echo -e "${YELLOW}Warning: No claude-compose.json in preset: ${preset_name}${NC}" >&2
        fi
        return
    fi

    echo -e "${CYAN}Processing preset:${NC} ${preset_name}" >&2

    # Process resources with MCP prefixing, skip manifest (we write it below)
    process_resources "$preset_config" "$preset_dir" "$preset_name" \
        "presets" "$preset_name" "$preset_name" "true"

    # CLAUDE.md via --add-dir (process_resources resets arrays, so add_dirs is clean)
    local claude_md
    claude_md=$(jq -r '.claude_md // true' "$preset_config" 2>/dev/null || echo "true")
    if [[ "$claude_md" == "true" && -f "$preset_dir/CLAUDE.md" ]]; then
        CURRENT_SOURCE_ADD_DIRS+=("$preset_dir")
    fi

    # Collect preset's projects
    local preset_project_count
    preset_project_count=$(jq '.projects // [] | length' "$preset_config" 2>/dev/null || echo 0)
    if [[ "$preset_project_count" -gt 0 ]]; then
        for i in $(seq 0 $((preset_project_count - 1))); do
            local proj_path proj_claude_md
            proj_path=$(jq -r ".projects[$i].path" "$preset_config")
            proj_path=$(expand_path "$proj_path")
            proj_claude_md=$(jq -r ".projects[$i].claude_md // true" "$preset_config")

            if [[ ! -d "$proj_path" ]]; then
                echo -e "${YELLOW}Warning: Preset project path not found, skipping: ${proj_path}${NC}" >&2
                continue
            fi

            CURRENT_SOURCE_PROJECT_DIRS+=("${proj_path}|${proj_claude_md}")
            echo -e "  ${GREEN}+project:${NC} $(basename "$proj_path") (from preset)" >&2
        done
    fi

    # Write manifest entry (includes agents/skills/mcp from process_resources + add_dirs + project_dirs)
    write_source_manifest "presets" "$preset_name"

    # Recursively process nested presets
    local nested_presets
    nested_presets=$(jq -r '.presets // [] | .[]' "$preset_config" 2>/dev/null || true)
    while IFS= read -r nested; do
        [[ -z "$nested" ]] && continue
        process_preset "$nested"
    done <<< "$nested_presets"
}

# ── Process a single workspace source ───────────────────────────────
process_workspace_source() {
    local ws_json="$1"

    local raw_path
    raw_path=$(echo "$ws_json" | jq -r '.path')
    local ws_path
    ws_path=$(expand_path "$raw_path")

    if [[ ! -d "$ws_path" ]]; then
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
    filter_json=$(echo "$ws_json" | jq -c '{
        mcp: (.mcp // {}),
        agents: (.agents // {}),
        skills: (.skills // {}),
        claude_md: (if .claude_md == null then true else .claude_md end)
    }')

    # Sync resources (MCP, agents, skills — no permissions)
    sync_source_dir "$ws_path" "$filter_json" "$(basename "$ws_path")"

    # Collect workspace's own projects (from its claude-compose.json)
    if [[ -f "$ws_path/claude-compose.json" ]]; then
        local ws_project_count
        ws_project_count=$(jq '.projects // [] | length' "$ws_path/claude-compose.json" 2>/dev/null || echo 0)
        if [[ "$ws_project_count" -gt 0 ]]; then
            for i in $(seq 0 $((ws_project_count - 1))); do
                local proj_path proj_claude_md
                proj_path=$(jq -r ".projects[$i].path" "$ws_path/claude-compose.json")
                proj_path=$(expand_path "$proj_path")
                proj_claude_md=$(jq -r ".projects[$i].claude_md // true" "$ws_path/claude-compose.json")

                if [[ ! -d "$proj_path" ]]; then
                    continue
                fi

                CURRENT_SOURCE_PROJECT_DIRS+=("${proj_path}|${proj_claude_md}")
                echo -e "  ${GREEN}+project:${NC} $(basename "$proj_path") (from workspace)" >&2
            done
        fi
    fi

    # Write manifest — use path as key (workspaces don't have global names)
    write_source_manifest "workspaces" "$ws_path"
}

# ── Process resources from a config file ───────────────────────────
# Args: [config_file] [base_dir] [label] [manifest_section] [manifest_key] [source_name] [skip_manifest]
# Defaults preserve backward compatibility for local resources.
# source_name: if set, enables env var prefixing for MCP servers (used by presets)
# skip_manifest: if "true", caller handles write_source_manifest (used by presets)
process_resources() {
    local config_file="${1:-$CONFIG_FILE}"
    local base_dir="${2:-$PWD}"
    local label="${3:-local}"
    local manifest_section="${4:-resources}"
    local manifest_key="${5:-local}"
    local source_name="${6:-}"
    local skip_manifest="${7:-false}"

    local resources
    resources=$(jq -c '.resources // {}' "$config_file")
    if [[ "$resources" == "{}" || "$resources" == "null" ]]; then
        return
    fi

    echo -e "${CYAN}Processing ${label} resources${NC}" >&2

    # Reset tracking
    CURRENT_SOURCE_AGENTS=()
    CURRENT_SOURCE_SKILLS=()
    CURRENT_SOURCE_MCP_SERVERS=()
    CURRENT_SOURCE_ADD_DIRS=()
    CURRENT_SOURCE_PROJECT_DIRS=()

    # ── Symlink agents ──
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
        local agent_basename
        agent_basename=$(basename "$agent_path")
        mkdir -p ".claude/agents"
        if [[ -f ".claude/agents/${agent_basename}" || -L ".claude/agents/${agent_basename}" ]]; then
            echo -e "  ${YELLOW}overwrite:${NC} .claude/agents/${agent_basename}" >&2
        fi
        ln -sf "$abs_path" ".claude/agents/${agent_basename}"
        CURRENT_SOURCE_AGENTS+=("$agent_basename")
        echo -e "  ${GREEN}+agent:${NC} ${agent_basename} (${label})" >&2
    done <<< "$agents"

    # ── Symlink skills ──
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

    # ── Collect known env var names for MCP prefixing (when source_name is set) ──
    local _source_known_vars=""
    if [[ -n "$source_name" ]]; then
        local _src_env_files
        _src_env_files=$(jq -r '.resources.env_files // [] | .[]' "$config_file" 2>/dev/null || true)
        while IFS= read -r _ef; do
            [[ -z "$_ef" ]] && continue
            local _ef_abs="$base_dir/$_ef"
            [[ -f "$_ef_abs" ]] || continue
            _source_known_vars+=$(jq -r 'keys[]' "$_ef_abs" 2>/dev/null || true)
            _source_known_vars+=$'\n'
        done <<< "$_src_env_files"
    fi

    # ── Merge MCP servers ──
    local mcp_keys
    mcp_keys=$(jq -r '.resources.mcp // {} | keys[]' "$config_file" 2>/dev/null || true)
    while IFS= read -r server_name; do
        [[ -z "$server_name" ]] && continue
        local server_config
        server_config=$(jq -c --arg n "$server_name" '.resources.mcp[$n]' "$config_file")

        # Prefix env vars from source's env_files (when source_name is set)
        if [[ -n "$source_name" && -n "${_source_known_vars:-}" ]]; then
            local prefix
            prefix=$(compute_source_prefix "$source_name" "$base_dir")
            server_config=$(prefix_env_vars_in_mcp "$server_config" "$prefix" "$_source_known_vars")
        fi

        if [[ ! -f ".mcp.json" ]]; then
            echo '{"_warning":"This file is managed by claude-compose. Do not edit directly.","mcpServers":{}}' > ".mcp.json"
        fi

        local tmp
        tmp=$(jq --arg name "$server_name" --argjson config "$server_config" \
            '.mcpServers[$name] = $config' ".mcp.json")
        echo "$tmp" > ".mcp.json"

        CURRENT_SOURCE_MCP_SERVERS+=("$server_name")
        echo -e "  ${GREEN}+mcp:${NC} ${server_name} (${label})" >&2
    done <<< "$mcp_keys"

    if [[ "$skip_manifest" != "true" ]]; then
        write_source_manifest "$manifest_section" "$manifest_key"
    fi
}

# ── Sync built-in skills from ~/.claude-compose/skills/ ────────────
process_builtin_skills() {
    if [[ ! -d "$BUILTIN_SKILLS_DIR" ]]; then
        return
    fi

    local has_skills=false
    for skill_path in "$BUILTIN_SKILLS_DIR"/*/; do
        [[ -d "$skill_path" ]] || continue
        has_skills=true
        break
    done
    [[ "$has_skills" == true ]] || return

    echo -e "${CYAN}Processing built-in skills${NC}" >&2

    CURRENT_SOURCE_AGENTS=()
    CURRENT_SOURCE_SKILLS=()
    CURRENT_SOURCE_MCP_SERVERS=()
    CURRENT_SOURCE_ADD_DIRS=()
    CURRENT_SOURCE_PROJECT_DIRS=()

    mkdir -p ".claude/skills"
    for skill_path in "$BUILTIN_SKILLS_DIR"/*/; do
        [[ -d "$skill_path" ]] || continue
        local skill_name
        skill_name=$(basename "$skill_path")

        if [[ -L ".claude/skills/${skill_name}" || -d ".claude/skills/${skill_name}" ]]; then
            rm -f ".claude/skills/${skill_name}" 2>/dev/null || rm -rf ".claude/skills/${skill_name}"
        fi

        local abs_skill_path
        abs_skill_path=$(cd "$skill_path" && pwd -P)
        ln -sf "$abs_skill_path" ".claude/skills/${skill_name}"
        CURRENT_SOURCE_SKILLS+=("$skill_name")
        echo -e "  ${GREEN}+skill:${NC} ${skill_name} (built-in)" >&2
    done

    write_source_manifest "builtin" "skills"
}

# ── Process global config ────────────────────────────────────────────
process_global() {
    [[ ! -f "$GLOBAL_CONFIG" ]] && return

    echo -e "${CYAN}Processing global config${NC}" >&2

    # ── Global presets ──
    local global_preset_names
    global_preset_names=$(jq -r '.presets // [] | .[]' "$GLOBAL_CONFIG" 2>/dev/null || true)
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        process_preset "$name"
    done <<< "$global_preset_names"

    # ── Global direct resources (agents, skills, MCP) ──
    process_resources "$GLOBAL_CONFIG" "$GLOBAL_CONFIG_DIR" "global" "global" "resources"

    # ── Global projects (top-level, not inside resources) ──
    local global_project_count
    global_project_count=$(jq '.projects // [] | length' "$GLOBAL_CONFIG" 2>/dev/null || echo 0)
    if [[ "$global_project_count" -gt 0 ]]; then
        CURRENT_SOURCE_AGENTS=()
        CURRENT_SOURCE_SKILLS=()
        CURRENT_SOURCE_MCP_SERVERS=()
        CURRENT_SOURCE_ADD_DIRS=()
        CURRENT_SOURCE_PROJECT_DIRS=()

        for i in $(seq 0 $((global_project_count - 1))); do
            local proj_path proj_claude_md
            proj_path=$(jq -r ".projects[$i].path" "$GLOBAL_CONFIG")
            proj_path=$(expand_path "$proj_path")
            proj_claude_md=$(jq -r ".projects[$i].claude_md // true" "$GLOBAL_CONFIG")

            if [[ ! -d "$proj_path" ]]; then
                echo -e "  ${YELLOW}Warning: Global project path not found, skipping: ${proj_path}${NC}" >&2
                continue
            fi

            CURRENT_SOURCE_PROJECT_DIRS+=("${proj_path}|${proj_claude_md}")
            echo -e "  ${GREEN}+project:${NC} $(basename "$proj_path") (global)" >&2
        done

        write_source_manifest "global" "projects"
    fi

    # ── Global workspaces ──
    local global_ws_count
    global_ws_count=$(jq '.workspaces // [] | length' "$GLOBAL_CONFIG" 2>/dev/null || echo 0)
    if [[ "$global_ws_count" -gt 0 ]]; then
        for i in $(seq 0 $((global_ws_count - 1))); do
            local ws_json
            ws_json=$(jq -c ".workspaces[$i]" "$GLOBAL_CONFIG")
            process_workspace_source "$ws_json"
        done
    fi
}

# Build orchestrator
build() {
    local force="${1:-false}"

    local preset_count ws_count has_resources
    preset_count=$(jq '.presets // [] | length' "$CONFIG_FILE")
    ws_count=$(jq '.workspaces // [] | length' "$CONFIG_FILE")
    has_resources=$(jq 'has("resources") and (.resources | length > 0)' "$CONFIG_FILE")

    local has_builtin_skills=false
    if [[ -d "$BUILTIN_SKILLS_DIR" ]]; then
        for _d in "$BUILTIN_SKILLS_DIR"/*/; do
            [[ -d "$_d" ]] && has_builtin_skills=true && break
        done
    fi

    local has_global_config=false
    [[ -f "$GLOBAL_CONFIG" ]] && has_global_config=true

    if [[ "$preset_count" -eq 0 && "$ws_count" -eq 0 && "$has_resources" != "true" && "$has_builtin_skills" != "true" && "$has_global_config" != "true" ]]; then
        echo -e "${CYAN}No presets, workspaces, or resources configured. Nothing to build.${NC}" >&2
        return
    fi

    if [[ "$force" != "true" ]] && ! needs_rebuild; then
        echo -e "${GREEN}Workspace is up to date. Use --force to rebuild.${NC}" >&2
        return
    fi

    echo -e "${BOLD}Building workspace...${NC}" >&2

    # Clean old resources from all sections
    local old_manifest
    old_manifest=$(read_manifest)
    clean_manifest_section "$old_manifest" "builtin"
    clean_manifest_section "$old_manifest" "global"
    clean_manifest_section "$old_manifest" "presets"
    clean_manifest_section "$old_manifest" "workspaces"
    clean_manifest_section "$old_manifest" "resources"

    # Reset state
    PROCESSED_PRESETS=()
    PROCESSED_WORKSPACES=()
    MANIFEST_JSON='{"builtin":{},"global":{},"presets":{},"workspaces":{},"resources":{}}'

    # Process built-in skills (first — can be overridden by presets/resources)
    process_builtin_skills

    # Process global config (presets, resources, workspaces)
    process_global

    # Process presets
    local preset_names
    preset_names=$(jq -r '.presets // [] | .[]' "$CONFIG_FILE" 2>/dev/null || true)
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        process_preset "$name"
    done <<< "$preset_names"

    # Process workspaces
    if [[ "$ws_count" -gt 0 ]]; then
        for i in $(seq 0 $((ws_count - 1))); do
            local ws_json
            ws_json=$(jq -c ".workspaces[$i]" "$CONFIG_FILE")
            process_workspace_source "$ws_json"
        done
    fi

    # Process local resources (last — wins on conflict)
    process_resources

    # Write manifest and hash
    echo "$MANIFEST_JSON" | jq '.' > ".compose-manifest.json"
    compute_build_hash > ".compose-hash"

    # Ensure _warning in .mcp.json
    if [[ -f ".mcp.json" ]]; then
        local tmp
        tmp=$(jq '._warning = "This file is managed by claude-compose. Do not edit directly."' ".mcp.json")
        echo "$tmp" > ".mcp.json"
    fi

    echo "" >&2
    echo -e "${GREEN}Build complete.${NC}" >&2
}

# Explicit build subcommand
cmd_build() {
    require_jq

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}Error: ${CONFIG_FILE} not found${NC}" >&2
        exit 1
    fi

    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        echo -e "${RED}Error: Invalid JSON in ${CONFIG_FILE}${NC}" >&2
        exit 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${BOLD}── Dry Run (build) ──${NC}" >&2
        echo "" >&2

        local preset_count ws_count has_resources
        preset_count=$(jq '.presets // [] | length' "$CONFIG_FILE")
        ws_count=$(jq '.workspaces // [] | length' "$CONFIG_FILE")
        has_resources=$(jq 'has("resources") and (.resources | length > 0)' "$CONFIG_FILE")

        local has_builtin_skills_dr=false
        if [[ -d "$BUILTIN_SKILLS_DIR" ]]; then
            for _d in "$BUILTIN_SKILLS_DIR"/*/; do
                [[ -d "$_d" ]] && has_builtin_skills_dr=true && break
            done
        fi

        local has_global_dr=false
        [[ -f "$GLOBAL_CONFIG" ]] && has_global_dr=true

        if [[ "$preset_count" -eq 0 && "$ws_count" -eq 0 && "$has_resources" != "true" && "$has_builtin_skills_dr" != "true" && "$has_global_dr" != "true" ]]; then
            echo -e "${CYAN}No presets, workspaces, or resources configured. Nothing to build.${NC}" >&2
            return
        fi

        if [[ "$has_builtin_skills_dr" == true ]]; then
            echo -e "${CYAN}Built-in skills:${NC}" >&2
            for _d in "$BUILTIN_SKILLS_DIR"/*/; do
                [[ -d "$_d" ]] || continue
                echo -e "  - $(basename "$_d")" >&2
            done
            echo "" >&2
        fi

        if [[ "$has_global_dr" == true ]]; then
            echo -e "${CYAN}Global config:${NC} ${GLOBAL_CONFIG}" >&2
            local gp_count gw_count ghr
            gp_count=$(jq '.presets // [] | length' "$GLOBAL_CONFIG" 2>/dev/null || echo 0)
            gw_count=$(jq '.workspaces // [] | length' "$GLOBAL_CONFIG" 2>/dev/null || echo 0)
            ghr=$(jq 'has("resources") and (.resources | length > 0)' "$GLOBAL_CONFIG" 2>/dev/null || echo false)
            [[ "$gp_count" -gt 0 ]] && echo "  presets: $gp_count" >&2
            [[ "$ghr" == "true" ]] && echo "  resources: yes" >&2
            [[ "$gw_count" -gt 0 ]] && echo "  workspaces: $gw_count" >&2
            echo "" >&2
        fi

        if [[ "$preset_count" -gt 0 ]]; then
            echo -e "${CYAN}Presets to process:${NC}" >&2
            jq -r '.presets // [] | .[]' "$CONFIG_FILE" | while read -r name; do
                local preset_dir="$PRESETS_DIR/$name"
                if [[ -d "$preset_dir" ]]; then
                    echo -e "  - $name (${preset_dir})" >&2
                    if [[ -f "$preset_dir/claude-compose.json" ]]; then
                        local pa ps pm
                        pa=$(jq '.resources.agents // [] | length' "$preset_dir/claude-compose.json" 2>/dev/null || echo 0)
                        ps=$(jq '.resources.skills // [] | length' "$preset_dir/claude-compose.json" 2>/dev/null || echo 0)
                        pm=$(jq '.resources.mcp // {} | length' "$preset_dir/claude-compose.json" 2>/dev/null || echo 0)
                        [[ "$pa" -gt 0 ]] && echo "    agents: $pa" >&2
                        [[ "$ps" -gt 0 ]] && echo "    skills: $ps" >&2
                        [[ "$pm" -gt 0 ]] && echo "    mcp: $pm" >&2
                    else
                        echo "    (no claude-compose.json)" >&2
                    fi
                    [[ -f "$preset_dir/CLAUDE.md" ]] && echo "    CLAUDE.md: yes" >&2
                else
                    echo -e "  - $name ${RED}(not found)${NC}" >&2
                fi
            done
            echo "" >&2
        fi

        if [[ "$ws_count" -gt 0 ]]; then
            echo -e "${CYAN}Workspaces to sync:${NC}" >&2
            for i in $(seq 0 $((ws_count - 1))); do
                local ws_path
                ws_path=$(jq -r ".workspaces[$i].path" "$CONFIG_FILE")
                local ws_expanded
                ws_expanded=$(expand_path "$ws_path")
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
