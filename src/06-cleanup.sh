# Clean resources tracked in manifest for a given section (presets or workspaces)
# $1 = old manifest, $2 = section name ("presets" or "workspaces")
clean_manifest_section() {
    local old_manifest="$1"
    local section="$2"

    local source_names
    source_names=$(echo "$old_manifest" | jq -r --arg s "$section" '.[$s] // {} | keys[]' 2>/dev/null || true)
    while IFS= read -r source_name; do
        [[ -z "$source_name" ]] && continue
        local source_data
        source_data=$(echo "$old_manifest" | jq -c --arg s "$section" --arg n "$source_name" '.[$s][$n]')

        # Delete agent files
        local agents
        agents=$(echo "$source_data" | jq -r '.agents // [] | .[]' 2>/dev/null || true)
        while IFS= read -r agent; do
            [[ -z "$agent" ]] && continue
            if [[ -f ".claude/agents/${agent}" ]]; then
                rm -f ".claude/agents/${agent}"
                echo -e "  ${YELLOW}-agent:${NC} $agent" >&2
            fi
        done <<< "$agents"

        # Delete skill symlinks/directories
        local skills
        skills=$(echo "$source_data" | jq -r '.skills // [] | .[]' 2>/dev/null || true)
        while IFS= read -r skill; do
            [[ -z "$skill" ]] && continue
            if [[ -L ".claude/skills/${skill}" ]]; then
                rm -f ".claude/skills/${skill}"
                echo -e "  ${YELLOW}-skill:${NC} $skill" >&2
            elif [[ -d ".claude/skills/${skill}" ]]; then
                rm -rf ".claude/skills/${skill}"
                echo -e "  ${YELLOW}-skill:${NC} $skill" >&2
            fi
        done <<< "$skills"

        # Remove MCP servers from .mcp.json
        local mcp_servers
        mcp_servers=$(echo "$source_data" | jq -r '.mcp_servers // [] | .[]' 2>/dev/null || true)
        if [[ -f ".mcp.json" ]]; then
            while IFS= read -r server; do
                [[ -z "$server" ]] && continue
                local tmp
                tmp=$(jq --arg s "$server" 'del(.mcpServers[$s])' ".mcp.json")
                echo "$tmp" > ".mcp.json"
                echo -e "  ${YELLOW}-mcp:${NC} $server" >&2
            done <<< "$mcp_servers"
            local server_count
            server_count=$(jq '.mcpServers | length' ".mcp.json" 2>/dev/null || echo 0)
            if [[ "$server_count" -eq 0 ]]; then
                rm -f ".mcp.json"
            fi
        fi
    done <<< "$source_names"
}
