#!/usr/bin/env bash
# Reset CNDF-VPN onboarding state and clear accounts so you can test the flow again.
# Quit CNDF-VPN before running this script.

set -e

BUNDLE_ID="com.cndf.vpn"
KEYS=(
  "com.cndf.vpn.Onboarding.hasSeenWelcome"
  "com.cndf.vpn.Onboarding.hasAcknowledgedPrivacy"
  "com.cndf.vpn.Onboarding.hasCompletedVPNInstallOnboarding"
  "com.cndf.vpn.Onboarding.hasCompletedSystemExtensionOnboarding"
)

echo "Resetting CNDF-VPN onboarding state and clearing accounts..."

# Standard app preferences (non-sandboxed or when running from Xcode)
for key in "${KEYS[@]}"; do
  defaults delete "$BUNDLE_ID" "$key" 2>/dev/null || true
done

# Sandboxed app container (if present)
CONTAINER_PLIST="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Preferences/$BUNDLE_ID.plist"
if [[ -f "$CONTAINER_PLIST" ]]; then
  echo "Clearing onboarding keys in sandbox container..."
  for key in "${KEYS[@]}"; do
    defaults delete "$CONTAINER_PLIST" "$key" 2>/dev/null || true
  done
fi

# Clear accounts (standard Application Support)
ACCOUNTS_FILE="$HOME/Library/Application Support/CNDFVPN/accounts.json"
if [[ -f "$ACCOUNTS_FILE" ]]; then
  echo "Removing accounts file (Application Support)..."
  rm -f "$ACCOUNTS_FILE"
fi

# Clear accounts (sandboxed container)
CONTAINER_ACCOUNTS="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Application Support/CNDFVPN/accounts.json"
if [[ -f "$CONTAINER_ACCOUNTS" ]]; then
  echo "Removing accounts file (sandbox container)..."
  rm -f "$CONTAINER_ACCOUNTS"
fi

echo "Done. Restart CNDF-VPN to see the onboarding flow again."
