#!/bin/bash
# BoxWatch Agent Installer
# Usage: curl -sL https://boxwatch.app/install.sh | bash -s YOUR_AGENT_KEY
# Safer: curl -sL https://boxwatch.app/install.sh | BOXWATCH_KEY=your_key bash

set -e

# Accept key from environment variable or positional argument
AGENT_KEY="${BOXWATCH_KEY:-$1}"
API_URL="https://api.boxwatch.app"
INSTALL_DIR="/opt/boxwatch"
AGENT_URL="https://boxwatch.app/agent.sh"

# Expected SHA256 checksum of agent.sh (update when agent.sh changes)
EXPECTED_SHA256="03c3ab87bcd869a5cee4efcf0fe8803170e59ccb8f7a1d4638c91a0d8b7fa6fd"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

error() {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}Warning: $1${NC}" >&2
}

success() {
    echo -e "${GREEN}$1${NC}"
}

# Check if agent key provided
if [ -z "$AGENT_KEY" ]; then
    error "Agent key required\nUsage: curl -sL https://boxwatch.app/install.sh | bash -s YOUR_AGENT_KEY\n   or: curl -sL https://boxwatch.app/install.sh | BOXWATCH_KEY=your_key bash"
fi

# Validate key format (alphanumeric, underscores, hyphens, dots only)
if [[ ! "$AGENT_KEY" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    error "Invalid agent key format"
fi

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ] && ! command -v sudo &> /dev/null; then
    error "This script requires root privileges or sudo"
fi

# Determine sudo prefix
SUDO=""
if [ "$EUID" -ne 0 ]; then
    SUDO="sudo"
fi

# Check for required commands
for cmd in curl crontab; do
    if ! command -v $cmd &> /dev/null; then
        error "$cmd is required but not installed"
    fi
done

echo "Installing BoxWatch agent..."

# Create directory
$SUDO mkdir -p "$INSTALL_DIR" || error "Failed to create installation directory"

# Download agent script
echo "Downloading agent script..."
if ! $SUDO curl -sL "$AGENT_URL" -o "$INSTALL_DIR/agent.sh"; then
    error "Failed to download agent script from $AGENT_URL"
fi

# Verify SHA256 checksum
echo "Verifying integrity..."
ACTUAL_SHA256=$($SUDO sha256sum "$INSTALL_DIR/agent.sh" 2>/dev/null | cut -d' ' -f1 || \
                 $SUDO shasum -a 256 "$INSTALL_DIR/agent.sh" 2>/dev/null | cut -d' ' -f1)

if [ -z "$ACTUAL_SHA256" ]; then
    warn "Could not verify checksum (sha256sum/shasum not available)"
elif [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    $SUDO rm -f "$INSTALL_DIR/agent.sh"
    error "Checksum verification failed! Downloaded file may be tampered.\nExpected: $EXPECTED_SHA256\nGot: $ACTUAL_SHA256"
fi

$SUDO chmod +x "$INSTALL_DIR/agent.sh" || error "Failed to make agent script executable"

# Save config (using heredoc to avoid key in process list)
echo "Saving configuration..."
$SUDO bash -c "cat > '$INSTALL_DIR/config'" << EOF
AGENT_KEY=$AGENT_KEY
API_URL=$API_URL
EOF
$SUDO chmod 600 "$INSTALL_DIR/config" || warn "Failed to set secure permissions on config file"

# Set up cron (every minute - server-side controls actual push frequency based on plan)
echo "Setting up monitoring..."
CRON_ENTRY="* * * * * $INSTALL_DIR/agent.sh"

# Remove existing boxwatch cron entries and add new one
(crontab -l 2>/dev/null | grep -v "boxwatch/agent.sh" || true; echo "$CRON_ENTRY") | crontab - || error "Failed to set up cron job"

# Run once immediately to verify installation
echo "Testing connection..."
if $SUDO "$INSTALL_DIR/agent.sh"; then
    success "✓ BoxWatch agent installed successfully!"
    success "✓ Your server will now report metrics based on your plan."
    echo ""
    echo "Push frequency: Hobby (60 min) | Pro/Team (5 min) | Scale (1 min)"
    echo ""
    echo "To uninstall: curl -sL https://boxwatch.app/uninstall.sh | bash"
else
    warn "Agent installed but initial test failed. Check your agent key and network connection."
    echo "The agent will continue trying to connect every minute."
fi
