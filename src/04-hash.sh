# ── Build System ─────────────────────────────────────────────────────

# Collect all preset identifiers recursively (for hashing)
# Items are prefixed: "local:name" or "github:source"
collect_all_presets() {
    local -a visited=()
    local -a queue=("$@")

    while [[ ${#queue[@]} -gt 0 ]]; do
        local item="${queue[0]}"
        queue=("${queue[@]:1}")

        local skip=false
        for v in "${visited[@]+"${visited[@]}"}"; do
            [[ "$v" == "$item" ]] && skip=true && break
        done
        [[ "$skip" == true ]] && continue

        visited+=("$item")
        echo "$item"

        # Resolve directory for nested preset discovery
        local preset_dir=""
        if [[ "$item" == local:* ]]; then
            preset_dir="$PRESETS_DIR/${item#local:}"
        elif [[ "$item" == github:* ]]; then
            # For github presets, resolve from lock file if available
            parse_github_source "github:${item#github:}"
            local source_key="github:${_GH_OWNER}/${_GH_REPO}"
            [[ -n "$_GH_PATH" ]] && source_key+="/${_GH_PATH}"
            preset_dir=$(resolve_locked_preset_dir "$source_key" 2>/dev/null || true)
        fi

        if [[ -n "$preset_dir" && -f "$preset_dir/claude-compose.json" ]]; then
            # Discover nested presets (mixed array)
            local nested_count
            nested_count=$(jq '.presets // [] | length' "$preset_dir/claude-compose.json" 2>/dev/null || echo 0)
            local j
            for ((j = 0; j < nested_count; j++)); do
                local entry_type
                entry_type=$(jq -r ".presets[$j] | type" "$preset_dir/claude-compose.json" 2>/dev/null || echo "null")
                if [[ "$entry_type" == "string" ]]; then
                    local nested_name
                    nested_name=$(jq -r ".presets[$j]" "$preset_dir/claude-compose.json")
                    if [[ "$nested_name" == *..* || "$nested_name" == */* ]]; then
                        continue
                    fi
                    # For nested local presets within a github registry, resolve relative to registry root
                    if [[ "$item" == github:* ]]; then
                        parse_github_source "github:${item#github:}"
                        if [[ -n "$LOCK_FILE" && -f "$LOCK_FILE" ]]; then
                            local reg_sk="github:${_GH_OWNER}/${_GH_REPO}"
                            [[ -n "$_GH_PATH" ]] && reg_sk+="/${_GH_PATH}"
                            local reg_ver
                            reg_ver=$(jq -r --arg k "$reg_sk" '.registries[$k].resolved // empty' "$LOCK_FILE" 2>/dev/null || true)
                            if [[ -n "$reg_ver" ]]; then
                                local reg_base
                                reg_base=$(registry_version_dir "$_GH_OWNER" "$_GH_REPO" "$reg_ver")
                                if [[ -d "$reg_base/$nested_name" ]]; then
                                    queue+=("github:${_GH_OWNER}/${_GH_REPO}/${nested_name}")
                                    continue
                                fi
                            fi
                        fi
                    fi
                    queue+=("local:$nested_name")
                elif [[ "$entry_type" == "object" ]]; then
                    local nested_source nested_name_h
                    nested_source=$(jq -r ".presets[$j].source // empty" "$preset_dir/claude-compose.json")
                    nested_name_h=$(jq -r ".presets[$j].name // empty" "$preset_dir/claude-compose.json")
                    if [[ -n "$nested_source" && "$nested_source" == github:* ]]; then
                        queue+=("github:${nested_source#github:}")
                    elif [[ -n "$nested_name_h" ]]; then
                        queue+=("local:$nested_name_h")
                    fi
                fi
            done
        fi
    done
}

# Hash Claude config files from a workspace directory (for change detection)
# Output goes to stdout — caller redirects to hash temp file
hash_workspace_config_files() {
    local ws_dir="$1"
    for f in "$ws_dir/.mcp.json" "$ws_dir/.claude/settings.local.json" "$ws_dir/claude-compose.json"; do
        if [[ -f "$f" ]]; then "$_SHASUM_CMD" "$f" 2>/dev/null || true; fi
    done
    if [[ -d "$ws_dir/.claude/agents" ]]; then find "$ws_dir/.claude/agents" -name '*.md' -print0 2>/dev/null | sort -z | xargs -0 "$_SHASUM_CMD" 2>/dev/null || true; fi
    if [[ -d "$ws_dir/.claude/skills" ]]; then find "$ws_dir/.claude/skills" \( -type f -o -type l \) -print0 2>/dev/null | sort -z | xargs -0 "$_SHASUM_CMD" 2>/dev/null || true; fi
}

# Compute content-based hash of config + all preset/workspace source files
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

    # Hash lock file
    if [[ -n "$LOCK_FILE" && -f "$LOCK_FILE" ]]; then
        cat "$LOCK_FILE" >> "$hash_tmp"
    fi

    # Hash global presets
    if [[ -f "$GLOBAL_CONFIG" ]]; then
        local -a global_preset_list=()
        local gp_count_h
        gp_count_h=$(jq '.presets // [] | length' "$GLOBAL_CONFIG" 2>/dev/null || echo 0)
        local gi
        for ((gi = 0; gi < gp_count_h; gi++)); do
            local gentry_type
            gentry_type=$(jq -r ".presets[$gi] | type" "$GLOBAL_CONFIG" 2>/dev/null || echo "null")
            if [[ "$gentry_type" == "string" ]]; then
                local gname
                gname=$(jq -r ".presets[$gi]" "$GLOBAL_CONFIG")
                global_preset_list+=("local:$gname")
            elif [[ "$gentry_type" == "object" ]]; then
                # Always hash full object (captures filters, prefix, rename)
                jq -c ".presets[$gi]" "$GLOBAL_CONFIG" >> "$hash_tmp"
                local gsource gname_h
                gsource=$(jq -r ".presets[$gi].source // empty" "$GLOBAL_CONFIG")
                gname_h=$(jq -r ".presets[$gi].name // empty" "$GLOBAL_CONFIG")
                if [[ -n "$gsource" && "$gsource" == github:* ]]; then
                    global_preset_list+=("github:${gsource#github:}")
                elif [[ -n "$gname_h" ]]; then
                    global_preset_list+=("local:$gname_h")
                fi
            fi
        done

        while IFS= read -r item; do
            [[ -z "$item" ]] && continue
            local preset_dir=""
            if [[ "$item" == local:* ]]; then
                preset_dir="$PRESETS_DIR/${item#local:}"
            elif [[ "$item" == github:* ]]; then
                parse_github_source "github:${item#github:}"
                local hp_sk="github:${_GH_OWNER}/${_GH_REPO}"
                [[ -n "$_GH_PATH" ]] && hp_sk+="/${_GH_PATH}"
                preset_dir=$(resolve_locked_preset_dir "$hp_sk" 2>/dev/null || true)
            fi
            [[ -z "$preset_dir" || ! -d "$preset_dir" ]] && continue
            find "$preset_dir" -type f -print0 | sort -z | xargs -0 "$_SHASUM_CMD" 2>/dev/null >> "$hash_tmp" || true
        done < <(collect_all_presets "${global_preset_list[@]+"${global_preset_list[@]}"}")
    fi

    # Hash preset dirs (recursively collected, handles mixed arrays)
    local -a preset_list=()
    local lp_count_h
    lp_count_h=$(jq '.presets // [] | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    local li
    for ((li = 0; li < lp_count_h; li++)); do
        local lentry_type
        lentry_type=$(jq -r ".presets[$li] | type" "$CONFIG_FILE" 2>/dev/null || echo "null")
        if [[ "$lentry_type" == "string" ]]; then
            local lname
            lname=$(jq -r ".presets[$li]" "$CONFIG_FILE")
            preset_list+=("local:$lname")
        elif [[ "$lentry_type" == "object" ]]; then
            # Always hash full object (captures filters, prefix, rename)
            jq -c ".presets[$li]" "$CONFIG_FILE" >> "$hash_tmp"
            local lsource lname_h
            lsource=$(jq -r ".presets[$li].source // empty" "$CONFIG_FILE")
            lname_h=$(jq -r ".presets[$li].name // empty" "$CONFIG_FILE")
            if [[ -n "$lsource" && "$lsource" == github:* ]]; then
                preset_list+=("github:${lsource#github:}")
            elif [[ -n "$lname_h" ]]; then
                preset_list+=("local:$lname_h")
            fi
        fi
    done

    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        local preset_dir=""
        if [[ "$item" == local:* ]]; then
            preset_dir="$PRESETS_DIR/${item#local:}"
        elif [[ "$item" == github:* ]]; then
            parse_github_source "github:${item#github:}"
            local hp2_sk="github:${_GH_OWNER}/${_GH_REPO}"
            [[ -n "$_GH_PATH" ]] && hp2_sk+="/${_GH_PATH}"
            preset_dir=$(resolve_locked_preset_dir "$hp2_sk" 2>/dev/null || true)
        fi
        [[ -z "$preset_dir" || ! -d "$preset_dir" ]] && continue
        find "$preset_dir" -type f -print0 | sort -z | xargs -0 "$_SHASUM_CMD" 2>/dev/null >> "$hash_tmp" || true
    done < <(collect_all_presets "${preset_list[@]+"${preset_list[@]}"}")

    # Hash workspace source dirs (Claude config files only)
    local ws_count
    ws_count=$(jq '.workspaces // [] | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    local hwi
    for ((hwi = 0; hwi < ws_count; hwi++)); do
        local ws_path
        ws_path=$(jq -r ".workspaces[$hwi].path" "$CONFIG_FILE")
        ws_path=$(expand_path "$ws_path")
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
            gws_path=$(expand_path "$gws_path")
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
        local abs_agent="$ORIGINAL_CWD/$agent_path"
        if [[ -f "$abs_agent" ]]; then "$_SHASUM_CMD" "$abs_agent" 2>/dev/null >> "$hash_tmp" || true; fi
    done <<< "$res_agents"

    local res_skills
    res_skills=$(jq -r '.resources.skills // [] | .[]' "$CONFIG_FILE" 2>/dev/null || true)
    while IFS= read -r skill_path; do
        [[ -z "$skill_path" ]] && continue
        local abs_skill="$ORIGINAL_CWD/$skill_path"
        if [[ -d "$abs_skill" ]]; then find "$abs_skill" \( -type f -o -type l \) -print0 2>/dev/null | sort -z | xargs -0 "$_SHASUM_CMD" 2>/dev/null >> "$hash_tmp" || true; fi
    done <<< "$res_skills"

    # Hash env files
    local res_env_files
    res_env_files=$(jq -r '.resources.env_files // [] | .[]' "$CONFIG_FILE" 2>/dev/null || true)
    while IFS= read -r env_file; do
        [[ -z "$env_file" ]] && continue
        local abs_env="$ORIGINAL_CWD/$env_file"
        if [[ -f "$abs_env" ]]; then "$_SHASUM_CMD" "$abs_env" 2>/dev/null >> "$hash_tmp" || true; fi
    done <<< "$res_env_files"

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
    fi

    local result
    result=$(_shasum256 < "$hash_tmp" | cut -c1-32)
    echo "$result"
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
