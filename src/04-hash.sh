# ── Build System ─────────────────────────────────────────────────────

# Hash Claude config files from a workspace directory (for change detection)
# Output goes to stdout — caller redirects to hash temp file
hash_workspace_config_files() {
    local ws_dir="$1"
    local _ws_mcp="$ws_dir/$COMPOSE_MCP"
    for f in "$_ws_mcp" "$ws_dir/.claude/settings.local.json" "$ws_dir/claude-compose.json"; do
        if [[ -f "$f" ]]; then "$_SHASUM_CMD" "$f" 2>/dev/null || true; fi
    done
    if [[ -d "$ws_dir/.claude/agents" ]]; then find "$ws_dir/.claude/agents" -name '*.md' -print0 2>/dev/null | sort -z | xargs -0 "$_SHASUM_CMD" 2>/dev/null || true; fi
    if [[ -d "$ws_dir/.claude/skills" ]]; then find "$ws_dir/.claude/skills" \( -type f -o -type l \) -print0 2>/dev/null | sort -z | xargs -0 "$_SHASUM_CMD" 2>/dev/null || true; fi
}

# Compute content-based hash of config + all workspace/resource source files
compute_build_hash() {
    local hash_tmp
    hash_tmp=$(mktemp)
    trap 'rm -f "$hash_tmp"' RETURN

    cat "$CONFIG_FILE" >> "$hash_tmp"

    # Hash global config
    if [[ -f "$GLOBAL_CONFIG" ]]; then
        cat "$GLOBAL_CONFIG" >> "$hash_tmp"
    fi

    # Hash built-in skills
    if [[ -d "$BUILTIN_SKILLS_DIR" ]]; then
        find "$BUILTIN_SKILLS_DIR" -type f -print0 2>/dev/null | sort -z | xargs -0 "$_SHASUM_CMD" 2>/dev/null >> "$hash_tmp" || true
    fi

    # Hash workspace source dirs (Claude config files only)
    local ws_count
    ws_count=$(jq '.workspaces // [] | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    local hwi
    for ((hwi = 0; hwi < ws_count; hwi++)); do
        local ws_path
        ws_path=$(jq -r ".workspaces[$hwi].path" "$CONFIG_FILE")
        ws_path=$(expand_path "$ws_path" "$CONFIG_DIR")
        if [[ -f "$ws_path" ]]; then
            ws_path=$(dirname "$ws_path")
        fi
        [[ -d "$ws_path" ]] || continue
        hash_workspace_config_files "$ws_path" >> "$hash_tmp"
    done

    # Hash global workspaces
    if [[ -f "$GLOBAL_CONFIG" ]]; then
        local global_ws_count
        global_ws_count=$(jq '.workspaces // [] | length' "$GLOBAL_CONFIG" 2>/dev/null || echo 0)
        local hgwi
        for ((hgwi = 0; hgwi < global_ws_count; hgwi++)); do
            local gws_path
            gws_path=$(jq -r ".workspaces[$hgwi].path" "$GLOBAL_CONFIG")
            gws_path=$(expand_path "$gws_path" "$GLOBAL_CONFIG_DIR")
            if [[ -f "$gws_path" ]]; then
                gws_path=$(dirname "$gws_path")
            fi
            [[ -d "$gws_path" ]] || continue
            hash_workspace_config_files "$gws_path" >> "$hash_tmp"
        done
    fi

    # Hash resources section content
    local resources_mcp
    resources_mcp=$(jq -c '.resources.mcp // empty' "$CONFIG_FILE" 2>/dev/null || true)
    [[ -n "$resources_mcp" ]] && printf '%s' "$resources_mcp" >> "$hash_tmp"

    # Hash referenced agent/skill files
    local res_agents
    res_agents=$(jq -r '.resources.agents // [] | .[]' "$CONFIG_FILE" 2>/dev/null || true)
    while IFS= read -r agent_path; do
        [[ -z "$agent_path" ]] && continue
        local abs_agent="$CONFIG_DIR/$agent_path"
        if [[ -f "$abs_agent" ]]; then "$_SHASUM_CMD" "$abs_agent" 2>/dev/null >> "$hash_tmp" || true; fi
    done <<< "$res_agents"

    local res_skills
    res_skills=$(jq -r '.resources.skills // [] | .[]' "$CONFIG_FILE" 2>/dev/null || true)
    while IFS= read -r skill_path; do
        [[ -z "$skill_path" ]] && continue
        local abs_skill="$CONFIG_DIR/$skill_path"
        if [[ -d "$abs_skill" ]]; then find "$abs_skill" \( -type f -o -type l \) -print0 2>/dev/null | sort -z | xargs -0 "$_SHASUM_CMD" 2>/dev/null >> "$hash_tmp" || true; fi
    done <<< "$res_skills"

    # Hash env files
    local res_env_files
    res_env_files=$(jq -r '.resources.env_files // [] | .[]' "$CONFIG_FILE" 2>/dev/null || true)
    while IFS= read -r env_file; do
        [[ -z "$env_file" ]] && continue
        local abs_env="$CONFIG_DIR/$env_file"
        if [[ -f "$abs_env" ]]; then "$_SHASUM_CMD" "$abs_env" 2>/dev/null >> "$hash_tmp" || true; fi
    done <<< "$res_env_files"

    # Hash append_system_prompt_files
    local res_aspf
    res_aspf=$(jq -r '.resources.append_system_prompt_files // [] | .[]' "$CONFIG_FILE" 2>/dev/null || true)
    while IFS= read -r aspf; do
        [[ -z "$aspf" ]] && continue
        local abs_aspf="$CONFIG_DIR/$aspf"
        if [[ -f "$abs_aspf" ]]; then "$_SHASUM_CMD" "$abs_aspf" 2>/dev/null >> "$hash_tmp" || true; fi
    done <<< "$res_aspf"

    # Hash settings file
    local res_settings
    res_settings=$(jq -r '.resources.settings // empty' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ -n "$res_settings" ]]; then
        local abs_settings="$CONFIG_DIR/$res_settings"
        if [[ -f "$abs_settings" ]]; then "$_SHASUM_CMD" "$abs_settings" 2>/dev/null >> "$hash_tmp" || true; fi
    fi

    # Hash global resources
    if [[ -f "$GLOBAL_CONFIG" ]]; then
        local global_mcp
        global_mcp=$(jq -c '.resources.mcp // empty' "$GLOBAL_CONFIG" 2>/dev/null || true)
        [[ -n "$global_mcp" ]] && printf '%s' "$global_mcp" >> "$hash_tmp"

        local global_agents
        global_agents=$(jq -r '.resources.agents // [] | .[]' "$GLOBAL_CONFIG" 2>/dev/null || true)
        while IFS= read -r agent_path; do
            [[ -z "$agent_path" ]] && continue
            local abs_agent="$GLOBAL_CONFIG_DIR/$agent_path"
            if [[ -f "$abs_agent" ]]; then "$_SHASUM_CMD" "$abs_agent" 2>/dev/null >> "$hash_tmp" || true; fi
        done <<< "$global_agents"

        local global_skills
        global_skills=$(jq -r '.resources.skills // [] | .[]' "$GLOBAL_CONFIG" 2>/dev/null || true)
        while IFS= read -r skill_path; do
            [[ -z "$skill_path" ]] && continue
            local abs_skill="$GLOBAL_CONFIG_DIR/$skill_path"
            if [[ -d "$abs_skill" ]]; then find "$abs_skill" \( -type f -o -type l \) -print0 2>/dev/null | sort -z | xargs -0 "$_SHASUM_CMD" 2>/dev/null >> "$hash_tmp" || true; fi
        done <<< "$global_skills"

        local global_env_files
        global_env_files=$(jq -r '.resources.env_files // [] | .[]' "$GLOBAL_CONFIG" 2>/dev/null || true)
        while IFS= read -r env_file; do
            [[ -z "$env_file" ]] && continue
            local abs_env="$GLOBAL_CONFIG_DIR/$env_file"
            if [[ -f "$abs_env" ]]; then "$_SHASUM_CMD" "$abs_env" 2>/dev/null >> "$hash_tmp" || true; fi
        done <<< "$global_env_files"

        # Hash global append_system_prompt_files
        local global_aspf
        global_aspf=$(jq -r '.resources.append_system_prompt_files // [] | .[]' "$GLOBAL_CONFIG" 2>/dev/null || true)
        while IFS= read -r aspf; do
            [[ -z "$aspf" ]] && continue
            local abs_aspf="$GLOBAL_CONFIG_DIR/$aspf"
            if [[ -f "$abs_aspf" ]]; then "$_SHASUM_CMD" "$abs_aspf" 2>/dev/null >> "$hash_tmp" || true; fi
        done <<< "$global_aspf"

        # Hash global settings file
        local global_settings
        global_settings=$(jq -r '.resources.settings // empty' "$GLOBAL_CONFIG" 2>/dev/null || true)
        if [[ -n "$global_settings" ]]; then
            local abs_gs="$GLOBAL_CONFIG_DIR/$global_settings"
            if [[ -f "$abs_gs" ]]; then "$_SHASUM_CMD" "$abs_gs" 2>/dev/null >> "$hash_tmp" || true; fi
        fi
    fi

    local result
    result=$(_shasum256 < "$hash_tmp" | cut -c1-32)
    echo "$result"
}

# Check if rebuild is needed
needs_rebuild() {
    [[ ! -f "$COMPOSE_MANIFEST" ]] && return 0
    [[ ! -f "$COMPOSE_HASH" ]] && return 0

    local current_hash stored_hash
    current_hash=$(compute_build_hash)
    stored_hash=$(cat "$COMPOSE_HASH")
    [[ "$current_hash" != "$stored_hash" ]]
}

# Read manifest or return empty
read_manifest() {
    if [[ -f "$COMPOSE_MANIFEST" ]]; then
        cat "$COMPOSE_MANIFEST"
    else
        echo '{"builtin":{},"global":{},"workspaces":{},"resources":{}}'
    fi
}
