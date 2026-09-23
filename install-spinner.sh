#!/usr/bin/env bash
# Install the spinner verbs from spinner-verbs.json into ~/.claude/settings.json.
#   curl -fsSL "https://raw.githubusercontent.com/alexanderleitch/claude-usage-guard/main/install-spinner.sh?$(date +%s)" | bash
# Needs jq. Backs up settings.json to settings.json.bak-spinner. Restart Claude Code afterwards.
set -euo pipefail
jq() { command jq "$@" | tr -d '\r'; }   # Windows jq prints CRLF
RAW="https://raw.githubusercontent.com/alexanderleitch/claude-usage-guard/main/spinner-verbs.json"
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; SETTINGS="$CFG/settings.json"
command -v jq >/dev/null || { echo "jq is required (brew install jq | winget install jqlang.jq | apt install jq)" >&2; exit 1; }
here="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd)"
if [ -s "$here/spinner-verbs.json" ]; then verbs=$(cat "$here/spinner-verbs.json"); else verbs=$(curl -fsSL "$RAW?$(date +%s)"); fi
jq -e '.mode and (.verbs|type=="array") and (.verbs|length>0)' <<<"$verbs" >/dev/null || { echo "bad spinner-verbs.json" >&2; exit 1; }
mkdir -p "$CFG"; [ -s "$SETTINGS" ] || printf '{}\n' >"$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-spinner"
tmp=$(mktemp); jq --argjson v "$verbs" '.spinnerVerbs = $v' "$SETTINGS" >"$tmp" && mv "$tmp" "$SETTINGS"
echo "installed $(jq '.verbs|length' <<<"$verbs") spinner verbs (mode: $(jq -r .mode <<<"$verbs")) into $SETTINGS. restart Claude Code."
