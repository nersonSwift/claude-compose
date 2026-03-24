
# ── Embedded built-in skills ────────────────────────────────────────
# Skills are embedded at build time and extracted to ~/.claude-compose/skills/
# on first run or when the version changes.

# Marker for Makefile injection — generates extract_embedded_skills() function
__EMBEDDED_SKILLS__

ensure_builtin_skills() {
    local version_file="$BUILTIN_SKILLS_DIR/.version"

    # Skip if already up to date
    if [[ -f "$version_file" ]] && [[ "$(cat "$version_file")" == "$VERSION" ]]; then
        return
    fi

    mkdir -p "$BUILTIN_SKILLS_DIR"
    extract_embedded_skills "$BUILTIN_SKILLS_DIR"
    atomic_write "$version_file" "$VERSION"
}
