
# ── Embedded built-in plugin ────────────────────────────────────────
# The compose plugin is embedded at build time and extracted to
# ~/.claude-compose/compose-plugin/ on first run or when the version changes.

# Marker for Makefile injection — generates extract_embedded_plugin() function
__EMBEDDED_PLUGIN__

ensure_builtin_plugin() {
    # Migrate: remove old skills dir from pre-plugin versions
    if [[ -d "$HOME/.claude-compose/skills" ]]; then
        rm -rf "$HOME/.claude-compose/skills"
    fi

    local version_file="$BUILTIN_PLUGIN_DIR/.version"

    # Skip if already up to date
    if [[ -f "$version_file" ]] && [[ "$(cat "$version_file")" == "$VERSION" ]]; then
        return
    fi

    mkdir -p "$BUILTIN_PLUGIN_DIR"
    extract_embedded_plugin "$BUILTIN_PLUGIN_DIR"
    atomic_write "$version_file" "$VERSION"
}
