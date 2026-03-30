# ── Shared Arg Collection ─────────────────────────────────────────────
# Shared helpers used by both main() and cmd_wrap() to collect --add-dir,
# system prompt, and settings arguments. Extracted to eliminate duplication.
#
# Call order (mandatory):
#   1. _collect_project_args "$verbose"
#   2. _init_system_prompt
#   3. _collect_manifest_args "$verbose"
#   4. _build_settings "$verbose" "$use_absolute_path"

# ── _collect_project_args ────────────────────────────────────────────
# Collect --add-dir from config projects and build alias list.
# $1 = "true" for verbose warnings/info, "false" for silent.
# Side effects: appends to CLAUDE_ARGS, HAS_ANY_ADD_DIR, COMPOSE_CLAUDE_MD_EXCLUDES.
# Sets global: _PROJECT_ALIASES (newline-separated "- name: path" lines, or empty).
_collect_project_args() {
    local verbose="$1"
    _PROJECT_ALIASES=""

    local project_count
    project_count=$(jq '.projects // [] | length' "$CONFIG_FILE")
    [[ "$project_count" -eq 0 ]] && return 0

    local mpi
    for ((mpi = 0; mpi < project_count; mpi++)); do
        local raw_path project_path claude_md project_name
        raw_path=$(jq -r ".projects[$mpi].path" "$CONFIG_FILE")
        project_path=$(expand_path "$raw_path" "$CONFIG_DIR")
        claude_md=$(jq -r ".projects[$mpi].claude_md // true" "$CONFIG_FILE")
        project_name=$(jq -r ".projects[$mpi].name // empty" "$CONFIG_FILE")
        # Sanitize: strip newlines/control chars to prevent prompt injection via config
        project_name="${project_name//$'\n'/}"
        project_name="${project_name//$'\r'/}"

        if [[ ! -d "$project_path" ]]; then
            warn_critical "projects" "Project path not found, skipping: ${raw_path}" "$verbose"
            continue
        fi

        CLAUDE_ARGS+=("--add-dir" "$project_path")
        [[ "$verbose" == "true" ]] && echo -e "${CYAN}Project:${NC} $(basename "$project_path") (${project_path})" >&2

        HAS_ANY_ADD_DIR=true
        if [[ "$claude_md" != "true" ]]; then
            COMPOSE_CLAUDE_MD_EXCLUDES+=("$project_path")
        fi

        if [[ -n "$project_name" ]]; then
            _PROJECT_ALIASES+="- ${project_name}: ${project_path}"$'\n'
        fi
    done
}

# ── _init_system_prompt ──────────────────────────────────────────────
# Create system prompt with project aliases appended.
# Must be called AFTER _collect_project_args and BEFORE _collect_manifest_args.
# Sets global: _SYSTEM_PROMPT
_init_system_prompt() {
    _SYSTEM_PROMPT=$(compose_system_prompt)

    if [[ -n "$_PROJECT_ALIASES" ]]; then
        _SYSTEM_PROMPT+=$'\n'"Projects in this workspace:"$'\n'"${_PROJECT_ALIASES%$'\n'}"
        _SYSTEM_PROMPT+=$'\n'"Use name:// to reference files in a project (e.g. project://path/to/file)."
    fi
}

# ── _collect_manifest_args ───────────────────────────────────────────
# Process manifest add_dirs/project_dirs/system_prompt_files/settings_files
# and append_system_prompt_files from global + local config.
# $1 = "true" for verbose warnings, "false" for silent.
# Reads/appends globals: _SYSTEM_PROMPT, CONFIG_FILE, GLOBAL_CONFIG, GLOBAL_CONFIG_DIR, CONFIG_DIR.
# Sets global: _COMPOSE_SETTINGS (JSON string, starts as '{}').
# Side effects: appends to CLAUDE_ARGS, HAS_ANY_ADD_DIR, COMPOSE_CLAUDE_MD_EXCLUDES.
# Appends --append-system-prompt to CLAUDE_ARGS.
_collect_manifest_args() {
    local verbose="$1"
    _COMPOSE_SETTINGS='{}'

    # ── manifest sections: add_dirs, project_dirs, system_prompt_files, settings_files ──
    if [[ -f "$COMPOSE_MANIFEST" ]]; then
        local section
        for section in global workspaces resources; do
            local source_names
            source_names=$(jq -r --arg s "$section" '.[$s] // {} | keys[]' "$COMPOSE_MANIFEST" 2>/dev/null || true)
            while IFS= read -r sname; do
                [[ -z "$sname" ]] && continue

                # add_dirs: new format is [{path, claude_md}], old format was ["path"]
                local add_dir_entries
                add_dir_entries=$(jq -c --arg s "$section" --arg n "$sname" '.[$s][$n].add_dirs // [] | .[]' "$COMPOSE_MANIFEST" 2>/dev/null || true)
                while IFS= read -r entry; do
                    [[ -z "$entry" ]] && continue
                    local dir cm_flag
                    if jq -e '.path' <<< "$entry" >/dev/null 2>&1; then
                        dir=$(jq -r '.path' <<< "$entry")
                        cm_flag=$(jq -r '.claude_md // true' <<< "$entry")
                    else
                        dir=$(jq -r '.' <<< "$entry")
                        cm_flag="true"
                    fi
                    [[ -z "$dir" || ! -d "$dir" ]] && continue
                    CLAUDE_ARGS+=("--add-dir" "$dir")
                    HAS_ANY_ADD_DIR=true
                    if [[ "$cm_flag" != "true" ]]; then
                        COMPOSE_CLAUDE_MD_EXCLUDES+=("$dir")
                    fi
                done <<< "$add_dir_entries"

                # project_dirs: transitive projects
                local proj_dirs
                proj_dirs=$(jq -c --arg s "$section" --arg n "$sname" '.[$s][$n].project_dirs // [] | .[]' "$COMPOSE_MANIFEST" 2>/dev/null || true)
                while IFS= read -r proj_entry; do
                    [[ -z "$proj_entry" ]] && continue
                    local proj_path proj_cmd
                    proj_path=$(jq -r '.path' <<< "$proj_entry")
                    proj_cmd=$(jq -r '.claude_md' <<< "$proj_entry")
                    # Direct-wins dedup: skip if already directly configured
                    local _is_direct=false _ddp
                    for _ddp in "${DIRECT_PROJECT_PATHS[@]+"${DIRECT_PROJECT_PATHS[@]}"}"; do
                        [[ "$_ddp" == "$proj_path" ]] && _is_direct=true && break
                    done
                    [[ "$_is_direct" == "true" ]] && continue
                    if [[ -d "$proj_path" ]]; then
                        CLAUDE_ARGS+=("--add-dir" "$proj_path")
                        HAS_ANY_ADD_DIR=true
                        if [[ "$proj_cmd" != "true" ]]; then
                            COMPOSE_CLAUDE_MD_EXCLUDES+=("$proj_path")
                        fi
                    fi
                done <<< "$proj_dirs"

            done <<< "$source_names"
        done
    fi

    # ── append_system_prompt_files: global then local ──
    if [[ -f "$GLOBAL_CONFIG" ]]; then
        local global_aspf
        global_aspf=$(jq -r '.resources.append_system_prompt_files // [] | .[]' "$GLOBAL_CONFIG" 2>/dev/null || true)
        while IFS= read -r aspf; do
            [[ -z "$aspf" ]] && continue
            local abs_aspf="$GLOBAL_CONFIG_DIR/$aspf"
            if [[ -f "$abs_aspf" ]]; then
                _SYSTEM_PROMPT+=$'\n\n'"$(cat "$abs_aspf")"
            else
                warn_critical "resources" "Global system prompt file not found: ${aspf}" "$verbose"
            fi
        done <<< "$global_aspf"
    fi

    local local_aspf
    local_aspf=$(jq -r '.resources.append_system_prompt_files // [] | .[]' "$CONFIG_FILE" 2>/dev/null || true)
    while IFS= read -r aspf; do
        [[ -z "$aspf" ]] && continue
        local abs_aspf="$CONFIG_DIR/$aspf"
        if [[ -f "$abs_aspf" ]]; then
            _SYSTEM_PROMPT+=$'\n\n'"$(cat "$abs_aspf")"
        else
            warn_critical "resources" "System prompt file not found: ${aspf}" "$verbose"
        fi
    done <<< "$local_aspf"

    CLAUDE_ARGS+=("--append-system-prompt" "$_SYSTEM_PROMPT")
}

# ── _build_settings ──────────────────────────────────────────────────
# Build claudeMdExcludes, merge global/local settings, write file.
# $1 = "true" for verbose warnings, "false" for silent.
# $2 = "true" to use absolute path for --settings (wrap mode), "false" for relative.
# Reads/writes: _COMPOSE_SETTINGS, COMPOSE_CLAUDE_MD_EXCLUDES.
# Side effects: appends to CLAUDE_ARGS. Writes $COMPOSE_SETTINGS (skipped when DRY_RUN=true).
_build_settings() {
    local verbose="$1" use_absolute="$2"

    # Build claudeMdExcludes from collected paths
    if [[ ${#COMPOSE_CLAUDE_MD_EXCLUDES[@]} -gt 0 ]]; then
        local excludes_json="[]"
        local exc_path
        for exc_path in "${COMPOSE_CLAUDE_MD_EXCLUDES[@]}"; do
            excludes_json=$(jq --arg p "$exc_path" '. + [$p + "/CLAUDE.md", $p + "/.claude/CLAUDE.md", $p + "/.claude/rules/*.md"]' <<< "$excludes_json")
        done
        _COMPOSE_SETTINGS=$(jq --argjson exc "$excludes_json" '.claudeMdExcludes = $exc' <<< "$_COMPOSE_SETTINGS")
    fi

    # Merge settings: compose-generated (base) → global overlay → local overlay (local wins)
    if [[ -f "$GLOBAL_CONFIG" ]]; then
        local global_sp
        global_sp=$(jq -r '.resources.settings // empty' "$GLOBAL_CONFIG" 2>/dev/null || true)
        if [[ -n "$global_sp" ]]; then
            local abs_gs="$GLOBAL_CONFIG_DIR/$global_sp"
            if [[ -f "$abs_gs" ]] && jq empty "$abs_gs" 2>/dev/null; then
                _COMPOSE_SETTINGS=$(merge_compose_settings "$_COMPOSE_SETTINGS" "$(cat "$abs_gs")")
            else
                warn_critical "resources" "Global settings file not found or invalid: ${global_sp}" "$verbose"
            fi
        fi
    fi

    local local_sp
    local_sp=$(jq -r '.resources.settings // empty' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ -n "$local_sp" ]]; then
        local abs_ls="$CONFIG_DIR/$local_sp"
        if [[ -f "$abs_ls" ]] && jq empty "$abs_ls" 2>/dev/null; then
            _COMPOSE_SETTINGS=$(merge_compose_settings "$_COMPOSE_SETTINGS" "$(cat "$abs_ls")")
        else
            warn_critical "resources" "Settings file not found or invalid: ${local_sp}" "$verbose"
        fi
    fi

    # Merge enabledPlugins from marketplace plugins
    if [[ ${#MARKETPLACE_PLUGINS[@]} -gt 0 ]]; then
        local enabled_json='{}'
        local mp
        for mp in "${MARKETPLACE_PLUGINS[@]}"; do
            enabled_json=$(jq --arg k "$mp" '.[$k] = true' <<< "$enabled_json")
        done
        _COMPOSE_SETTINGS=$(jq --argjson ep "$enabled_json" '.enabledPlugins = ((.enabledPlugins // {}) + $ep)' <<< "$_COMPOSE_SETTINGS")
    fi

    # Merge extraKnownMarketplaces from config
    local mkts
    mkts=$(jq -c '.marketplaces // {}' "$CONFIG_FILE" 2>/dev/null || echo '{}')
    if [[ "$mkts" != "{}" && "$mkts" != "null" ]]; then
        _COMPOSE_SETTINGS=$(jq --argjson m "$mkts" '.extraKnownMarketplaces = ((.extraKnownMarketplaces // {}) + $m)' <<< "$_COMPOSE_SETTINGS")
    fi
    if [[ -f "$GLOBAL_CONFIG" ]]; then
        local global_mkts
        global_mkts=$(jq -c '.marketplaces // {}' "$GLOBAL_CONFIG" 2>/dev/null || echo '{}')
        if [[ "$global_mkts" != "{}" && "$global_mkts" != "null" ]]; then
            _COMPOSE_SETTINGS=$(jq --argjson m "$global_mkts" '.extraKnownMarketplaces = ((.extraKnownMarketplaces // {}) + $m)' <<< "$_COMPOSE_SETTINGS")
        fi
    fi

    # Write and pass --settings
    if [[ "$_COMPOSE_SETTINGS" != '{}' ]]; then
        if [[ "$DRY_RUN" != true ]]; then
            ensure_compose_dir
            atomic_write "$COMPOSE_SETTINGS" "$(jq '.' <<< "$_COMPOSE_SETTINGS")"
        fi
        if [[ "$use_absolute" == "true" ]]; then
            CLAUDE_ARGS+=("--settings" "$(pwd -P)/$COMPOSE_SETTINGS")
        else
            CLAUDE_ARGS+=("--settings" "$COMPOSE_SETTINGS")
        fi
    else
        rm -f "$COMPOSE_SETTINGS" 2>/dev/null || true
    fi
}

# ── _is_plugin_installed ─────────────────────────────────────────
# Check if a marketplace plugin is already installed.
# $1 = plugin identifier (e.g. "ralph-loop" or "ralph-loop@mkt")
_is_plugin_installed() {
    local plugin_id="$1"
    local installed="$HOME/.claude/plugins/installed_plugins.json"
    [[ -f "$installed" ]] && jq -e --arg p "$plugin_id" '.plugins[$p] | length > 0' "$installed" &>/dev/null
}

# ── _install_marketplace_plugin ──────────────────────────────────
# Install a marketplace plugin if not already installed.
# $1 = plugin name (e.g. "ralph-loop" or "code-review@my-marketplace")
_install_marketplace_plugin() {
    local name="$1"
    if _is_plugin_installed "$name"; then
        return 0
    fi
    echo -e "${CYAN}Installing plugin: $name${NC}" >&2
    if ! claude plugins install "$name" --scope user 2>&1; then
        warn_critical "plugins" "Failed to install plugin: $name"
        return 1
    fi
}

# ── Plugin dedup helpers (last wins) ─────────────────────────────
_dedup_plugin_dir() {
    local target="$1" i new=()
    for i in "${PLUGIN_DIRS[@]+"${PLUGIN_DIRS[@]}"}"; do
        [[ "$i" != "$target" ]] && new+=("$i")
    done
    PLUGIN_DIRS=("${new[@]+"${new[@]}"}")
}

_dedup_marketplace_plugin() {
    local target="$1" i new=()
    for i in "${MARKETPLACE_PLUGINS[@]+"${MARKETPLACE_PLUGINS[@]}"}"; do
        [[ "$i" != "$target" ]] && new+=("$i")
    done
    MARKETPLACE_PLUGINS=("${new[@]+"${new[@]}"}")
}

# ── _resolve_single_plugin ──────────────────────────────────────
# Resolve a single plugin entry from a config file.
# $1 = config file, $2 = plugin index, $3 = base dir for relative paths
# Populates PLUGIN_DIRS[], MARKETPLACE_PLUGINS[], PLUGIN_CONFIG_ENVS[]
_resolve_single_plugin() {
    local config_file="$1" pi="$2" base_dir="$3"

    local entry_type
    entry_type=$(jq -r ".plugins[$pi] | type" "$config_file")

    if [[ "$entry_type" == "string" ]]; then
        local str_val
        str_val=$(jq -r ".plugins[$pi]" "$config_file")
        if [[ "$str_val" == ./* || "$str_val" == ~* || "$str_val" == /* ]]; then
            local plugin_dir
            plugin_dir=$(expand_path "$str_val")
            [[ "$plugin_dir" != /* ]] && plugin_dir="$base_dir/$plugin_dir"
            if [[ -d "$plugin_dir" ]]; then
                _dedup_plugin_dir "$plugin_dir"
                PLUGIN_DIRS+=("$plugin_dir")
            else
                warn_critical "plugins" "Plugin directory not found: ${plugin_dir}"
            fi
        else
            _dedup_marketplace_plugin "$str_val"
            _install_marketplace_plugin "$str_val" || true
            MARKETPLACE_PLUGINS+=("$str_val")
        fi

    elif [[ "$entry_type" == "object" ]]; then
        local p_path p_name
        p_path=$(jq -r ".plugins[$pi].path // empty" "$config_file")
        p_name=$(jq -r ".plugins[$pi].name // empty" "$config_file")

        if [[ -n "$p_path" ]]; then
            local plugin_dir
            plugin_dir=$(expand_path "$p_path")
            [[ "$plugin_dir" != /* ]] && plugin_dir="$base_dir/$plugin_dir"
            if [[ -d "$plugin_dir" ]]; then
                _dedup_plugin_dir "$plugin_dir"
                PLUGIN_DIRS+=("$plugin_dir")
            else
                warn_critical "plugins" "Plugin directory not found: ${plugin_dir}"
            fi
        elif [[ -n "$p_name" ]]; then
            _dedup_marketplace_plugin "$p_name"
            _install_marketplace_plugin "$p_name" || true
            MARKETPLACE_PLUGINS+=("$p_name")

            # Parse config keys → CLAUDE_PLUGIN_OPTION_* env vars
            local has_config
            has_config=$(jq -r ".plugins[$pi] | has(\"config\")" "$config_file")
            if [[ "$has_config" == "true" ]]; then
                local config_keys
                config_keys=$(jq -r ".plugins[$pi].config | keys[]" "$config_file" 2>/dev/null || true)
                while IFS= read -r ckey; do
                    [[ -z "$ckey" ]] && continue
                    local cval upper_key
                    cval=$(jq -r --arg k "$ckey" ".plugins[$pi].config[\$k]" "$config_file")
                    upper_key=$(echo "$ckey" | tr '[:lower:]' '[:upper:]')
                    # Remove old config for this key (last wins)
                    local _env_new=() _e
                    for _e in "${PLUGIN_CONFIG_ENVS[@]+"${PLUGIN_CONFIG_ENVS[@]}"}"; do
                        [[ "$_e" != "CLAUDE_PLUGIN_OPTION_${upper_key}="* ]] && _env_new+=("$_e")
                    done
                    PLUGIN_CONFIG_ENVS=("${_env_new[@]+"${_env_new[@]}"}")
                    PLUGIN_CONFIG_ENVS+=("CLAUDE_PLUGIN_OPTION_${upper_key}=${cval}")
                done <<< "$config_keys"
            fi
        fi
    fi
}

# ── resolve_plugins ───────────────────────────────────────────────
# Resolve plugins from config: local paths → PLUGIN_DIRS[], marketplace names → MARKETPLACE_PLUGINS[].
# $1 = config file, $2 = base directory for relative path resolution.
resolve_plugins() {
    local config_file="$1" base_dir="$2"
    [[ ! -f "$config_file" ]] && return

    local plugin_count
    plugin_count=$(jq '.plugins // [] | length' "$config_file" 2>/dev/null || echo 0)
    if [[ "$plugin_count" -eq 0 ]]; then
        _PLUGINS_RESOLVED=true
        return
    fi

    local pi
    for ((pi = 0; pi < plugin_count; pi++)); do
        _resolve_single_plugin "$config_file" "$pi" "$base_dir"
    done
    _PLUGINS_RESOLVED=true
}

# ── collect_workspace_plugins ────────────────────────────────────
# Collect plugins from a workspace's claude-compose.json, applying include/exclude.
# $1 = workspace config file, $2 = workspace base dir, $3 = filter JSON
collect_workspace_plugins() {
    local ws_config="$1" ws_base_dir="$2" filter_json="$3"
    [[ ! -f "$ws_config" ]] && return

    local plugin_count
    plugin_count=$(jq '.plugins // [] | length' "$ws_config" 2>/dev/null || echo 0)
    [[ "$plugin_count" -eq 0 ]] && return

    local plugins_include plugins_exclude
    plugins_include=$(jq -c '.plugins.include // ["*"]' <<< "$filter_json")
    plugins_exclude=$(jq -c '.plugins.exclude // []' <<< "$filter_json")

    local pi
    for ((pi = 0; pi < plugin_count; pi++)); do
        # Determine plugin identifier for filtering
        local plugin_id=""
        local entry_type
        entry_type=$(jq -r ".plugins[$pi] | type" "$ws_config")
        if [[ "$entry_type" == "string" ]]; then
            local str_val
            str_val=$(jq -r ".plugins[$pi]" "$ws_config")
            if [[ "$str_val" == ./* || "$str_val" == ~* || "$str_val" == /* ]]; then
                plugin_id=$(basename "$str_val")
            else
                plugin_id="$str_val"
            fi
        elif [[ "$entry_type" == "object" ]]; then
            local p_path p_name
            p_path=$(jq -r ".plugins[$pi].path // empty" "$ws_config")
            p_name=$(jq -r ".plugins[$pi].name // empty" "$ws_config")
            plugin_id="${p_name:-$(basename "${p_path:-unknown}")}"
        fi

        [[ -z "$plugin_id" ]] && continue
        matches_filter "$plugin_id" "$plugins_include" "$plugins_exclude" || continue

        # Resolve using shared helper (with ws_base_dir for relative paths)
        _resolve_single_plugin "$ws_config" "$pi" "$ws_base_dir"
    done
}

# ── _collect_plugin_args ──────────────────────────────────────────
# Resolve plugins (if not already done) and append --plugin-dir to CLAUDE_ARGS.
# $1 = "true" for verbose, "false" for silent.
# $2 = base directory for relative path resolution.
_collect_plugin_args() {
    local verbose="$1" base_dir="$2"

    # Guard: only resolve once (even if no plugins found)
    if [[ "$_PLUGINS_RESOLVED" != "true" ]]; then
        resolve_plugins "$CONFIG_FILE" "$base_dir"
        [[ -f "$GLOBAL_CONFIG" ]] && resolve_plugins "$GLOBAL_CONFIG" "$GLOBAL_CONFIG_DIR"
    fi

    # Always include built-in compose plugin first
    if [[ -d "$BUILTIN_PLUGIN_DIR/.claude-plugin" ]]; then
        local _already=false _pd
        for _pd in "${PLUGIN_DIRS[@]+"${PLUGIN_DIRS[@]}"}"; do
            [[ "$_pd" == "$BUILTIN_PLUGIN_DIR" ]] && _already=true && break
        done
        [[ "$_already" == false ]] && PLUGIN_DIRS=("$BUILTIN_PLUGIN_DIR" "${PLUGIN_DIRS[@]+"${PLUGIN_DIRS[@]}"}")
    fi

    local pdir
    for pdir in "${PLUGIN_DIRS[@]+"${PLUGIN_DIRS[@]}"}"; do
        CLAUDE_ARGS+=("--plugin-dir" "$pdir")
        [[ "$verbose" == "true" ]] && echo -e "${CYAN}Plugin:${NC} $(basename "$pdir") (${pdir})" >&2
    done

    # Export plugin config env vars
    local env_pair
    for env_pair in "${PLUGIN_CONFIG_ENVS[@]+"${PLUGIN_CONFIG_ENVS[@]}"}"; do
        # shellcheck disable=SC2163
        export "$env_pair"
    done
}
