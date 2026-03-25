# Extract filter JSON from a preset entry (object with optional agents/skills/mcp fields)
# $1 = preset entry JSON
# Prints: filter JSON (or '{}' if no filters)
extract_preset_filters() {
    local entry="$1"
    local result
    result=$(echo "$entry" | jq -c '{
        agents: (if has("agents") then .agents else null end),
        skills: (if has("skills") then .skills else null end),
        mcp: (if has("mcp") then .mcp else null end)
    } | with_entries(select(.value != null))')
    if [[ -z "$result" || "$result" == "null" ]]; then
        echo '{}'
    else
        echo "$result"
    fi
}

# ── Process a single preset ─────────────────────────────────────────
process_preset() {
    local preset_name="$1"
    local filter_json="${2:-{}}"

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
        die_doctor "Preset not found: ${preset_name} (expected at ~/.claude-compose/presets/${preset_name}/)"
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

    # Local presets don't use prefix/rename
    CURRENT_PRESET_PREFIX=""
    CURRENT_PRESET_RENAME='{}'

    # Recursively process nested presets FIRST (so own resources override nested ones)
    local nested_count
    nested_count=$(jq '.presets // [] | length' "$preset_config" 2>/dev/null || echo 0)
    local ni
    for ((ni = 0; ni < nested_count; ni++)); do
        local nested_type
        nested_type=$(jq -r ".presets[$ni] | type" "$preset_config" 2>/dev/null || echo "null")
        if [[ "$nested_type" == "string" ]]; then
            local nested_name
            nested_name=$(jq -r ".presets[$ni]" "$preset_config")
            [[ -z "$nested_name" ]] && continue
            if [[ "$nested_name" == *..* || "$nested_name" == */* ]]; then
                echo -e "${YELLOW}Warning: Invalid nested preset name '${nested_name}', skipping${NC}" >&2
                continue
            fi
            # String entry inherits parent's filter unchanged
            process_preset "$nested_name" "$filter_json"
        elif [[ "$nested_type" == "object" ]]; then
            local nested_json
            nested_json=$(jq -c ".presets[$ni]" "$preset_config")
            local nested_source
            nested_source=$(echo "$nested_json" | jq -r '.source // empty')
            local nested_name_field
            nested_name_field=$(echo "$nested_json" | jq -r '.name // empty')

            # Extract child filters and merge with inherited
            local child_filter merged_filter
            child_filter=$(extract_preset_filters "$nested_json")
            merged_filter=$(merge_preset_filters "$filter_json" "$child_filter")

            if [[ -n "$nested_source" && "$nested_source" == github:* ]]; then
                # Rebuild entry_json with merged filters for process_github_preset
                local patched_entry
                patched_entry=$(echo "$nested_json" | jq --argjson f "$merged_filter" '
                    del(.agents, .skills, .mcp) +
                    (if ($f.agents // null) != null then {agents: $f.agents} else {} end) +
                    (if ($f.skills // null) != null then {skills: $f.skills} else {} end) +
                    (if ($f.mcp // null) != null then {mcp: $f.mcp} else {} end)')
                process_github_preset "$patched_entry"
            elif [[ -n "$nested_name_field" ]]; then
                # Local preset with filters
                process_preset "$nested_name_field" "$merged_filter"
            fi
        fi
    done

    # Reset prefix/rename after nested recursion (may have been clobbered by nested github presets)
    CURRENT_PRESET_PREFIX=""
    CURRENT_PRESET_RENAME='{}'

    # process_resources: config_file base_dir label manifest_section manifest_key source_name skip_manifest filter_json
    process_resources "$preset_config" "$preset_dir" "$preset_name" \
        "presets" "$preset_name" "$preset_name" "true" "$filter_json"

    # CLAUDE.md via --add-dir (process_resources always resets arrays, even on early return)
    local claude_md
    claude_md=$(jq -r '.claude_md // true' "$preset_config" 2>/dev/null || echo "true")
    if [[ "$claude_md" == "true" && -f "$preset_dir/CLAUDE.md" ]]; then
        CURRENT_SOURCE_ADD_DIRS+=("$preset_dir")
    fi

    # Collect preset's projects
    local preset_project_count
    preset_project_count=$(jq '.projects // [] | length' "$preset_config" 2>/dev/null || echo 0)
    if [[ "$preset_project_count" -gt 0 ]]; then
        local ppi
        for ((ppi = 0; ppi < preset_project_count; ppi++)); do
            local proj_path proj_claude_md
            proj_path=$(jq -r ".projects[$ppi].path" "$preset_config")
            proj_path=$(expand_path "$proj_path")
            proj_claude_md=$(jq -r ".projects[$ppi].claude_md // true" "$preset_config")

            if [[ ! -d "$proj_path" ]]; then
                echo -e "${YELLOW}Warning: Preset project path not found, skipping: ${proj_path}${NC}" >&2
                continue
            fi

            CURRENT_SOURCE_PROJECT_DIRS+=("${proj_path}|${proj_claude_md}")
            echo -e "  ${GREEN}+project:${NC} $(basename "$proj_path") (from preset)" >&2
        done
    fi

    # Write manifest entry (includes agents/skills/mcp from process_resources + add_dirs + project_dirs)
    CURRENT_SOURCE_NAME="$preset_name"
    write_source_manifest "presets" "$preset_name"
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
            local wpi
            for ((wpi = 0; wpi < ws_project_count; wpi++)); do
                local proj_path proj_claude_md
                proj_path=$(jq -r ".projects[$wpi].path" "$ws_path/claude-compose.json")
                proj_path=$(expand_path "$proj_path")
                proj_claude_md=$(jq -r ".projects[$wpi].claude_md // true" "$ws_path/claude-compose.json")

                if [[ ! -d "$proj_path" ]]; then
                    continue
                fi

                CURRENT_SOURCE_PROJECT_DIRS+=("${proj_path}|${proj_claude_md}")
                echo -e "  ${GREEN}+project:${NC} $(basename "$proj_path") (from workspace)" >&2
            done
        fi
    fi

    # Write manifest — use path as key (workspaces don't have global names)
    CURRENT_SOURCE_NAME="$(basename "$ws_path")"
    write_source_manifest "workspaces" "$ws_path"
}

# ── Process resources from a config file ───────────────────────────
# Args: [config_file] [base_dir] [label] [manifest_section] [manifest_key] [source_name] [skip_manifest] [filter_json]
# Defaults preserve backward compatibility for local resources.
# source_name: if set, enables env var prefixing for MCP servers (used by presets)
# skip_manifest: if "true", caller handles write_source_manifest (used by presets)
# filter_json: preset filter JSON with agents/skills/mcp include/exclude (default '{}')
process_resources() {
    local config_file="${1:-$CONFIG_FILE}"
    local base_dir="${2:-$PWD}"
    local label="${3:-local}"
    local manifest_section="${4:-resources}"
    local manifest_key="${5:-local}"
    local source_name="${6:-}"
    local skip_manifest="${7:-false}"
    local filter_json="${8:-{}}"

    # Set source_name for manifest tracking (used by env var prefixing at launch time)
    CURRENT_SOURCE_NAME="$source_name"

    # Reset tracking (must happen before early return so callers see clean arrays)
    CURRENT_SOURCE_AGENTS=()
    CURRENT_SOURCE_SKILLS=()
    CURRENT_SOURCE_MCP_SERVERS=()
    CURRENT_SOURCE_ADD_DIRS=()
    CURRENT_SOURCE_PROJECT_DIRS=()

    local resources
    resources=$(jq -c '.resources // {}' "$config_file")
    if [[ "$resources" == "{}" || "$resources" == "null" ]]; then
        return
    fi

    echo -e "${CYAN}Processing ${label} resources${NC}" >&2

    # Parse filter JSON for include/exclude lists
    local pr_agents_include pr_agents_exclude pr_skills_include pr_skills_exclude pr_mcp_include pr_mcp_exclude
    pr_agents_include=$(echo "$filter_json" | jq -c '.agents.include // ["*"]')
    pr_agents_exclude=$(echo "$filter_json" | jq -c '.agents.exclude // []')
    pr_skills_include=$(echo "$filter_json" | jq -c '.skills.include // ["*"]')
    pr_skills_exclude=$(echo "$filter_json" | jq -c '.skills.exclude // []')
    pr_mcp_include=$(echo "$filter_json" | jq -c '.mcp.include // ["*"]')
    pr_mcp_exclude=$(echo "$filter_json" | jq -c '.mcp.exclude // []')

    # ── Sync agents (symlink or copy+rename) ──
    local agents
    agents=$(jq -r '.resources.agents // [] | .[]' "$config_file" 2>/dev/null || true)
    while IFS= read -r agent_path; do
        [[ -z "$agent_path" ]] && continue
        if _has_path_traversal "$agent_path"; then
            echo -e "  ${YELLOW}Warning: agent path contains traversal, skipping: ${agent_path}${NC}" >&2
            continue
        fi
        local abs_path="$base_dir/$agent_path"
        if [[ ! -f "$abs_path" ]]; then
            echo -e "  ${YELLOW}Warning: agent not found: ${agent_path}${NC}" >&2
            continue
        fi
        abs_path=$(cd "$(dirname "$abs_path")" && pwd -P)/$(basename "$abs_path")
        local agent_basename
        agent_basename=$(basename "$agent_path")
        local name_no_ext="${agent_basename%.md}"
        if ! matches_filter "$name_no_ext" "$pr_agents_include" "$pr_agents_exclude"; then continue; fi
        # Apply prefix/rename if active
        local final_name="$name_no_ext"
        if [[ -n "$CURRENT_PRESET_PREFIX" || "$CURRENT_PRESET_RENAME" != '{}' ]]; then
            final_name=$(apply_resource_prefix "$name_no_ext" "$CURRENT_PRESET_PREFIX" "$CURRENT_PRESET_RENAME")
        fi
        local final_agent="${final_name}.md"
        mkdir -p ".claude/agents"
        if [[ -f ".claude/agents/${final_agent}" || -L ".claude/agents/${final_agent}" ]]; then
            echo -e "  ${YELLOW}overwrite:${NC} .claude/agents/${final_agent}" >&2
        fi
        if [[ "$final_name" != "$name_no_ext" ]]; then
            # Name changed — copy and rewrite name: in frontmatter (Claude CLI reads it)
            rewrite_frontmatter_name "$abs_path" ".claude/agents/${final_agent}" "$final_name"
        else
            ln -sf "$abs_path" ".claude/agents/${final_agent}"
        fi
        CURRENT_SOURCE_AGENTS+=("$final_agent")
        if [[ "$final_name" != "$name_no_ext" ]]; then
            echo -e "  ${GREEN}+agent:${NC} ${name_no_ext} → ${final_name} (${label})" >&2
        else
            echo -e "  ${GREEN}+agent:${NC} ${name_no_ext} (${label})" >&2
        fi
    done <<< "$agents"

    # ── Sync skills (symlink or copy+rename) ──
    local skills
    skills=$(jq -r '.resources.skills // [] | .[]' "$config_file" 2>/dev/null || true)
    while IFS= read -r skill_path; do
        [[ -z "$skill_path" ]] && continue
        if _has_path_traversal "$skill_path"; then
            echo -e "  ${YELLOW}Warning: skill path contains traversal, skipping: ${skill_path}${NC}" >&2
            continue
        fi
        local abs_path="$base_dir/$skill_path"
        if [[ ! -d "$abs_path" ]]; then
            echo -e "  ${YELLOW}Warning: skill not found: ${skill_path}${NC}" >&2
            continue
        fi
        abs_path=$(cd "$abs_path" && pwd -P)
        local skill_basename
        skill_basename=$(basename "$skill_path")
        if ! matches_filter "$skill_basename" "$pr_skills_include" "$pr_skills_exclude"; then continue; fi
        # Apply prefix/rename if active
        local final_skill="$skill_basename"
        if [[ -n "$CURRENT_PRESET_PREFIX" || "$CURRENT_PRESET_RENAME" != '{}' ]]; then
            final_skill=$(apply_resource_prefix "$skill_basename" "$CURRENT_PRESET_PREFIX" "$CURRENT_PRESET_RENAME")
        fi
        mkdir -p ".claude/skills"
        if [[ -L ".claude/skills/${final_skill}" || -d ".claude/skills/${final_skill}" ]]; then
            echo -e "  ${YELLOW}overwrite:${NC} .claude/skills/${final_skill}/" >&2
            rm -f ".claude/skills/${final_skill}" 2>/dev/null || rm -rf ".claude/skills/${final_skill}"
        fi
        if [[ "$final_skill" != "$skill_basename" ]]; then
            # Name changed — copy dir and rewrite name: in SKILL.md
            cp -R "$abs_path" ".claude/skills/${final_skill}"
            if [[ -f ".claude/skills/${final_skill}/SKILL.md" ]]; then
                local tmp_skill
                tmp_skill=$(mktemp ".claude/skills/${final_skill}/SKILL.md.XXXXXX")
                rewrite_frontmatter_name ".claude/skills/${final_skill}/SKILL.md" "$tmp_skill" "$final_skill"
                mv "$tmp_skill" ".claude/skills/${final_skill}/SKILL.md"
            fi
        else
            ln -sf "$abs_path" ".claude/skills/${final_skill}"
        fi
        CURRENT_SOURCE_SKILLS+=("$final_skill")
        if [[ "$final_skill" != "$skill_basename" ]]; then
            echo -e "  ${GREEN}+skill:${NC} ${skill_basename} → ${final_skill} (${label})" >&2
        else
            echo -e "  ${GREEN}+skill:${NC} ${skill_basename} (${label})" >&2
        fi
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
    if [[ ! -f ".mcp.json" ]]; then
        atomic_write ".mcp.json" "$_MCP_EMPTY"
    fi

    local mcp_batch='{}'
    local mcp_keys
    mcp_keys=$(jq -r '.resources.mcp // {} | keys[]' "$config_file" 2>/dev/null || true)
    while IFS= read -r server_name; do
        [[ -z "$server_name" ]] && continue
        if ! matches_filter "$server_name" "$pr_mcp_include" "$pr_mcp_exclude"; then continue; fi
        local server_config
        server_config=$(jq -c --arg n "$server_name" '.resources.mcp[$n]' "$config_file")

        # Prefix env vars from source's env_files (when source_name is set)
        if [[ -n "$source_name" && -n "${_source_known_vars:-}" ]]; then
            local env_prefix
            env_prefix=$(compute_source_prefix "$source_name" "$base_dir")
            server_config=$(prefix_env_vars_in_mcp "$server_config" "$env_prefix" "$_source_known_vars")
        fi

        # Apply resource prefix/rename to server name
        local final_server="$server_name"
        if [[ -n "$CURRENT_PRESET_PREFIX" || "$CURRENT_PRESET_RENAME" != '{}' ]]; then
            final_server=$(apply_resource_prefix "$server_name" "$CURRENT_PRESET_PREFIX" "$CURRENT_PRESET_RENAME")
        fi

        mcp_batch=$(echo "$mcp_batch" | jq --arg name "$final_server" --argjson config "$server_config" '.[$name] = $config')

        CURRENT_SOURCE_MCP_SERVERS+=("$final_server")
        if [[ "$final_server" != "$server_name" ]]; then
            echo -e "  ${GREEN}+mcp:${NC} ${server_name} → ${final_server} (${label})" >&2
        else
            echo -e "  ${GREEN}+mcp:${NC} ${server_name} (${label})" >&2
        fi
    done <<< "$mcp_keys"

    if [[ "$mcp_batch" != '{}' ]]; then
        local overwrites
        overwrites=$(jq -r --argjson batch "$mcp_batch" \
            '[.mcpServers // {} | keys[] as $k | select($batch | has($k)) | $k] | .[]' \
            ".mcp.json" 2>/dev/null || true)
        while IFS= read -r ow; do
            [[ -z "$ow" ]] && continue
            echo -e "  ${YELLOW}overwrite mcp:${NC} $ow" >&2
        done <<< "$overwrites"
        local tmp
        tmp=$(jq --argjson batch "$mcp_batch" '.mcpServers += $batch' ".mcp.json")
        atomic_write ".mcp.json" "$tmp"
    fi

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

    CURRENT_SOURCE_NAME=""
    write_source_manifest "builtin" "skills"
}

# ── Process global config ────────────────────────────────────────────
process_global() {
    [[ ! -f "$GLOBAL_CONFIG" ]] && return

    echo -e "${CYAN}Processing global config${NC}" >&2

    # ── Global presets (handles mixed arrays) ──
    # shellcheck disable=SC2329
    _global_preset_cb() {
        local etype="$1" _idx="$2" name="$3" source="$4" is_gh="$5" ejson="$6"
        if [[ "$etype" == "string" ]]; then
            process_preset "$name"
        elif [[ "$is_gh" == "true" ]]; then
            process_github_preset "$ejson"
        elif [[ -n "$name" ]]; then
            local filter; filter=$(extract_preset_filters "$ejson")
            process_preset "$name" "$filter"
        fi
    }
    iterate_presets "$GLOBAL_CONFIG" _global_preset_cb

    # process_resources: config_file base_dir label manifest_section manifest_key source_name skip_manifest filter_json
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

        local gpi2
        for ((gpi2 = 0; gpi2 < global_project_count; gpi2++)); do
            local proj_path proj_claude_md
            proj_path=$(jq -r ".projects[$gpi2].path" "$GLOBAL_CONFIG")
            proj_path=$(expand_path "$proj_path")
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
            process_workspace_source "$ws_json"
        done
    fi
}

# ── Process a GitHub preset ─────────────────────────────────────────
process_github_preset() {
    local entry_json="$1"

    local source
    source=$(echo "$entry_json" | jq -r '.source')
    local prefix
    prefix=$(echo "$entry_json" | jq -r '.prefix // empty')
    local rename_json
    rename_json=$(echo "$entry_json" | jq -c '.rename // {}')
    # Parse source
    parse_github_source "$source"
    local owner="$_GH_OWNER" repo="$_GH_REPO" preset_path="$_GH_PATH" spec_str="$_GH_SPEC"

    # Build source_key
    local source_key="github:${owner}/${repo}"
    [[ -n "$preset_path" ]] && source_key+="/${preset_path}"

    # Cycle detection
    for processed in "${PROCESSED_PRESETS[@]+"${PROCESSED_PRESETS[@]}"}"; do
        if [[ "$processed" == "$source_key" ]]; then
            echo -e "${YELLOW}Warning: GitHub preset already processed, skipping: ${source_key}${NC}" >&2
            return
        fi
    done
    PROCESSED_PRESETS+=("$source_key")

    require_git

    echo -e "${CYAN}Processing GitHub preset:${NC} ${source_key}" >&2

    # Resolve version
    local resolved_info resolved_version
    resolved_info=$(resolve_github_version "$owner" "$repo" "$source_key" "$spec_str")
    read -r resolved_version _ <<< "$resolved_info"

    # Get preset directory
    local preset_dir
    preset_dir=$(registry_preset_dir "$owner" "$repo" "$resolved_version" "$preset_path")

    if [[ ! -d "$preset_dir" ]]; then
        echo -e "${RED}Error: Preset directory not found in registry: ${preset_dir}${NC}" >&2
        die_doctor "Preset directory not found in registry: ${preset_dir}. Try running: claude-compose update"
    fi

    local preset_config="$preset_dir/claude-compose.json"
    if [[ ! -f "$preset_config" ]]; then
        echo -e "${YELLOW}Warning: No claude-compose.json in GitHub preset: ${source_key}${NC}" >&2
        return
    fi

    # Compute stable source_name (without version) for env var prefixing
    local source_name
    source_name="${owner}_${repo}"
    [[ -n "$preset_path" ]] && source_name+="_${preset_path}"
    # If prefix is set, use it for more readable env var names
    if [[ -n "$prefix" ]]; then
        source_name="$prefix"
    fi

    # Extract filters from entry_json
    local filter_json
    filter_json=$(extract_preset_filters "$entry_json")

    # Save prefix/rename to locals for later use by process_resources
    local my_prefix="$prefix"
    local my_rename="$rename_json"

    # Reset globals before nested recursion (nested presets manage their own)
    CURRENT_PRESET_PREFIX=""
    CURRENT_PRESET_RENAME='{}'

    # Recursively process nested presets FIRST (so own resources override nested ones)
    local nested_count
    nested_count=$(jq '.presets // [] | length' "$preset_config" 2>/dev/null || echo 0)
    local ni
    for ((ni = 0; ni < nested_count; ni++)); do
        local nested_type
        nested_type=$(jq -r ".presets[$ni] | type" "$preset_config" 2>/dev/null || echo "null")
        if [[ "$nested_type" == "string" ]]; then
            local nested_name
            nested_name=$(jq -r ".presets[$ni]" "$preset_config")
            [[ -z "$nested_name" ]] && continue
            if [[ "$nested_name" == *..* || "$nested_name" == */* ]]; then
                echo -e "${YELLOW}Warning: Invalid nested preset name '${nested_name}', skipping${NC}" >&2
                continue
            fi
            # Local presets within a github registry resolve relative to registry root
            local reg_root
            reg_root=$(registry_version_dir "$owner" "$repo" "$resolved_version")
            if [[ -d "$reg_root/$nested_name" ]]; then
                # Treat as another github preset from same repo — inherit filter
                local nested_entry
                nested_entry=$(jq -n --arg s "github:${owner}/${repo}/${nested_name}@${resolved_version}" \
                    --argjson f "$filter_json" \
                    '{source: $s} +
                    (if ($f.agents // null) != null then {agents: $f.agents} else {} end) +
                    (if ($f.skills // null) != null then {skills: $f.skills} else {} end) +
                    (if ($f.mcp // null) != null then {mcp: $f.mcp} else {} end)')
                process_github_preset "$nested_entry"
            else
                process_preset "$nested_name" "$filter_json"
            fi
        elif [[ "$nested_type" == "object" ]]; then
            local nested_json
            nested_json=$(jq -c ".presets[$ni]" "$preset_config")
            local nested_source
            nested_source=$(echo "$nested_json" | jq -r '.source // empty')
            local nested_name_field
            nested_name_field=$(echo "$nested_json" | jq -r '.name // empty')

            # Extract child filters and merge with inherited
            local child_filter merged_filter
            child_filter=$(extract_preset_filters "$nested_json")
            merged_filter=$(merge_preset_filters "$filter_json" "$child_filter")

            if [[ -n "$nested_source" && "$nested_source" == github:* ]]; then
                # Rebuild entry_json with merged filters for process_github_preset
                local patched_entry
                patched_entry=$(echo "$nested_json" | jq --argjson f "$merged_filter" '
                    del(.agents, .skills, .mcp) +
                    (if ($f.agents // null) != null then {agents: $f.agents} else {} end) +
                    (if ($f.skills // null) != null then {skills: $f.skills} else {} end) +
                    (if ($f.mcp // null) != null then {mcp: $f.mcp} else {} end)')
                process_github_preset "$patched_entry"
            elif [[ -n "$nested_name_field" ]]; then
                # Local preset with filters
                process_preset "$nested_name_field" "$merged_filter"
            fi
        fi
    done

    # Restore prefix/rename for own resource processing
    CURRENT_PRESET_PREFIX="$my_prefix"
    CURRENT_PRESET_RENAME="$my_rename"

    # process_resources: config_file base_dir label manifest_section manifest_key source_name skip_manifest filter_json
    process_resources "$preset_config" "$preset_dir" "$source_key" \
        "presets" "$source_key" "$source_name" "true" "$filter_json"

    # CLAUDE.md via --add-dir
    local claude_md
    claude_md=$(jq -r '.claude_md // true' "$preset_config" 2>/dev/null || echo "true")
    if [[ "$claude_md" == "true" && -f "$preset_dir/CLAUDE.md" ]]; then
        CURRENT_SOURCE_ADD_DIRS+=("$preset_dir")
    fi

    # Collect preset's projects
    local preset_project_count
    preset_project_count=$(jq '.projects // [] | length' "$preset_config" 2>/dev/null || echo 0)
    if [[ "$preset_project_count" -gt 0 ]]; then
        local pi
        for ((pi = 0; pi < preset_project_count; pi++)); do
            local proj_path proj_claude_md
            proj_path=$(jq -r ".projects[$pi].path" "$preset_config")
            proj_path=$(expand_path "$proj_path")
            proj_claude_md=$(jq -r ".projects[$pi].claude_md // true" "$preset_config")

            if [[ ! -d "$proj_path" ]]; then
                echo -e "${YELLOW}Warning: GitHub preset project path not found, skipping: ${proj_path}${NC}" >&2
                continue
            fi

            CURRENT_SOURCE_PROJECT_DIRS+=("${proj_path}|${proj_claude_md}")
            echo -e "  ${GREEN}+project:${NC} $(basename "$proj_path") (from github preset)" >&2
        done
    fi

    # Write manifest entry
    CURRENT_SOURCE_NAME="$source_name"
    write_source_manifest "presets" "$source_key"

    # Reset prefix/rename to prevent leaking to caller
    CURRENT_PRESET_PREFIX=""
    CURRENT_PRESET_RENAME='{}'
}

# ── Apply resource prefix/rename ──────────────────────────────────────
# $1 = original name, $2 = prefix, $3 = rename JSON object
# Prints the final name
apply_resource_prefix() {
    local name="$1" prefix="$2" rename_json="$3"

    # Check rename map first
    local renamed
    renamed=$(echo "$rename_json" | jq -r --arg n "$name" '.[$n] // empty')
    if [[ -n "$renamed" ]]; then
        echo "$renamed"
        return
    fi

    # Apply prefix
    if [[ -n "$prefix" ]]; then
        echo "${prefix}-${name}"
    else
        echo "$name"
    fi
}

# Iterate over a presets array in a config file, calling a callback for each entry.
# $1 = config file path
# $2 = callback function name
# Callback receives: entry_type index name source is_github entry_json config_file
# shellcheck disable=SC2329
iterate_presets() {
    local config_file="$1" callback="$2"
    [[ ! -f "$config_file" ]] && return
    local count
    count=$(jq '.presets // [] | length' "$config_file" 2>/dev/null || echo 0)
    local i
    for ((i = 0; i < count; i++)); do
        local entry_type
        entry_type=$(jq -r ".presets[$i] | type" "$config_file" 2>/dev/null || echo "null")
        if [[ "$entry_type" == "string" ]]; then
            local name
            name=$(jq -r ".presets[$i]" "$config_file")
            [[ -z "$name" ]] && continue
            "$callback" "string" "$i" "$name" "" "false" '{}' "$config_file"
        elif [[ "$entry_type" == "object" ]]; then
            local entry_json source_val name_val is_github="false"
            entry_json=$(jq -c ".presets[$i]" "$config_file")
            source_val=$(echo "$entry_json" | jq -r '.source // empty')
            name_val=$(echo "$entry_json" | jq -r '.name // empty')
            [[ -n "$source_val" && "$source_val" == github:* ]] && is_github="true"
            "$callback" "object" "$i" "$name_val" "$source_val" "$is_github" "$entry_json" "$config_file"
        fi
    done
}

# Build orchestrator
build() {
    local force="${1:-false}"

    local preset_count ws_count has_resources
    preset_count=$(jq '.presets // [] | length' "$CONFIG_FILE")
    ws_count=$(jq '.workspaces // [] | length' "$CONFIG_FILE")
    has_resources=$(jq 'has("resources") and (.resources | length > 0)' "$CONFIG_FILE")

    local has_global_config=false
    [[ -f "$GLOBAL_CONFIG" ]] && has_global_config=true

    if [[ "$preset_count" -eq 0 && "$ws_count" -eq 0 && "$has_resources" != "true" && "$has_global_config" != "true" ]] && ! has_builtin_skills; then
        echo -e "${CYAN}No presets, workspaces, or resources configured. Nothing to build.${NC}" >&2
        return
    fi

    if [[ "$force" != "true" ]] && ! needs_rebuild; then
        echo -e "${GREEN}Workspace is up to date. Use --force to rebuild.${NC}" >&2
        return
    fi

    # Acquire build lock to prevent concurrent builds
    if ! _acquire_lock ".compose-build.lock"; then
        echo -e "${YELLOW}Warning: Another build is in progress, skipping.${NC}" >&2
        return
    fi
    # Release lock on normal return; also chain into EXIT trap for abnormal exit (die_doctor, etc.)
    # shellcheck disable=SC2064
    trap '_release_lock ".compose-build.lock"; _BUILD_LOCK_HELD=false' RETURN
    _BUILD_LOCK_HELD=true

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

    # Process presets (handles mixed arrays)
    # shellcheck disable=SC2329
    _build_preset_cb() {
        local etype="$1" _idx="$2" name="$3" source="$4" is_gh="$5" ejson="$6"
        if [[ "$etype" == "string" ]]; then
            process_preset "$name"
        elif [[ "$is_gh" == "true" ]]; then
            process_github_preset "$ejson"
        elif [[ -n "$name" ]]; then
            local filter; filter=$(extract_preset_filters "$ejson")
            process_preset "$name" "$filter"
        fi
    }
    iterate_presets "$CONFIG_FILE" _build_preset_cb

    # Process workspaces
    if [[ "$ws_count" -gt 0 ]]; then
        local bwi
        for ((bwi = 0; bwi < ws_count; bwi++)); do
            local ws_json
            ws_json=$(jq -c ".workspaces[$bwi]" "$CONFIG_FILE")
            process_workspace_source "$ws_json"
        done
    fi

    # process_resources: config_file base_dir label manifest_section manifest_key source_name skip_manifest filter_json
    # (all defaults: CONFIG_FILE, PWD, "local", "resources", "local", "", "false", "{}")
    process_resources

    # Write manifest and hash
    atomic_write ".compose-manifest.json" "$(echo "$MANIFEST_JSON" | jq '.')"
    atomic_write ".compose-hash" "$(compute_build_hash)"

    # Ensure _warning in .mcp.json
    if [[ -f ".mcp.json" ]]; then
        local tmp
        tmp=$(jq '._warning = "This file is managed by claude-compose. Do not edit directly."' ".mcp.json")
        atomic_write ".mcp.json" "$tmp"
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

        local preset_count ws_count has_resources
        preset_count=$(jq '.presets // [] | length' "$CONFIG_FILE")
        ws_count=$(jq '.workspaces // [] | length' "$CONFIG_FILE")
        has_resources=$(jq 'has("resources") and (.resources | length > 0)' "$CONFIG_FILE")

        local has_global_dr=false
        [[ -f "$GLOBAL_CONFIG" ]] && has_global_dr=true

        if [[ "$preset_count" -eq 0 && "$ws_count" -eq 0 && "$has_resources" != "true" && "$has_global_dr" != "true" ]] && ! has_builtin_skills; then
            echo -e "${CYAN}No presets, workspaces, or resources configured. Nothing to build.${NC}" >&2
            return
        fi

        if has_builtin_skills; then
            echo -e "${CYAN}Built-in skills:${NC}" >&2
            local _d
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
            local dri
            for ((dri = 0; dri < preset_count; dri++)); do
                local dr_type
                dr_type=$(jq -r ".presets[$dri] | type" "$CONFIG_FILE")
                if [[ "$dr_type" == "string" ]]; then
                    local name
                    name=$(jq -r ".presets[$dri]" "$CONFIG_FILE")
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
                elif [[ "$dr_type" == "object" ]]; then
                    local dr_source dr_prefix dr_locked_ver
                    dr_source=$(jq -r ".presets[$dri].source // empty" "$CONFIG_FILE")
                    dr_prefix=$(jq -r ".presets[$dri].prefix // empty" "$CONFIG_FILE")
                    echo -e "  - ${dr_source}" >&2
                    [[ -n "$dr_prefix" ]] && echo "    prefix: ${dr_prefix}" >&2
                    if [[ -n "$LOCK_FILE" && -f "$LOCK_FILE" ]]; then
                        parse_github_source "$dr_source"
                        local dr_sk="github:${_GH_OWNER}/${_GH_REPO}"
                        [[ -n "$_GH_PATH" ]] && dr_sk+="/${_GH_PATH}"
                        dr_locked_ver=$(jq -r --arg k "$dr_sk" '.registries[$k].resolved // empty' "$LOCK_FILE" 2>/dev/null || true)
                        [[ -n "$dr_locked_ver" ]] && echo "    locked: v${dr_locked_ver}" >&2
                        local dr_dir
                        dr_dir=$(registry_preset_dir "$_GH_OWNER" "$_GH_REPO" "$dr_locked_ver" "$_GH_PATH")
                        [[ -d "$dr_dir" ]] && echo "    path: ${dr_dir}" >&2
                    fi
                fi
            done
            echo "" >&2
        fi

        if [[ "$ws_count" -gt 0 ]]; then
            echo -e "${CYAN}Workspaces to sync:${NC}" >&2
            local drwi
            for ((drwi = 0; drwi < ws_count; drwi++)); do
                local ws_path
                ws_path=$(jq -r ".workspaces[$drwi].path" "$CONFIG_FILE")
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
