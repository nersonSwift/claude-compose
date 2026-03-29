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
