# ── Build System ─────────────────────────────────────────────────────

# Collect all preset names recursively (for hashing)
collect_all_presets() {
    local -a visited=()
    local -a queue=("$@")

    while [[ ${#queue[@]} -gt 0 ]]; do
        local name="${queue[0]}"
        queue=("${queue[@]:1}")

        local skip=false
        for v in "${visited[@]+"${visited[@]}"}"; do
            [[ "$v" == "$name" ]] && skip=true && break
        done
        [[ "$skip" == true ]] && continue

        visited+=("$name")
        echo "$name"

        local preset_dir="$PRESETS_DIR/$name"
        if [[ -f "$preset_dir/claude-compose.json" ]]; then
            local nested
            nested=$(jq -r '.presets // [] | .[]' "$preset_dir/claude-compose.json" 2>/dev/null || true)
            while IFS= read -r n; do
                [[ -z "$n" ]] && continue
                queue+=("$n")
            done <<< "$nested"
        fi
    done
}

# Hash Claude config files from a workspace directory (for change detection)
hash_workspace_config_files() {
    local ws_dir="$1"
    local result=""
    for f in "$ws_dir/.mcp.json" "$ws_dir/.claude/settings.local.json" "$ws_dir/claude-compose.json"; do
        [[ -f "$f" ]] && result+=$(shasum "$f" 2>/dev/null || true)
    done
    [[ -d "$ws_dir/.claude/agents" ]] && result+=$(find "$ws_dir/.claude/agents" -name '*.md' -print0 2>/dev/null | sort -z | xargs -0 shasum 2>/dev/null || true)
    [[ -d "$ws_dir/.claude/skills" ]] && result+=$(find "$ws_dir/.claude/skills" \( -type f -o -type l \) -print0 2>/dev/null | sort -z | xargs -0 shasum 2>/dev/null || true)
    echo "$result"
}

# Compute content-based hash of config + all preset/workspace source files
compute_build_hash() {
    local hash_input=""
    hash_input+=$(cat "$CONFIG_FILE")

    # Hash global config
    if [[ -f "$GLOBAL_CONFIG" ]]; then
        hash_input+=$(cat "$GLOBAL_CONFIG")
    fi

    # Hash built-in skills
    if [[ -d "$BUILTIN_SKILLS_DIR" ]]; then
        hash_input+=$(find "$BUILTIN_SKILLS_DIR" -type f -print0 2>/dev/null | sort -z | xargs -0 shasum 2>/dev/null || true)
    fi

    # Hash global presets
    if [[ -f "$GLOBAL_CONFIG" ]]; then
        local global_presets
        global_presets=$(jq -r '.presets // [] | .[]' "$GLOBAL_CONFIG" 2>/dev/null || true)
        local -a global_preset_list=()
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            global_preset_list+=("$name")
        done <<< "$global_presets"

        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            local preset_dir="$PRESETS_DIR/$name"
            [[ -d "$preset_dir" ]] || continue
            hash_input+=$(find "$preset_dir" -type f -print0 | sort -z | xargs -0 shasum 2>/dev/null || true)
        done < <(collect_all_presets "${global_preset_list[@]+"${global_preset_list[@]}"}")
    fi

    # Hash preset dirs (recursively collected)
    local top_presets
    top_presets=$(jq -r '.presets // [] | .[]' "$CONFIG_FILE" 2>/dev/null || true)
    local -a preset_list=()
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        preset_list+=("$name")
    done <<< "$top_presets"

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        local preset_dir="$PRESETS_DIR/$name"
        [[ -d "$preset_dir" ]] || continue
        hash_input+=$(find "$preset_dir" -type f -print0 | sort -z | xargs -0 shasum 2>/dev/null || true)
    done < <(collect_all_presets "${preset_list[@]+"${preset_list[@]}"}")

    # Hash workspace source dirs (Claude config files only)
    local ws_count
    ws_count=$(jq '.workspaces // [] | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    for i in $(seq 0 $((ws_count - 1))); do
        local ws_path
        ws_path=$(jq -r ".workspaces[$i].path" "$CONFIG_FILE")
        ws_path=$(expand_path "$ws_path")
        [[ -d "$ws_path" ]] || continue
        hash_input+=$(hash_workspace_config_files "$ws_path")
    done

    # Hash global workspaces
    if [[ -f "$GLOBAL_CONFIG" ]]; then
        local global_ws_count
        global_ws_count=$(jq '.workspaces // [] | length' "$GLOBAL_CONFIG" 2>/dev/null || echo 0)
        for i in $(seq 0 $((global_ws_count - 1))); do
            local gws_path
            gws_path=$(jq -r ".workspaces[$i].path" "$GLOBAL_CONFIG")
            gws_path=$(expand_path "$gws_path")
            [[ -d "$gws_path" ]] || continue
            hash_input+=$(hash_workspace_config_files "$gws_path")
        done
    fi

    # Hash resources section content
    local resources_mcp
    resources_mcp=$(jq -c '.resources.mcp // empty' "$CONFIG_FILE" 2>/dev/null || true)
    [[ -n "$resources_mcp" ]] && hash_input+="$resources_mcp"

    # Hash referenced agent/skill files
    local res_agents
    res_agents=$(jq -r '.resources.agents // [] | .[]' "$CONFIG_FILE" 2>/dev/null || true)
    while IFS= read -r agent_path; do
        [[ -z "$agent_path" ]] && continue
        local abs_agent="$ORIGINAL_CWD/$agent_path"
        [[ -f "$abs_agent" ]] && hash_input+=$(shasum "$abs_agent" 2>/dev/null || true)
    done <<< "$res_agents"

    local res_skills
    res_skills=$(jq -r '.resources.skills // [] | .[]' "$CONFIG_FILE" 2>/dev/null || true)
    while IFS= read -r skill_path; do
        [[ -z "$skill_path" ]] && continue
        local abs_skill="$ORIGINAL_CWD/$skill_path"
        [[ -d "$abs_skill" ]] && hash_input+=$(find "$abs_skill" \( -type f -o -type l \) -print0 2>/dev/null | sort -z | xargs -0 shasum 2>/dev/null || true)
    done <<< "$res_skills"

    # Hash env files
    local res_env_files
    res_env_files=$(jq -r '.resources.env_files // [] | .[]' "$CONFIG_FILE" 2>/dev/null || true)
    while IFS= read -r env_file; do
        [[ -z "$env_file" ]] && continue
        local abs_env="$ORIGINAL_CWD/$env_file"
        [[ -f "$abs_env" ]] && hash_input+=$(shasum "$abs_env" 2>/dev/null || true)
    done <<< "$res_env_files"

    # Hash global resources
    if [[ -f "$GLOBAL_CONFIG" ]]; then
        local global_mcp
        global_mcp=$(jq -c '.resources.mcp // empty' "$GLOBAL_CONFIG" 2>/dev/null || true)
        [[ -n "$global_mcp" ]] && hash_input+="$global_mcp"

        local global_agents
        global_agents=$(jq -r '.resources.agents // [] | .[]' "$GLOBAL_CONFIG" 2>/dev/null || true)
        while IFS= read -r agent_path; do
            [[ -z "$agent_path" ]] && continue
            local abs_agent="$GLOBAL_CONFIG_DIR/$agent_path"
            [[ -f "$abs_agent" ]] && hash_input+=$(shasum "$abs_agent" 2>/dev/null || true)
        done <<< "$global_agents"

        local global_skills
        global_skills=$(jq -r '.resources.skills // [] | .[]' "$GLOBAL_CONFIG" 2>/dev/null || true)
        while IFS= read -r skill_path; do
            [[ -z "$skill_path" ]] && continue
            local abs_skill="$GLOBAL_CONFIG_DIR/$skill_path"
            [[ -d "$abs_skill" ]] && hash_input+=$(find "$abs_skill" \( -type f -o -type l \) -print0 2>/dev/null | sort -z | xargs -0 shasum 2>/dev/null || true)
        done <<< "$global_skills"

        local global_env_files
        global_env_files=$(jq -r '.resources.env_files // [] | .[]' "$GLOBAL_CONFIG" 2>/dev/null || true)
        while IFS= read -r env_file; do
            [[ -z "$env_file" ]] && continue
            local abs_env="$GLOBAL_CONFIG_DIR/$env_file"
            [[ -f "$abs_env" ]] && hash_input+=$(shasum "$abs_env" 2>/dev/null || true)
        done <<< "$global_env_files"
    fi

    printf '%s' "$hash_input" | shasum -a 256 | cut -c1-32
}

# Check if rebuild is needed
needs_rebuild() {
    [[ ! -f ".compose-manifest.json" ]] && return 0
    [[ ! -f ".compose-hash" ]] && return 0

    local current_hash stored_hash
    current_hash=$(compute_build_hash)
    stored_hash=$(cat ".compose-hash")
    [[ "$current_hash" != "$stored_hash" ]]
}

# Read manifest or return empty
read_manifest() {
    if [[ -f ".compose-manifest.json" ]]; then
        cat ".compose-manifest.json"
    else
        echo '{"builtin":{},"global":{},"presets":{},"workspaces":{},"resources":{}}'
    fi
}
