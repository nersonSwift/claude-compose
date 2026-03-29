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
    # Hash local plugin directories from workspace config
    if [[ -f "$ws_dir/claude-compose.json" ]]; then
        while IFS= read -r _hp_entry; do
            [[ -z "$_hp_entry" ]] && continue
            local _hp_path
            _hp_path=$(jq -r 'if type == "string" then . elif .path then .path else empty end' <<< "$_hp_entry" 2>/dev/null || true)
            [[ -z "$_hp_path" ]] && continue
            # Only hash local path plugins (not marketplace names)
            [[ "$_hp_path" != ./* && "$_hp_path" != ~* && "$_hp_path" != /* ]] && continue
            _hp_path="${_hp_path/#\~/$HOME}"
            [[ "$_hp_path" != /* ]] && _hp_path="$ws_dir/$_hp_path"
            if [[ -d "$_hp_path" ]]; then
                find "$_hp_path" -type f -print0 2>/dev/null | sort -z | xargs -0 "$_SHASUM_CMD" 2>/dev/null || true
            fi
        done < <(jq -c '.plugins // [] | .[]' "$ws_dir/claude-compose.json" 2>/dev/null || true)
    fi
}

# Hash resource files (agents, skills, env, aspf, settings, mcp) from a config
# $1=config_file $2=base_dir $3=hash_tmp_file
_hash_config_resources() {
    local cf="$1" bd="$2" ht="$3"

    local mcp_json
    mcp_json=$(jq -c '.resources.mcp // empty' "$cf" 2>/dev/null || true)
    [[ -n "$mcp_json" ]] && printf '%s' "$mcp_json" >> "$ht"

    local field path abs
    for field in agents skills; do
        while IFS= read -r path; do
            [[ -z "$path" ]] && continue
            abs="$bd/$path"
            if [[ "$field" == "agents" && -f "$abs" ]]; then
                "$_SHASUM_CMD" "$abs" 2>/dev/null >> "$ht" || true
            elif [[ "$field" == "skills" && -d "$abs" ]]; then
                find "$abs" \( -type f -o -type l \) -print0 2>/dev/null | sort -z | xargs -0 "$_SHASUM_CMD" 2>/dev/null >> "$ht" || true
            fi
        done < <(jq -r ".resources.${field} // [] | .[]" "$cf" 2>/dev/null || true)
    done

    for field in env_files append_system_prompt_files; do
        while IFS= read -r path; do
            [[ -z "$path" ]] && continue
            abs="$bd/$path"
            [[ -f "$abs" ]] && { "$_SHASUM_CMD" "$abs" 2>/dev/null >> "$ht" || true; }
        done < <(jq -r ".resources.${field} // [] | .[]" "$cf" 2>/dev/null || true)
    done

    local settings_path
    settings_path=$(jq -r '.resources.settings // empty' "$cf" 2>/dev/null || true)
    if [[ -n "$settings_path" ]]; then
        abs="$bd/$settings_path"
        [[ -f "$abs" ]] && { "$_SHASUM_CMD" "$abs" 2>/dev/null >> "$ht" || true; }
    fi
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

    # Hash built-in plugin
    if [[ -d "$BUILTIN_PLUGIN_DIR" ]]; then
        find "$BUILTIN_PLUGIN_DIR" -type f -print0 2>/dev/null | sort -z | xargs -0 "$_SHASUM_CMD" 2>/dev/null >> "$hash_tmp" || true
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

    # Hash resources from a config file
    # $1=config_file $2=base_dir $3=hash_tmp
    _hash_config_resources "$CONFIG_FILE" "$CONFIG_DIR" "$hash_tmp"
    [[ -f "$GLOBAL_CONFIG" ]] && _hash_config_resources "$GLOBAL_CONFIG" "$GLOBAL_CONFIG_DIR" "$hash_tmp"

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
        echo '{"global":{},"workspaces":{},"resources":{}}'
    fi
}
