#!/usr/bin/env bash
set -euo pipefail

# claude-compose installer
# Usage: curl -fsSL https://raw.githubusercontent.com/nersonSwift/claude-compose/main/install.sh | bash

REPO="nersonSwift/claude-compose"
INSTALL_DIR="${HOME}/.local/bin"
BINARY_NAME="claude-compose"

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}Installing claude-compose...${NC}"

# Check dependencies
if ! command -v jq &>/dev/null; then
    echo -e "${RED}Error: jq is required.${NC}"
    if [[ "$(uname)" == "Darwin" ]]; then
        echo "  Install: brew install jq"
    else
        echo "  Install: sudo apt install jq"
    fi
    exit 1
fi

if ! command -v claude &>/dev/null; then
    echo -e "${RED}Warning: claude CLI not found. Install it before using claude-compose.${NC}"
fi

# Create install directory
mkdir -p "$INSTALL_DIR"

# Resolve latest release tag
LATEST_TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | jq -r '.tag_name // empty')
if [[ -z "$LATEST_TAG" ]]; then
    echo -e "${RED}Error: Could not determine latest release. Check https://github.com/${REPO}/releases${NC}"
    exit 1
fi

# Download
DOWNLOAD_URL="https://raw.githubusercontent.com/${REPO}/${LATEST_TAG}/claude-compose"
if command -v curl &>/dev/null; then
    curl -fsSL "$DOWNLOAD_URL" -o "${INSTALL_DIR}/${BINARY_NAME}"
elif command -v wget &>/dev/null; then
    wget -qO "${INSTALL_DIR}/${BINARY_NAME}" "$DOWNLOAD_URL"
else
    echo -e "${RED}Error: curl or wget required.${NC}"
    exit 1
fi

chmod +x "${INSTALL_DIR}/${BINARY_NAME}"

# Verify download
if ! head -1 "${INSTALL_DIR}/${BINARY_NAME}" | grep -q '^#!/usr/bin/env bash'; then
    echo -e "${RED}Error: Downloaded file is not a valid claude-compose binary.${NC}"
    rm -f "${INSTALL_DIR}/${BINARY_NAME}"
    exit 1
fi

# Check PATH
if [[ ":$PATH:" != *":${INSTALL_DIR}:"* ]]; then
    echo ""
    echo -e "${RED}${INSTALL_DIR} is not in your PATH.${NC}"
    SHELL_NAME=$(basename "$SHELL")
    case "$SHELL_NAME" in
        zsh)  RC_FILE="~/.zshrc" ;;
        bash) RC_FILE="~/.bashrc" ;;
        *)    RC_FILE="your shell rc file" ;;
    esac
    echo "Add this to ${RC_FILE}:"
    echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
    echo ""
fi

echo -e "${GREEN}Installed ${BINARY_NAME} to ${INSTALL_DIR}/${BINARY_NAME}${NC}"
echo ""
echo "Usage:"
echo "  claude-compose --help"
