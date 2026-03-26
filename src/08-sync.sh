# ── Sync resources from a source directory ──────────────────────────
# Shared logic for presets and workspaces.
# $1 = source dir, $2 = filter JSON, $3 = source name (for env prefix)
# Populates CURRENT_SOURCE_* arrays. Caller writes manifest.
sync_source_dir() {
    local source_dir="$1"
    local filter_json="$2"
    local source_name="${3:-}"

    # Reset tracking
    CURRENT_SOURCE_AGENTS=()
    CURRENT_SOURCE_SKILLS=()
    CURRENT_SOURCE_MCP_SERVERS=()
    CURRENT_SOURCE_ADD_DIRS=()
    CURRENT_SOURCE_PROJECT_DIRS=()
    CURRENT_SOURCE_SYSTEM_PROMPT_FILES=()
    CURRENT_SOURCE_SETTINGS_FILES=()

    # ── Copy agents ──
    local agents_dir="$source_dir/.claude/agents"
    if [[ -d "$agents_dir" ]]; then
        local agents_include agents_exclude agents_rename
        agents_include=$(echo "$filter_json" | jq -c '.agents.include // ["*"]')
        agents_exclude=$(echo "$filter_json" | jq -c '.agents.exclude // []')
        agents_rename=$(echo "$filter_json" | jq -c '.agents.rename // {}')

        mkdir -p ".claude/agents"
        for agent_file in "$agents_dir"/*.md; do
            [[ -f "$agent_file" ]] || continue
            local agent_name
            agent_name=$(basename "$agent_file" .md)

            if matches_filter "$agent_name" "$agents_include" "$agents_exclude"; then
                local final_name
                final_name=$(echo "$agents_rename" | jq -r --arg n "$agent_name" '.[$n] // $n')
                local dest_file="${final_name}.md"

                if [[ -f ".claude/agents/${dest_file}" ]]; then
                    echo -e "  ${YELLOW}overwrite:${NC} .claude/agents/${dest_file}" >&2
                fi

                local abs_agent_file
                abs_agent_file=$(cd "$(dirname "$agent_file")" && pwd -P)/$(basename "$agent_file")
                # Security: reject symlinks pointing outside the source directory
                if [[ -L "$agent_file" ]]; then
                    local _link_val _real_target _real_source
                    _link_val=$(readlink "$agent_file")
                    # Resolve relative symlinks against the symlink's directory
                    if [[ "$_link_val" != /* ]]; then
                        _link_val="$(cd "$(dirname "$agent_file")" && pwd -P)/$_link_val"
                    fi
                    local _target_dir
                    _target_dir=$(cd "$(dirname "$_link_val")" 2>/dev/null && pwd -P) || {
                        echo -e "  ${YELLOW}skip agent:${NC} $agent_name (broken symlink)" >&2
                        continue
                    }
                    _real_target="${_target_dir}/$(basename "$_link_val")"
                    _real_source=$(cd "$source_dir" && pwd -P)
                    if [[ "$_real_target" != "$_real_source"/* ]]; then
                        echo -e "  ${YELLOW}skip agent:${NC} $agent_name (symlink escapes source directory)" >&2
                        continue
                    fi
                fi
                if [[ "$final_name" != "$agent_name" ]]; then
                    # Name changed — copy and rewrite name: in frontmatter
                    rewrite_frontmatter_name "$abs_agent_file" ".claude/agents/${dest_file}" "$final_name"
                else
                    ln -sf "$abs_agent_file" ".claude/agents/${dest_file}"
                fi
                CURRENT_SOURCE_AGENTS+=("$dest_file")
                if [[ "$final_name" != "$agent_name" ]]; then
                    echo -e "  ${GREEN}+agent:${NC} $agent_name → $final_name" >&2
                else
                    echo -e "  ${GREEN}+agent:${NC} $agent_name" >&2
                fi
            fi
        done
    fi

    # ── Copy skills ──
    local skills_dir="$source_dir/.claude/skills"
    if [[ -d "$skills_dir" ]]; then
        local skills_include skills_exclude
        skills_include=$(echo "$filter_json" | jq -c '.skills.include // ["*"]')
        skills_exclude=$(echo "$filter_json" | jq -c '.skills.exclude // []')

        mkdir -p ".claude/skills"
        for skill_path in "$skills_dir"/*/; do
            [[ -d "$skill_path" ]] || continue
            local skill_name
            skill_name=$(basename "$skill_path")

            if matches_filter "$skill_name" "$skills_include" "$skills_exclude"; then
                if [[ -L ".claude/skills/${skill_name}" || -d ".claude/skills/${skill_name}" ]]; then
                    echo -e "  ${YELLOW}overwrite:${NC} .claude/skills/${skill_name}/" >&2
                    rm -f ".claude/skills/${skill_name}" 2>/dev/null || rm -rf ".claude/skills/${skill_name}"
                fi

                local abs_skill_path
                abs_skill_path=$(cd "$skill_path" && pwd -P)
                # Security: reject symlinks pointing outside the source directory
                if [[ -L "${skill_path%/}" ]]; then
                    local _real_source
                    _real_source=$(cd "$source_dir" && pwd -P)
                    if [[ "$abs_skill_path" != "$_real_source"/* ]]; then
                        echo -e "  ${YELLOW}skip skill:${NC} $skill_name (symlink escapes source directory)" >&2
                        continue
                    fi
                fi
                ln -sf "$abs_skill_path" ".claude/skills/${skill_name}"
                CURRENT_SOURCE_SKILLS+=("$skill_name")
                echo -e "  ${GREEN}+skill:${NC} $skill_name" >&2
            fi
        done
    fi

    # ── Collect known env var names from source's env_files (for selective prefixing) ──
    local _source_known_vars=""
    if [[ -n "$source_name" && -f "$source_dir/claude-compose.json" ]]; then
        local _src_env_files
        _src_env_files=$(jq -r '.resources.env_files // [] | .[]' "$source_dir/claude-compose.json" 2>/dev/null || true)
        while IFS= read -r _ef; do
            [[ -z "$_ef" ]] && continue
            local _ef_abs="$source_dir/$_ef"
            [[ -f "$_ef_abs" ]] || continue
            _source_known_vars+=$(jq -r 'keys[]' "$_ef_abs" 2>/dev/null || true)
            _source_known_vars+=$'\n'
        done <<< "$_src_env_files"
    fi

    # ── Merge MCP servers ──
    local mcp_file="$source_dir/.mcp.json"
    if [[ -f "$mcp_file" ]]; then
        local mcp_include mcp_exclude mcp_rename
        mcp_include=$(echo "$filter_json" | jq -c '.mcp.include // ["*"]')
        mcp_exclude=$(echo "$filter_json" | jq -c '.mcp.exclude // []')
        mcp_rename=$(echo "$filter_json" | jq -c '.mcp.rename // {}')

        if [[ ! -f ".mcp.json" ]]; then
            atomic_write ".mcp.json" "$_MCP_EMPTY"
        fi

        local mcp_batch='{}'
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            if matches_filter "$name" "$mcp_include" "$mcp_exclude"; then
                local server_config final_name
                server_config=$(jq -c --arg n "$name" '.mcpServers[$n]' "$mcp_file")
                final_name=$(echo "$mcp_rename" | jq -r --arg n "$name" '.[$n] // $n')

                # Prefix only env vars defined in source's env_files
                if [[ -n "$source_name" && -n "${_source_known_vars:-}" ]]; then
                    local prefix
                    prefix=$(compute_source_prefix "$source_name" "$source_dir")
                    server_config=$(prefix_env_vars_in_mcp "$server_config" "$prefix" "$_source_known_vars")
                fi

                mcp_batch=$(echo "$mcp_batch" | jq --arg name "$final_name" --argjson config "$server_config" '.[$name] = $config')

                CURRENT_SOURCE_MCP_SERVERS+=("$final_name")
                if [[ "$final_name" != "$name" ]]; then
                    echo -e "  ${GREEN}+mcp:${NC} $name → $final_name" >&2
                else
                    echo -e "  ${GREEN}+mcp:${NC} $name" >&2
                fi
            fi
        done < <(jq -r '.mcpServers // {} | keys[]' "$mcp_file" 2>/dev/null || true)

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
    fi

    # ── CLAUDE.md via --add-dir ──
    local claude_md
    claude_md=$(echo "$filter_json" | jq -r 'if has("claude_md") then .claude_md else true end')
    if [[ -f "$source_dir/CLAUDE.md" || -d "$source_dir/.claude" ]]; then
        CURRENT_SOURCE_ADD_DIRS+=("${source_dir}|${claude_md}")
    fi
}

# Write CURRENT_SOURCE_* arrays to manifest under given section/name
# $1 = section ("presets" or "workspaces"), $2 = entry name
write_source_manifest() {
    local section="$1"
    local entry_name="$2"

    local agents_json skills_json mcp_json
    agents_json=$(printf '%s\n' "${CURRENT_SOURCE_AGENTS[@]+"${CURRENT_SOURCE_AGENTS[@]}"}" | jq -R -s 'split("\n") | map(select(. != ""))')
    skills_json=$(printf '%s\n' "${CURRENT_SOURCE_SKILLS[@]+"${CURRENT_SOURCE_SKILLS[@]}"}" | jq -R -s 'split("\n") | map(select(. != ""))')
    mcp_json=$(printf '%s\n' "${CURRENT_SOURCE_MCP_SERVERS[@]+"${CURRENT_SOURCE_MCP_SERVERS[@]}"}" | jq -R -s 'split("\n") | map(select(. != ""))')

    # add_dirs: array of {path, claude_md} objects
    local dirs_json="[]"
    for entry in "${CURRENT_SOURCE_ADD_DIRS[@]+"${CURRENT_SOURCE_ADD_DIRS[@]}"}"; do
        [[ -z "$entry" ]] && continue
        local d="${entry%|*}"
        local cmd="${entry##*|}"
        dirs_json=$(echo "$dirs_json" | jq --arg d "$d" --arg c "$cmd" '. + [{path: $d, claude_md: ($c == "true")}]')
    done

    # project_dirs: array of {path, claude_md} objects
    local proj_dirs_json="[]"
    for entry in "${CURRENT_SOURCE_PROJECT_DIRS[@]+"${CURRENT_SOURCE_PROJECT_DIRS[@]}"}"; do
        [[ -z "$entry" ]] && continue
        local p="${entry%|*}"
        local cmd="${entry##*|}"
        proj_dirs_json=$(echo "$proj_dirs_json" | jq --arg p "$p" --arg c "$cmd" '. + [{path: $p, claude_md: ($c == "true")}]')
    done

    # system_prompt_files: array of absolute paths
    local spf_json
    spf_json=$(printf '%s\n' "${CURRENT_SOURCE_SYSTEM_PROMPT_FILES[@]+"${CURRENT_SOURCE_SYSTEM_PROMPT_FILES[@]}"}" | jq -R -s 'split("\n") | map(select(. != ""))')

    # settings_files: array of absolute paths
    local sf_json
    sf_json=$(printf '%s\n' "${CURRENT_SOURCE_SETTINGS_FILES[@]+"${CURRENT_SOURCE_SETTINGS_FILES[@]}"}" | jq -R -s 'split("\n") | map(select(. != ""))')

    MANIFEST_JSON=$(echo "$MANIFEST_JSON" | jq \
        --arg section "$section" \
        --arg name "$entry_name" \
        --arg sname "$CURRENT_SOURCE_NAME" \
        --argjson agents "$agents_json" \
        --argjson skills "$skills_json" \
        --argjson mcp "$mcp_json" \
        --argjson dirs "$dirs_json" \
        --argjson pdirs "$proj_dirs_json" \
        --argjson spfiles "$spf_json" \
        --argjson sfiles "$sf_json" \
        '.[$section][$name] = {agents: $agents, skills: $skills, mcp_servers: $mcp, add_dirs: $dirs, project_dirs: $pdirs, system_prompt_files: $spfiles, settings_files: $sfiles, source_name: $sname}')
}
