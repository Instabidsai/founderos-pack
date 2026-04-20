#!/usr/bin/env bash
# FounderOS — one-command installer
#
# Hands-free client install. Pipeable from curl.
#
#   curl -sSL https://founderos.ai/i | bash -s -- <TOKEN>
#
# OR use the GitHub URL directly:
#   curl -sSL https://raw.githubusercontent.com/Instabidsai/founderos-pack/main/install.sh | bash -s -- <TOKEN>
#
# This wrapper exists so the URL stays stable even if we move hosts / rename the actual install script.
set -euo pipefail

TOKEN="${1:-}"
if [[ -z "$TOKEN" ]]; then
  cat <<'HELP'
FounderOS installer

Usage:
  curl -sSL https://founderos.ai/i | bash -s -- YOUR-INSTALL-TOKEN

Or download & run:
  bash founderos.sh YOUR-INSTALL-TOKEN

You should have received your token from our team. If not, email hello@founderos.ai.
HELP
  exit 1
fi

echo ""
echo "================================================="
echo "  FounderOS — AI owner harness installer"
echo "================================================="
echo ""

# Redirect to the real installer in the current release
REAL_URL="https://raw.githubusercontent.com/Instabidsai/founderos-pack/main/install.sh"
exec bash <(curl -sSL "$REAL_URL") "$TOKEN"
