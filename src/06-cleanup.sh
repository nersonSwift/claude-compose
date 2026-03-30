# Clean resources tracked in manifest for a given section
# $1 = old manifest, $2 = section name (e.g. "workspaces", "resources")
clean_manifest_section() {
    local old_manifest="$1"
    local section="$2"

    local source_names
    source_names=$(jq -r --arg s "$section" '.[$s] // {} | keys[]' <<< "$old_manifest" 2>/dev/null || true)
    while IFS= read -r source_name; do
        [[ -z "$source_name" ]] && continue
        local source_data
        source_data=$(jq -c --arg s "$section" --arg n "$source_name" '.[$s][$n]' <<< "$old_manifest")

        # Delete agent files
        local agents
        agents=$(jq -r '.agents // [] | .[]' <<< "$source_data" 2>/dev/null || true)
        while IFS= read -r agent; do
            [[ -z "$agent" ]] && continue
            [[ "$agent" == */* || "$agent" == ..* ]] && continue
            if [[ -L ".claude/agents/${agent}" || -f ".claude/agents/${agent}" ]]; then
                rm -f ".claude/agents/${agent}"
                echo -e "  ${YELLOW}-agent:${NC} $agent" >&2
            fi
        done <<< "$agents"

        # Delete skill symlinks/directories
        local skills
        skills=$(jq -r '.skills // [] | .[]' <<< "$source_data" 2>/dev/null || true)
        while IFS= read -r skill; do
            [[ -z "$skill" ]] && continue
            [[ "$skill" == */* || "$skill" == ..* ]] && continue
            if [[ -L ".claude/skills/${skill}" ]]; then
                rm -f ".claude/skills/${skill}"
                echo -e "  ${YELLOW}-skill:${NC} $skill" >&2
            elif [[ -d ".claude/skills/${skill}" ]]; then
                rm -rf ".claude/skills/${skill}"
                echo -e "  ${YELLOW}-skill:${NC} $skill" >&2
            fi
        done <<< "$skills"

        # Remove MCP servers from $COMPOSE_MCP
        local mcp_servers
        mcp_servers=$(jq -r '.mcp_servers // [] | .[]' <<< "$source_data" 2>/dev/null || true)
        if [[ -f "$COMPOSE_MCP" ]]; then
            local -a servers_to_delete=()
            while IFS= read -r server; do
                [[ -z "$server" ]] && continue
                servers_to_delete+=("$server")
                echo -e "  ${YELLOW}-mcp:${NC} $server" >&2
            done <<< "$mcp_servers"
            if [[ ${#servers_to_delete[@]} -gt 0 ]]; then
                local del_array
                del_array=$(printf '%s\n' "${servers_to_delete[@]}" | jq -Rs 'split("\n") | map(select(. != ""))')
                local tmp
                tmp=$(jq --argjson del "$del_array" 'reduce $del[] as $s (.; del(.mcpServers[$s]))' "$COMPOSE_MCP")
                atomic_write "$COMPOSE_MCP" "$tmp"
            fi
            local server_count
            server_count=$(jq '.mcpServers | length' "$COMPOSE_MCP" 2>/dev/null || echo 0)
            if [[ "$server_count" -eq 0 ]]; then
                rm -f "$COMPOSE_MCP"
            fi
        fi
    done <<< "$source_names"
}

# Wipe managed directories (.claude/agents/ and .claude/skills/) if safe.
# Compares stored hash with current state to detect manual changes.
# Check managed dirs for manual changes BEFORE any cleanup happens.
# Must be called before clean_manifest_section.
# Sets global _MANAGED_DIRS_MODIFIED=true if manual changes detected.
check_managed_dirs() {
    _MANAGED_DIRS_MODIFIED=false

    local agents_dir=".claude/agents"
    local skills_dir=".claude/skills"

    # No dirs — nothing to check
    if [[ ! -d "$agents_dir" && ! -d "$skills_dir" ]]; then
        return 0
    fi

    # No hash file (first build / migration) — skip check
    if [[ ! -f "$COMPOSE_DIRS_HASH" ]]; then
        return 0
    fi

    local stored_hash current_hash
    stored_hash=$(cat "$COMPOSE_DIRS_HASH")
    current_hash=$(compute_managed_dirs_hash)

    if [[ "$current_hash" != "$stored_hash" ]]; then
        _MANAGED_DIRS_MODIFIED=true
    fi
}

# Wipe managed directories. Called after check_managed_dirs + clean_manifest_section.
# If manual changes were detected, abort with doctor instead of wiping.
wipe_managed_dirs() {
    local agents_dir=".claude/agents"
    local skills_dir=".claude/skills"

    if [[ "$_MANAGED_DIRS_MODIFIED" == "true" ]]; then
        # Build actionable context for doctor
        local msg="Manual changes detected in managed directories (.claude/agents/ and .claude/skills/)."$'\n'
        msg+="These directories are fully managed by compose build and are wiped on each rebuild."$'\n'$'\n'
        msg+="Current contents:"$'\n'
        local dir
        for dir in "$agents_dir" "$skills_dir"; do
            [[ ! -d "$dir" ]] && continue
            msg+="  ${dir}/:"$'\n'
            while IFS= read -r f; do
                [[ -z "$f" ]] && continue
                if [[ -L "$f" ]]; then
                    msg+="    $(basename "$f") -> $(readlink "$f") [symlink, managed]"$'\n'
                else
                    msg+="    $(basename "$f") [manual, NOT in config]"$'\n'
                fi
            done < <(find "$dir" -maxdepth 1 \( -type f -o -type l \) 2>/dev/null | sort)
        done
        msg+=$'\n'"ACTION: For each [manual] file above:"$'\n'
        msg+="  - If it's an agent: move it to workspace (e.g. agents/) and add path to resources.agents in claude-compose.json"$'\n'
        msg+="  - If it's a skill dir: move it to workspace (e.g. skills/) and add path to resources.skills in claude-compose.json"$'\n'
        msg+="  - If it's unwanted: just delete it"$'\n'
        msg+="Then run claude-compose build --force to rebuild."

        # Release lock before aborting (critical for wrap mode subshell)
        _release_lock "$COMPOSE_LOCK" 2>/dev/null || true
        _BUILD_LOCK_HELD=false

        die_doctor "$msg"
    fi

    # Safe to wipe
    rm -rf "$agents_dir" "$skills_dir"
}
