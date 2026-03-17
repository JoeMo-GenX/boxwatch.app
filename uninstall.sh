#!/bin/bash
# BoxWatch Agent Uninstaller
# Usage: curl -sL https://boxwatch.app/uninstall.sh | bash

set -e

INSTALL_DIR="/opt/boxwatch"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

error() {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

success() {
    echo -e "${GREEN}$1${NC}"
}

# Determine sudo prefix
SUDO=""
if [ "$EUID" -ne 0 ]; then
    if command -v sudo &> /dev/null; then
        SUDO="sudo"
    else
        error "This script requires root privileges or sudo"
    fi
fi

echo "Removing BoxWatch agent..."

# Remove cron job (more specific pattern to avoid removing unrelated entries)
if command -v crontab &> /dev/null; then
    (crontab -l 2>/dev/null | grep -v "boxwatch/agent.sh" || true) | crontab - 2>/dev/null || true
    success "✓ Removed cron job"
else
    echo "Crontab not found, skipping cron removal"
fi

# Remove installation directory
if [ -d "$INSTALL_DIR" ]; then
    $SUDO rm -rf "$INSTALL_DIR" || error "Failed to remove $INSTALL_DIR"
    success "✓ Removed installation directory"
else
    echo "Installation directory not found, nothing to remove"
fi

success "✓ BoxWatch agent removed successfully"
echo ""
echo "Your server is no longer being monitored."
echo "To reinstall: curl -sL https://boxwatch.app/install.sh | bash -s YOUR_AGENT_KEY"
