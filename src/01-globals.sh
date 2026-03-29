
# ── Globals ──────────────────────────────────────────────────────────
CONFIG_FILE=""
DRY_RUN=false
EXTRA_ARGS=()
ORIGINAL_CWD="$(pwd -P)"
CONFIG_DIR=""                              # Absolute path to directory containing claude-compose.json
WORKSPACE_DIR=""                           # Absolute path to workspace directory (default: CONFIG_DIR)
CLAUDE_ARGS=()
COMPOSE_CLAUDE_MD_EXCLUDES=()          # Paths to exclude from CLAUDE.md loading
HAS_ANY_ADD_DIR=false                  # Track if any --add-dir was added
SUBCOMMAND=""           # "", "config", "build", "migrate", "copy"
CONFIG_YES=false        # -y flag for config
CONFIG_PATH=""          # optional path for config -y
CONFIG_CHECK=false      # --check flag for config
BUILD_FORCE=false       # --force flag for build
MIGRATE_DELETE=false    # --delete flag for migrate
MIGRATE_WORKSPACE=""    # --workspace flag for migrate
MIGRATE_PATH=""         # positional arg for migrate
COPY_SOURCE=""          # positional arg for copy
COPY_DEST=""            # positional arg for copy
START_PATH=""            # positional arg for start
WRAP_CLAUDE_BIN=""          # Path to claude binary (wrap mode only)
WRAP_PASSTHROUGH_ARGS=()    # VS Code args to pass through in wrap mode
# shellcheck disable=SC2034
WRAP_MODE=false             # true when running as wrap subcommand
VSCODE_VARIANT=""           # "code", "insiders", "cursor" for vscode subcommand
DOCTOR_ERROR_MSG=""      # Error message for doctor mode
DOCTOR_ENABLED=true      # false prevents doctor trap (when claude/jq missing)
BUILTIN_PLUGIN_DIR="$HOME/.claude-compose/compose-plugin"
GLOBAL_CONFIG="$HOME/.claude-compose/global.json"
GLOBAL_CONFIG_DIR="$HOME/.claude-compose"
PROCESSED_WORKSPACES=() # workspace dedup (absolute paths)
DIRECT_PROJECT_PATHS=()  # Abs paths of directly-configured projects (for "direct wins" dedup)
PLUGIN_DIRS=()              # Resolved plugin directory paths for --plugin-dir
MARKETPLACE_PLUGINS=()          # "name@marketplace" entries to enable
PLUGIN_CONFIG_ENVS=()           # "KEY=VALUE" pairs for CLAUDE_PLUGIN_OPTION_*
_PLUGINS_RESOLVED=false     # Guard: true after resolve_plugins() ran

# Manifest state (built during build)
MANIFEST_JSON='{"global":{},"workspaces":{},"resources":{}}'
CURRENT_SOURCE_AGENTS=()
CURRENT_SOURCE_SKILLS=()
CURRENT_SOURCE_MCP_SERVERS=()
CURRENT_SOURCE_ADD_DIRS=()
CURRENT_SOURCE_PROJECT_DIRS=()
CURRENT_SOURCE_NAME=""
_BUILD_LOCK_HELD=false

# ── Compose output directory & file paths ────────────────────────────
COMPOSE_DIR=".claude/claude-compose"
COMPOSE_MCP="${COMPOSE_DIR}/mcp.json"
COMPOSE_MANIFEST="${COMPOSE_DIR}/manifest.json"
COMPOSE_HASH="${COMPOSE_DIR}/hash"
COMPOSE_SETTINGS="${COMPOSE_DIR}/settings.json"
COMPOSE_LOCK="${COMPOSE_DIR}/build.lock"

_MCP_EMPTY='{"_warning":"This file is managed by claude-compose. Do not edit directly.","mcpServers":{}}'

# Shared collection state (set by _collect_project_args / _collect_manifest_args / _build_settings)
_PROJECT_ALIASES=""
_SYSTEM_PROMPT=""
_COMPOSE_SETTINGS='{}'

# ── Colors ───────────────────────────────────────────────────────────
if [[ -t 2 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    BOLD=''
    NC=''
fi
