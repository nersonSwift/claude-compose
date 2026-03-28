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
        project_path=$(expand_path "$raw_path")
        claude_md=$(jq -r ".projects[$mpi].claude_md // true" "$CONFIG_FILE")
        project_name=$(jq -r ".projects[$mpi].name // empty" "$CONFIG_FILE")

        if [[ ! -d "$project_path" ]]; then
            [[ "$verbose" == "true" ]] && echo -e "${YELLOW}Warning: Project path not found, skipping: ${raw_path}${NC}" >&2
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
# Reads/appends globals: _SYSTEM_PROMPT, CONFIG_FILE, GLOBAL_CONFIG, GLOBAL_CONFIG_DIR, ORIGINAL_CWD.
# Sets global: _COMPOSE_SETTINGS (JSON string, starts as '{}').
# Side effects: appends to CLAUDE_ARGS, HAS_ANY_ADD_DIR, COMPOSE_CLAUDE_MD_EXCLUDES.
# Appends --append-system-prompt to CLAUDE_ARGS.
_collect_manifest_args() {
    local verbose="$1"
    _COMPOSE_SETTINGS='{}'

    # ── manifest sections: add_dirs, project_dirs, system_prompt_files, settings_files ──
    if [[ -f ".compose-manifest.json" ]]; then
        local section
        for section in global presets workspaces resources; do
            local source_names
            source_names=$(jq -r --arg s "$section" '.[$s] // {} | keys[]' ".compose-manifest.json" 2>/dev/null || true)
            while IFS= read -r sname; do
                [[ -z "$sname" ]] && continue

                # add_dirs: new format is [{path, claude_md}], old format was ["path"]
                local add_dir_entries
                add_dir_entries=$(jq -c --arg s "$section" --arg n "$sname" '.[$s][$n].add_dirs // [] | .[]' ".compose-manifest.json" 2>/dev/null || true)
                while IFS= read -r entry; do
                    [[ -z "$entry" ]] && continue
                    local dir cm_flag
                    if echo "$entry" | jq -e '.path' >/dev/null 2>&1; then
                        dir=$(echo "$entry" | jq -r '.path')
                        cm_flag=$(echo "$entry" | jq -r '.claude_md // true')
                    else
                        dir=$(echo "$entry" | jq -r '.')
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
                proj_dirs=$(jq -c --arg s "$section" --arg n "$sname" '.[$s][$n].project_dirs // [] | .[]' ".compose-manifest.json" 2>/dev/null || true)
                while IFS= read -r proj_entry; do
                    [[ -z "$proj_entry" ]] && continue
                    local proj_path proj_cmd
                    proj_path=$(echo "$proj_entry" | jq -r '.path')
                    proj_cmd=$(echo "$proj_entry" | jq -r '.claude_md')
                    if [[ -d "$proj_path" ]]; then
                        CLAUDE_ARGS+=("--add-dir" "$proj_path")
                        HAS_ANY_ADD_DIR=true
                        if [[ "$proj_cmd" != "true" ]]; then
                            COMPOSE_CLAUDE_MD_EXCLUDES+=("$proj_path")
                        fi
                    fi
                done <<< "$proj_dirs"

                # system_prompt_files from manifest
                local spf_list
                spf_list=$(jq -r --arg s "$section" --arg n "$sname" '.[$s][$n].system_prompt_files // [] | .[]' ".compose-manifest.json" 2>/dev/null || true)
                while IFS= read -r spf; do
                    [[ -z "$spf" || ! -f "$spf" ]] && continue
                    _SYSTEM_PROMPT+=$'\n\n'"$(cat "$spf")"
                done <<< "$spf_list"

                # settings_files from manifest
                local sf_list
                sf_list=$(jq -r --arg s "$section" --arg n "$sname" '.[$s][$n].settings_files // [] | .[]' ".compose-manifest.json" 2>/dev/null || true)
                while IFS= read -r sf; do
                    [[ -z "$sf" || ! -f "$sf" ]] && continue
                    if jq empty "$sf" 2>/dev/null; then
                        _COMPOSE_SETTINGS=$(merge_compose_settings "$_COMPOSE_SETTINGS" "$(cat "$sf")")
                    fi
                done <<< "$sf_list"
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
                [[ "$verbose" == "true" ]] && echo -e "${YELLOW}Warning: global system prompt file not found: ${aspf}${NC}" >&2
            fi
        done <<< "$global_aspf"
    fi

    local local_aspf
    local_aspf=$(jq -r '.resources.append_system_prompt_files // [] | .[]' "$CONFIG_FILE" 2>/dev/null || true)
    while IFS= read -r aspf; do
        [[ -z "$aspf" ]] && continue
        local abs_aspf="$ORIGINAL_CWD/$aspf"
        if [[ -f "$abs_aspf" ]]; then
            _SYSTEM_PROMPT+=$'\n\n'"$(cat "$abs_aspf")"
        else
            [[ "$verbose" == "true" ]] && echo -e "${YELLOW}Warning: system prompt file not found: ${aspf}${NC}" >&2
        fi
    done <<< "$local_aspf"

    CLAUDE_ARGS+=("--append-system-prompt" "$_SYSTEM_PROMPT")
}

# ── _build_settings ──────────────────────────────────────────────────
# Build claudeMdExcludes, merge global/local settings, write file.
# $1 = "true" for verbose warnings, "false" for silent.
# $2 = "true" to use absolute path for --settings (wrap mode), "false" for relative.
# Reads/writes: _COMPOSE_SETTINGS, COMPOSE_CLAUDE_MD_EXCLUDES.
# Side effects: appends to CLAUDE_ARGS. Writes .compose-settings.json (skipped when DRY_RUN=true).
_build_settings() {
    local verbose="$1" use_absolute="$2"

    # Build claudeMdExcludes from collected paths
    if [[ ${#COMPOSE_CLAUDE_MD_EXCLUDES[@]} -gt 0 ]]; then
        local excludes_json="[]"
        local exc_path
        for exc_path in "${COMPOSE_CLAUDE_MD_EXCLUDES[@]}"; do
            excludes_json=$(echo "$excludes_json" | jq --arg p "$exc_path" '. + [$p + "/CLAUDE.md", $p + "/.claude/CLAUDE.md", $p + "/.claude/rules/*.md"]')
        done
        _COMPOSE_SETTINGS=$(echo "$_COMPOSE_SETTINGS" | jq --argjson exc "$excludes_json" '.claudeMdExcludes = $exc')
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
                [[ "$verbose" == "true" ]] && echo -e "${YELLOW}Warning: global settings file not found or invalid: ${global_sp}${NC}" >&2
            fi
        fi
    fi

    local local_sp
    local_sp=$(jq -r '.resources.settings // empty' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ -n "$local_sp" ]]; then
        local abs_ls="$ORIGINAL_CWD/$local_sp"
        if [[ -f "$abs_ls" ]] && jq empty "$abs_ls" 2>/dev/null; then
            _COMPOSE_SETTINGS=$(merge_compose_settings "$_COMPOSE_SETTINGS" "$(cat "$abs_ls")")
        else
            [[ "$verbose" == "true" ]] && echo -e "${YELLOW}Warning: settings file not found or invalid: ${local_sp}${NC}" >&2
        fi
    fi

    # Write and pass --settings
    if [[ "$_COMPOSE_SETTINGS" != '{}' ]]; then
        if [[ "$DRY_RUN" != true ]]; then
            atomic_write ".compose-settings.json" "$(echo "$_COMPOSE_SETTINGS" | jq '.')"
        fi
        if [[ "$use_absolute" == "true" ]]; then
            CLAUDE_ARGS+=("--settings" "$(pwd -P)/.compose-settings.json")
        else
            CLAUDE_ARGS+=("--settings" ".compose-settings.json")
        fi
    else
        rm -f ".compose-settings.json" 2>/dev/null || true
    fi
}
