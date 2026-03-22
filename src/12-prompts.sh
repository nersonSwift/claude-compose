
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

compose_fix_prompt() {
    local config_file="$1"
    local error_msg="$2"
    local prompt
    IFS= read -r -d '' prompt <<'PROMPT_EOF' || true
__PROMPT_COMPOSE_FIX__
PROMPT_EOF
    prompt="${prompt//__CONFIG_FILE__/$config_file}"
    prompt="${prompt//__ERROR__/$error_msg}"
    echo "$prompt"
}
