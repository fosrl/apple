#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./check-system-extension-version.sh net.pangolin.Pangolin.PacketTunnel
#
# Optional:
#   ./check-system-extension-version.sh <bundle_id> "<team_id>"
# If team_id is provided, it narrows the match.

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <extension_bundle_id> [team_id]"
  exit 1
fi

BUNDLE_ID="$1"
TEAM_ID="${2:-}"

RAW_OUTPUT="$(systemextensionsctl list 2>/dev/null || true)"

if [[ -z "$RAW_OUTPUT" ]]; then
  echo "Failed to read system extensions (systemextensionsctl returned no output)."
  exit 2
fi

if [[ -n "$TEAM_ID" ]]; then
  MATCH_LINE="$(printf '%s\n' "$RAW_OUTPUT" | rg -F "$TEAM_ID" | rg -F "$BUNDLE_ID" || true)"
else
  MATCH_LINE="$(printf '%s\n' "$RAW_OUTPUT" | rg -F "$BUNDLE_ID" || true)"
fi

if [[ -z "$MATCH_LINE" ]]; then
  echo "Not installed: $BUNDLE_ID"
  exit 3
fi

echo "Installed entry:"
echo "$MATCH_LINE"

# Try to extract a version from common formats in systemextensionsctl output.
VERSION="$(printf '%s\n' "$MATCH_LINE" | sed -nE 's/.*[Vv]ersion[: ]+([0-9A-Za-z._-]+).*/\1/p' | head -n1 || true)"

# Fallback: try "bundleID (x.y.z)" format if present.
if [[ -z "$VERSION" ]]; then
  VERSION="$(printf '%s\n' "$MATCH_LINE" | sed -nE 's/.*\(([0-9]+(\.[0-9A-Za-z_-]+)*)\).*/\1/p' | head -n1 || true)"
fi

if [[ -n "$VERSION" ]]; then
  echo "Detected installed version: $VERSION"
else
  echo "Version not parseable from this macOS output format."
  echo "You can still use the installed entry above for verification."
fi
