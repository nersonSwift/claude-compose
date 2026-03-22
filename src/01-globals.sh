
# ── Globals ──────────────────────────────────────────────────────────
CONFIG_FILE=""
DRY_RUN=false
EXTRA_ARGS=()
ORIGINAL_CWD="$(pwd)"
CLAUDE_ARGS=()
NEED_CLAUDE_MD_ENV=false
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
PRESETS_DIR="$HOME/.claude-compose/presets"
BUILTIN_SKILLS_DIR="$HOME/.claude-compose/skills"
GLOBAL_CONFIG="$HOME/.claude-compose/global.json"
GLOBAL_CONFIG_DIR="$HOME/.claude-compose"
PROCESSED_PRESETS=()    # cycle detection set
PROCESSED_WORKSPACES=() # workspace dedup (absolute paths)

# Manifest state (built during process_preset / process_workspace)
MANIFEST_JSON='{"builtin":{},"global":{},"presets":{},"workspaces":{},"resources":{}}'
CURRENT_SOURCE_AGENTS=()
CURRENT_SOURCE_SKILLS=()
CURRENT_SOURCE_MCP_SERVERS=()
CURRENT_SOURCE_ADD_DIRS=()
CURRENT_SOURCE_PROJECT_DIRS=()

# ── Colors ───────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
