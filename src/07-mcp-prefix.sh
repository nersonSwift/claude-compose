# ── Env var prefixing for nested sources ─────────────────────────────

# Compute a prefix for env vars from a source: {name}_{hash4}_
compute_source_prefix() {
    local name="$1" abs_path="$2"
    # Sanitize name: replace non-alphanumeric chars with underscore (shell var names)
    local safe_name
    safe_name=$(printf '%s' "$name" | tr -c '[:alnum:]_' '_')
    local hash4
    hash4=$(printf '%s' "$abs_path" | _shasum256 | cut -c1-4)
    echo "${safe_name}_${hash4}_"
}

# Transform ${VAR} references in MCP server config's env block
# Only prefixes vars that are defined in the source's env_files (not system vars like HOME)
# $1 = server config JSON, $2 = prefix, $3 = known var names (newline-separated)
prefix_env_vars_in_mcp() {
    local config="$1" prefix="$2" known_vars="$3"
    if [[ -z "$known_vars" ]]; then
        # No known vars — nothing to prefix
        echo "$config"
        return
    fi
    # Build jq array of known var names
    local vars_json
    vars_json=$(printf '%s\n' "$known_vars" | jq -R -s 'split("\n") | map(select(. != ""))')
    echo "$config" | jq --arg pfx "$prefix" --argjson known "$vars_json" '
      if .env then .env |= with_entries(
        if (.value | type) == "string" then
          .value |= reduce $known[] as $var (.; gsub("\\$\\{" + $var + "\\}"; "${\($pfx)\($var)}"))
        else . end
      ) else . end'
}
