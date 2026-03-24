# ── Registry: GitHub-based remote presets ──────────────────────────────

# ── Git dependency check ──────────────────────────────────────────────
require_git() {
    if ! command -v git &>/dev/null; then
        die_doctor "git is required for GitHub presets but not installed. Install: brew install git / apt install git"
    fi
}

# Check if any config has github: presets (used for conditional git check)
has_github_presets() {
    local config_file="$1"
    [[ ! -f "$config_file" ]] && return 1
    local count
    count=$(jq '[.presets // [] | .[] | select(type == "object" and .source and (.source | startswith("github:")))] | length' "$config_file" 2>/dev/null || echo 0)
    [[ "$count" -gt 0 ]]
}

# ── Registry directory helpers ────────────────────────────────────────

registry_version_dir() {
    local owner="$1" repo="$2" version="$3"
    echo "$REGISTRIES_DIR/$owner/$repo/v$version"
}

registry_has_clone() {
    local owner="$1" repo="$2" version="$3"
    local dir
    dir=$(registry_version_dir "$owner" "$repo" "$version")
    [[ -d "$dir/.git" ]]
}

registry_preset_dir() {
    local owner="$1" repo="$2" version="$3" preset_path="$4"
    local base
    base=$(registry_version_dir "$owner" "$repo" "$version")
    if [[ -n "$preset_path" ]]; then
        echo "$base/$preset_path"
    else
        echo "$base"
    fi
}

# ── Git operations ────────────────────────────────────────────────────

registry_clone_version() {
    local owner="$1" repo="$2" tag="$3"
    local dir
    dir=$(registry_version_dir "$owner" "$repo" "${tag#v}")

    # Already cloned
    if [[ -d "$dir/.git" ]]; then
        return 0
    fi

    # Corrupted: dir exists but no .git
    if [[ -d "$dir" && ! -d "$dir/.git" ]]; then
        rm -rf "$dir"
    fi

    mkdir -p "$(dirname "$dir")"

    echo -e "  ${CYAN}Cloning:${NC} ${owner}/${repo}@${tag}" >&2
    if ! GIT_TERMINAL_PROMPT=0 git clone --quiet --branch "$tag" --depth 1 \
        "https://github.com/$owner/$repo.git" "$dir" 2>/dev/null; then
        rm -rf "$dir"
        echo -e "${RED}Error: Failed to clone github:${owner}/${repo}@${tag}${NC}" >&2
        return 1
    fi
}

# List remote tags from a GitHub repo. Uses an existing clone if available,
# otherwise does ls-remote against GitHub.
registry_list_remote_tags() {
    local owner="$1" repo="$2"

    local tags_output
    if ! tags_output=$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags --refs \
        "https://github.com/$owner/$repo.git" 2>/dev/null); then
        return 1
    fi

    # Extract tag names: refs/tags/v1.2.3 → v1.2.3
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "${line##*refs/tags/}"
    done <<< "$tags_output"
}

# ── Semver parsing ────────────────────────────────────────────────────

# Parse github:owner/repo/path@spec and set _GH_OWNER, _GH_REPO, _GH_PATH, _GH_SPEC
# path may be empty, spec may be empty
parse_github_source() {
    local source="$1"
    # Strip github: prefix
    local rest="${source#github:}"

    # Split on @ for version spec
    _GH_SPEC=""
    local path_part
    if [[ "$rest" == *@* ]]; then
        _GH_SPEC="${rest##*@}"
        path_part="${rest%@*}"
    else
        path_part="$rest"
    fi

    # Split path_part: owner/repo[/preset_path]
    _GH_OWNER="${path_part%%/*}"
    local after_owner="${path_part#*/}"
    _GH_PATH=""
    if [[ "$after_owner" == */* ]]; then
        _GH_REPO="${after_owner%%/*}"
        _GH_PATH="${after_owner#*/}"
    else
        _GH_REPO="$after_owner"
    fi
}

# Parse version spec string → prints "type major minor patch"
# Types: exact, tilde, caret, latest
parse_version_spec() {
    local spec="$1"

    if [[ -z "$spec" ]]; then
        echo "latest 0 0 0"
        return
    fi

    local type="" version_str=""
    case "$spec" in
        "~"*)
            type="tilde"
            version_str="${spec#\~}"
            ;;
        "^"*)
            type="caret"
            version_str="${spec#^}"
            ;;
        *)
            type="exact"
            version_str="$spec"
            ;;
    esac

    local major=0 minor=0 patch=0
    IFS='.' read -r major minor patch <<< "$version_str"
    major="${major:-0}"
    minor="${minor:-0}"
    patch="${patch:-0}"

    echo "$type $major $minor $patch"
}

# Parse a tag name into version components → prints "major minor patch"
# Returns 1 for non-semver tags
parse_tag_version() {
    local tag="$1"
    # Strip v prefix
    local ver="${tag#v}"

    # Must match X.Y.Z pattern (at minimum X.Y)
    if [[ ! "$ver" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        return 1
    fi

    local major minor patch
    IFS='.' read -r major minor patch <<< "$ver"
    patch="${patch:-0}"

    echo "$major $minor $patch"
}

# Check if a tag version satisfies a version spec
# Returns 0 if tag matches spec
version_matches() {
    local tag_major="$1" tag_minor="$2" tag_patch="$3"
    local spec_type="$4" spec_major="$5" spec_minor="$6" spec_patch="$7"

    case "$spec_type" in
        latest)
            return 0
            ;;
        exact)
            (( tag_major == spec_major && tag_minor == spec_minor && tag_patch == spec_patch ))
            return $?
            ;;
        tilde)
            # ~1.2.3: major+minor match, patch >= spec
            (( tag_major == spec_major && tag_minor == spec_minor && tag_patch >= spec_patch ))
            return $?
            ;;
        caret)
            # ^X.Y.Z: compatible changes per semver
            # ^0.0.Z: exact match only (0.0.Z is fully unstable)
            # ^0.Y.Z: minor-locked (0.Y.z where z >= Z)
            # ^X.Y.Z (X>0): major-locked (X.y.z where y>Y or y==Y && z>=Z)
            if (( tag_major != spec_major )); then
                return 1
            fi
            if (( spec_major == 0 )); then
                if (( spec_minor == 0 )); then
                    # ^0.0.Z — exact patch
                    (( tag_minor == 0 && tag_patch == spec_patch ))
                    return $?
                fi
                # ^0.Y.Z — minor-locked
                (( tag_minor == spec_minor && tag_patch >= spec_patch ))
                return $?
            fi
            # ^X.Y.Z (X>0)
            if (( tag_minor > spec_minor )); then
                return 0
            fi
            (( tag_minor == spec_minor && tag_patch >= spec_patch ))
            return $?
            ;;
    esac
    return 1
}

# Find the best matching tag from a list of tags
# $1 = newline-separated tag list, $2-$5 = spec_type spec_major spec_minor spec_patch
# Prints the best matching tag (original form with v prefix if present)
find_best_tag() {
    local tags_list="$1"
    local spec_type="$2" spec_major="$3" spec_minor="$4" spec_patch="$5"

    local best_tag="" best_major=-1 best_minor=-1 best_patch=-1

    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue

        local parsed
        parsed=$(parse_tag_version "$tag") || continue
        local t_major t_minor t_patch
        read -r t_major t_minor t_patch <<< "$parsed"

        if version_matches "$t_major" "$t_minor" "$t_patch" "$spec_type" "$spec_major" "$spec_minor" "$spec_patch"; then
            # Check if this is better (higher) than current best
            if (( t_major > best_major )) || \
               (( t_major == best_major && t_minor > best_minor )) || \
               (( t_major == best_major && t_minor == best_minor && t_patch > best_patch )); then
                best_tag="$tag"
                best_major="$t_major"
                best_minor="$t_minor"
                best_patch="$t_patch"
            fi
        fi
    done <<< "$tags_list"

    if [[ -n "$best_tag" ]]; then
        echo "$best_tag"
        return 0
    fi
    return 1
}

# Check if major version increased
check_major_bump() {
    local old_version="$1" new_version="$2"
    local old_major new_major
    old_major="${old_version%%.*}"
    new_major="${new_version%%.*}"
    # Guard against non-numeric values
    [[ "$old_major" =~ ^[0-9]+$ ]] || return 1
    [[ "$new_major" =~ ^[0-9]+$ ]] || return 1
    (( new_major > old_major ))
}

# ── Lock file management ─────────────────────────────────────────────

# Read locked version for a source key from lock file
# Prints: resolved_version tag spec (space-separated), or empty if not found
lock_read() {
    local source_key="$1"
    [[ ! -f "$LOCK_FILE" ]] && return 1

    local entry
    entry=$(jq -c --arg k "$source_key" '.registries[$k] // empty' "$LOCK_FILE" 2>/dev/null)
    [[ -z "$entry" || "$entry" == "null" ]] && return 1

    local resolved tag spec
    resolved=$(echo "$entry" | jq -r '.resolved')
    tag=$(echo "$entry" | jq -r '.tag')
    spec=$(echo "$entry" | jq -r '.spec')
    echo "$resolved" "$tag" "$spec"
}

# Acquire a directory-based lock (POSIX-portable, no flock needed)
# $1 = lock dir path
_acquire_lock() {
    local lock_dir="$1"
    local attempts=0
    while ! mkdir "$lock_dir" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [[ "$attempts" -ge 25 ]]; then
            # Check if lock holder is still alive
            local lock_pid=""
            [[ -f "$lock_dir/pid" ]] && lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || true)
            if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
                echo -e "${YELLOW}Warning: Lock ${lock_dir} held by active process ${lock_pid}${NC}" >&2
                return 1
            fi
            # Stale lock — force-remove and retry
            rm -rf "$lock_dir"
            if ! mkdir "$lock_dir" 2>/dev/null; then
                echo -e "${YELLOW}Warning: Failed to acquire lock ${lock_dir}${NC}" >&2
                return 1
            fi
            echo "$$" > "$lock_dir/pid"
            return 0
        fi
        sleep 0.2
    done
    echo "$$" > "$lock_dir/pid"
}

# Release a directory-based lock
# $1 = lock dir path
_release_lock() {
    rm -rf "$1" 2>/dev/null || true
}

# Write/update a lock entry atomically
lock_write() {
    local source_key="$1" version="$2" tag="$3" spec="$4"

    _acquire_lock "${LOCK_FILE}.lock" || return 1
    trap '_release_lock "${LOCK_FILE}.lock"' RETURN

    local lock_json
    if [[ -f "$LOCK_FILE" ]]; then
        lock_json=$(cat "$LOCK_FILE")
    else
        lock_json='{"registries":{}}'
    fi

    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local tmp
    tmp=$(mktemp "${LOCK_FILE}.XXXXXX")
    if echo "$lock_json" | jq --arg k "$source_key" --arg v "$version" \
        --arg t "$tag" --arg s "$spec" --arg ts "$now" \
        '.registries[$k] = {resolved: $v, tag: $t, spec: $s, locked_at: $ts}' > "$tmp"; then
        mv "$tmp" "$LOCK_FILE"
    else
        rm -f "$tmp"
        echo -e "${YELLOW}Warning: Failed to update lock file${NC}" >&2
    fi
}

# Resolve a github preset dir from lock file. Sets _GH_* globals as side effect.
# $1 = source key (github:owner/repo[/path]), prints dir path or empty
resolve_locked_preset_dir() {
    local source_key="$1"
    [[ ! -f "$LOCK_FILE" ]] && return 1

    parse_github_source "$source_key"
    local ver
    ver=$(jq -r --arg k "$source_key" '.registries[$k].resolved // empty' "$LOCK_FILE" 2>/dev/null || true)
    [[ -z "$ver" ]] && return 1

    registry_preset_dir "$_GH_OWNER" "$_GH_REPO" "$ver" "$_GH_PATH"
}

# ── Update interval ───────────────────────────────────────────────────

# Read update_interval from config (hours). Default: 24. 0 = every launch.
# Checks CONFIG_FILE first, then GLOBAL_CONFIG.
get_update_interval() {
    local interval=""
    if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
        interval=$(jq -r '.update_interval // empty' "$CONFIG_FILE" 2>/dev/null || true)
    fi
    if [[ -z "$interval" && -f "$GLOBAL_CONFIG" ]]; then
        interval=$(jq -r '.update_interval // empty' "$GLOBAL_CONFIG" 2>/dev/null || true)
    fi
    echo "${interval:-24}"
}

# Check if enough time has passed since last lock update
# $1 = source_key. Returns 0 if check should be skipped (within interval).
lock_within_interval() {
    local source_key="$1"
    [[ ! -f "$LOCK_FILE" ]] && return 1

    local interval_hours
    interval_hours=$(get_update_interval)
    # 0 = always check
    [[ "$interval_hours" == "0" ]] && return 1

    local locked_at
    locked_at=$(jq -r --arg k "$source_key" '.registries[$k].locked_at // empty' "$LOCK_FILE" 2>/dev/null || true)
    [[ -z "$locked_at" ]] && return 1

    local locked_epoch now_epoch
    # macOS date -j -f for parsing ISO timestamp
    if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$locked_at" "+%s" &>/dev/null; then
        locked_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$locked_at" "+%s")
    elif date -d "$locked_at" "+%s" &>/dev/null; then
        # GNU date
        locked_epoch=$(date -d "$locked_at" "+%s")
    else
        return 1
    fi
    now_epoch=$(date "+%s")

    local interval_seconds=$(( interval_hours * 3600 ))
    (( (now_epoch - locked_epoch) < interval_seconds ))
}

# ── Version resolution ────────────────────────────────────────────────

# Resolve a github preset source to a concrete version.
# Handles locking, auto-update, interval check, and network failure fallback.
# Prints: resolved_version tag
# Sets up the clone directory.
resolve_github_version() {
    local owner="$1" repo="$2" source_key="$3" spec_str="$4"

    local spec_parsed
    spec_parsed=$(parse_version_spec "$spec_str")
    local spec_type spec_major spec_minor spec_patch
    read -r spec_type spec_major spec_minor spec_patch <<< "$spec_parsed"

    # Read existing lock
    local locked_version="" locked_tag=""
    local lock_data
    if lock_data=$(lock_read "$source_key"); then
        read -r locked_version locked_tag _ <<< "$lock_data"
    fi

    # Exact spec with lock: use locked version, no network
    if [[ "$spec_type" == "exact" && -n "$locked_version" ]]; then
        # Ensure clone exists
        if ! registry_has_clone "$owner" "$repo" "$locked_version"; then
            registry_clone_version "$owner" "$repo" "$locked_tag" || die_doctor "Failed to clone ${owner}/${repo}@${locked_tag}"
        fi
        echo "$locked_version" "$locked_tag"
        return
    fi

    # Exact spec without lock: clone the exact version
    if [[ "$spec_type" == "exact" ]]; then
        local exact_ver="${spec_major}.${spec_minor}.${spec_patch}"
        # Try v-prefixed tag first
        local try_tag="v${exact_ver}"
        if registry_clone_version "$owner" "$repo" "$try_tag" 2>/dev/null; then
            lock_write "$source_key" "$exact_ver" "$try_tag" "$spec_str"
            echo "$exact_ver" "$try_tag"
            return
        fi
        # Try without v prefix
        if registry_clone_version "$owner" "$repo" "$exact_ver" 2>/dev/null; then
            lock_write "$source_key" "$exact_ver" "$exact_ver" "$spec_str"
            echo "$exact_ver" "$exact_ver"
            return
        fi
        echo -e "${RED}Error: Tag v${exact_ver} not found in ${owner}/${repo}${NC}" >&2
        die_doctor "Tag v${exact_ver} not found in ${owner}/${repo}. Check the version spec in your config."
    fi

    # Non-exact spec: skip network check if within update interval
    if [[ -n "$locked_version" ]] && lock_within_interval "$source_key"; then
        if registry_has_clone "$owner" "$repo" "$locked_version"; then
            echo "$locked_version" "$locked_tag"
            return
        fi
    fi

    # Check for updates (network call)
    local remote_tags
    if remote_tags=$(registry_list_remote_tags "$owner" "$repo"); then
        local best_tag
        if best_tag=$(find_best_tag "$remote_tags" "$spec_type" "$spec_major" "$spec_minor" "$spec_patch"); then
            local best_parsed
            best_parsed=$(parse_tag_version "$best_tag")
            local best_major best_minor best_patch
            read -r best_major best_minor best_patch <<< "$best_parsed"
            local best_version="${best_major}.${best_minor}.${best_patch}"

            # Check if this is an update
            if [[ -n "$locked_version" && "$best_version" != "$locked_version" ]]; then
                # Warn on major bump
                if check_major_bump "$locked_version" "$best_version"; then
                    echo -e "  ${YELLOW}Major update available:${NC} ${owner}/${repo} ${locked_version} → ${best_version}" >&2
                else
                    echo -e "  ${GREEN}Updating:${NC} ${owner}/${repo} ${locked_version} → ${best_version}" >&2
                fi
            fi

            # Clone if needed
            if ! registry_has_clone "$owner" "$repo" "$best_version"; then
                registry_clone_version "$owner" "$repo" "$best_tag" || die_doctor "Failed to clone ${owner}/${repo}@${best_tag}"
            fi

            lock_write "$source_key" "$best_version" "$best_tag" "$spec_str"
            echo "$best_version" "$best_tag"
            return
        else
            echo -e "${RED}Error: No matching tag for spec '${spec_str}' in ${owner}/${repo}${NC}" >&2
            if [[ -n "$locked_version" ]]; then
                echo -e "${YELLOW}Falling back to locked version: ${locked_version}${NC}" >&2
                echo "$locked_version" "$locked_tag"
                return
            fi
            die_doctor "No matching tag for spec '${spec_str}' in ${owner}/${repo}. Check version spec in config."
        fi
    else
        # Network failure
        if [[ -n "$locked_version" ]]; then
            echo -e "  ${YELLOW}Network unavailable, using locked version:${NC} ${owner}/${repo}@${locked_version}" >&2
            if ! registry_has_clone "$owner" "$repo" "$locked_version"; then
                echo -e "${RED}Error: Locked version ${locked_version} not available locally${NC}" >&2
                die_doctor "Locked version ${locked_version} of ${owner}/${repo} not available locally and network is unavailable"
            fi
            echo "$locked_version" "$locked_tag"
            return
        fi
        die_doctor "Cannot fetch tags from ${owner}/${repo} (network unavailable) and no locked version exists"
    fi
}
