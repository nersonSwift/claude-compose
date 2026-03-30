
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
        # Sanitize: remove chars that could cause prompt injection or code fence breakout
        local sanitized_msg="${error_msg//\`/}"
        sanitized_msg="${sanitized_msg//\$/}"
        sanitized_msg="${sanitized_msg//\\/}"
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
        read -r pc wsc ac sc mc ec < <(jq -r '[
            (.projects//[]|length), (.workspaces//[]|length),
            (.resources.agents//[]|length), (.resources.skills//[]|length),
            (.resources.mcp//{}|length), (.resources.env_files//[]|length)
        ] | @tsv' "$config_file" 2>/dev/null || echo "0	0	0	0	0	0")
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
