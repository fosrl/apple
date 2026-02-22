#!/usr/bin/env bash
# Reset Pangolin onboarding state and clear accounts so you can test the flow again.
# Quit Pangolin before running this script.

set -e

BUNDLE_ID="net.pangolin.Pangolin"
KEYS=(
  "net.pangolin.Pangolin.Onboarding.hasSeenWelcome"
  "net.pangolin.Pangolin.Onboarding.hasAcknowledgedPrivacy"
  "net.pangolin.Pangolin.Onboarding.hasCompletedVPNInstallOnboarding"
  "net.pangolin.Pangolin.Onboarding.hasCompletedSystemExtensionOnboarding"
)

echo "Resetting Pangolin onboarding state and clearing accounts..."

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
ACCOUNTS_FILE="$HOME/Library/Application Support/Pangolin/accounts.json"
if [[ -f "$ACCOUNTS_FILE" ]]; then
  echo "Removing accounts file (Application Support)..."
  rm -f "$ACCOUNTS_FILE"
fi

# Clear accounts (sandboxed container)
CONTAINER_ACCOUNTS="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Application Support/Pangolin/accounts.json"
if [[ -f "$CONTAINER_ACCOUNTS" ]]; then
  echo "Removing accounts file (sandbox container)..."
  rm -f "$CONTAINER_ACCOUNTS"
fi

echo "Done. Restart Pangolin to see the onboarding flow again."
