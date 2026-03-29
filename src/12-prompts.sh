
# ── Prompt functions ─────────────────────────────────────────────────

compose_config_prompt() {
    local config_file="$1"
    local prompt
    IFS= read -r -d '' prompt <<'PROMPT_EOF' || true
__PROMPT_COMPOSE_CONFIG__
PROMPT_EOF
    # Interpolate placeholders
    local default_marker f_flag
    if [[ "$config_file" == "claude-compose.json" ]]; then
        default_marker=" (default)"; f_flag=""
    else
        default_marker=""; f_flag=" -f ${config_file}"
    fi
    prompt="${prompt//__CONFIG_FILE__/$config_file}"
    prompt="${prompt//__CONFIG_DEFAULT__/$default_marker}"
    prompt="${prompt//__CONFIG_F_FLAG__/$f_flag}"
    echo "$prompt"
}

compose_system_prompt() {
    local prompt
    IFS= read -r -d '' prompt <<'PROMPT_EOF' || true
__PROMPT_COMPOSE_SYSTEM__
PROMPT_EOF
    echo "$prompt"
}

compose_instructions_prompt() {
    local workspace_summary="$1"
    local prompt
    IFS= read -r -d '' prompt <<'PROMPT_EOF' || true
__PROMPT_COMPOSE_INSTRUCTIONS__
PROMPT_EOF
    prompt="${prompt//__WORKSPACE_SUMMARY__/$workspace_summary}"
    echo "$prompt"
}

compose_doctor_prompt() {
    local config_file="$1"
    local workspace_dir="$2"
    local error_msg="$3"
    local prompt
    IFS= read -r -d '' prompt <<'PROMPT_EOF' || true
__PROMPT_COMPOSE_DOCTOR__
PROMPT_EOF
    prompt="${prompt//__CONFIG_FILE__/$config_file}"
    prompt="${prompt//__WORKSPACE_DIR__/$workspace_dir}"

    if [[ -n "$error_msg" ]]; then
        # Sanitize: remove backticks to prevent code fence breakout in prompt
        local sanitized_msg="${error_msg//\`/}"
        prompt="${prompt//__ERROR_CONTEXT__/$sanitized_msg}"
        prompt="${prompt//__DOCTOR_MODE__/analyze and fix the error below}"
    else
        prompt="${prompt//__ERROR_CONTEXT__/No error — manual diagnostic session}"
        prompt="${prompt//__DOCTOR_MODE__/interactive — ask the user what problem they are experiencing}"
    fi

    # Build workspace summary
    local ws_summary="(no config file found)"
    if [[ -f "$config_file" ]] && jq empty "$config_file" 2>/dev/null; then
        local pc wsc ac sc mc ec
        pc=$(jq '.projects // [] | length' "$config_file" 2>/dev/null || echo 0)
        wsc=$(jq '.workspaces // [] | length' "$config_file" 2>/dev/null || echo 0)
        ac=$(jq '.resources.agents // [] | length' "$config_file" 2>/dev/null || echo 0)
        sc=$(jq '.resources.skills // [] | length' "$config_file" 2>/dev/null || echo 0)
        mc=$(jq '.resources.mcp // {} | length' "$config_file" 2>/dev/null || echo 0)
        ec=$(jq '.resources.env_files // [] | length' "$config_file" 2>/dev/null || echo 0)
        ws_summary="Projects: ${pc}, Workspaces: ${wsc}, Resources: ${ac} agents, ${sc} skills, ${mc} MCP servers, ${ec} env files"
    fi
    prompt="${prompt//__WORKSPACE_SUMMARY__/$ws_summary}"

    echo "$prompt"
}

compose_start_prompt() {
    local root_path="$1"
    local prompt
    IFS= read -r -d '' prompt <<'PROMPT_EOF' || true
__PROMPT_COMPOSE_START__
PROMPT_EOF
    if [[ -n "$root_path" ]]; then
        prompt="${prompt//__START_ROOT_PATH__/$root_path}"
    else
        prompt="${prompt//__START_ROOT_PATH__/not specified — ask the user}"
    fi
    echo "$prompt"
}
