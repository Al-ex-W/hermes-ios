#!/bin/sh
# Installs hermes-voice-mcp as a launchd agent for the current user, filling in local paths.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
project=$(dirname "$here")
uv=$(command -v uv) || { echo "uv not found on PATH" >&2; exit 1; }
log="$HOME/.hermes/logs/hermes-voice-mcp.log"
target="$HOME/Library/LaunchAgents/io.github.hermes-ios.voice.plist"
mkdir -p "$(dirname "$log")" "$(dirname "$target")"
sed -e "s|__UV__|$uv|" -e "s|__PROJECT__|$project|" -e "s|__LOG__|$log|" "$here/hermes-voice.plist.example" > "$target"
launchctl bootout "gui/$(id -u)" "$target" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$target"
echo "Installed $target (logs: $log)"
