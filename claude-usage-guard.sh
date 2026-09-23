#!/usr/bin/env bash
# claude-usage-guard: show Claude Code plan-limit usage in the status line and
# stop cleanly (commit + handoff note) before the limit cuts the session off.
#
#   install:   curl -fsSL https://raw.githubusercontent.com/alexanderleitch/claude-usage-guard/main/claude-usage-guard.sh | bash -s install
#   uninstall: bash ~/.claude/usage-guard.sh uninstall
#   selftest:  bash ~/.claude/usage-guard.sh selftest
#
# Needs bash + jq (macOS: brew install jq | Windows: winget install jqlang.jq | Debian: apt install jq).
# Windows: Claude Code runs hooks through Git Bash, so install Git for Windows first.
# Threshold: CLAUDE_USAGE_GUARD_PCT (default 85). Config dir: CLAUDE_CONFIG_DIR (default ~/.claude).
#
# How it works: Claude Code gives the status line command a JSON payload that
# includes rate_limits.{five_hour,seven_day}.used_percentage. Hooks never get
# that field, so the status line caches it to a file and the Stop hook reads
# the file. Nothing here calls the API; it costs zero usage.
set -euo pipefail

RAW_URL="https://raw.githubusercontent.com/alexanderleitch/claude-usage-guard/main/claude-usage-guard.sh"
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SELF="$CFG/usage-guard.sh"
SETTINGS="$CFG/settings.json"
PREV="$CFG/usage-guard.prev-statusline"
PCT="${CLAUDE_USAGE_GUARD_PCT:-85}"
CACHE_DIR="${TMPDIR:-/tmp}"

cache_path() { printf '%s/cc-limits-%s.json' "${CACHE_DIR%/}" "$1"; }

cmd_statusline() {
  local input sid
  input=$(cat)
  [ -n "$input" ] || exit 0
  sid=$(jq -r '.session_id // "unknown"' <<<"$input")
  jq -c '{f:(.rate_limits.five_hour.used_percentage // null),
          w:(.rate_limits.seven_day.used_percentage // null),
          fr:(.rate_limits.five_hour.resets_at // null),
          ctx:(.context_window.used_percentage // null)}' <<<"$input" \
    >"$(cache_path "$sid")" 2>/dev/null || true
  jq -r '
    def pc(x): if x == null then "-" else ((x|floor)|tostring) + "%" end;
    def rs(x): if x == null then "" else " (" + (x|floor|strflocaltime("%H:%M")) + ")" end;
    [ "5h " + pc(.rate_limits.five_hour.used_percentage) + rs(.rate_limits.five_hour.resets_at),
      "7d " + pc(.rate_limits.seven_day.used_percentage),
      "ctx " + pc(.context_window.used_percentage),
      (.model.display_name // empty) ] | join(" | ")' <<<"$input"
  # chain whatever status line command was configured before install
  if [ -s "$PREV" ]; then printf '%s' "$input" | bash -c "$(cat "$PREV")" 2>/dev/null || true; fi
}

cmd_stop() {
  local input sid f five seven worst marker
  input=$(cat)
  [ "$(jq -r '.stop_hook_active // false' <<<"$input")" = "true" ] && exit 0
  sid=$(jq -r '.session_id // "unknown"' <<<"$input")
  f=$(cache_path "$sid"); marker="$f.blocked"
  [ -f "$f" ] || exit 0
  read -r five seven < <(jq -r '[(.f // 0), (.w // 0)] | map(floor) | @tsv' "$f")
  worst=$five; [ "$seven" -gt "$worst" ] && worst=$seven
  if [ "$worst" -lt "$PCT" ]; then rm -f "$marker"; exit 0; fi
  [ -f "$marker" ] && exit 0   # ponytail: warn once per session per window; reset clears the marker
  : >"$marker"
  jq -nc --arg p "$worst" --arg lim "$PCT" '{decision:"block",
    reason:("Claude usage limit is at " + $p + "% (guard threshold " + $lim + "%). Do not start new work. Commit work in progress, write a handoff note to the project PROGRESS.md (done / next / how to resume), then stop and tell the user the usage limit is nearly reached.")}'
}

cmd_install() {
  command -v jq >/dev/null || { echo "jq is required (brew install jq | winget install jqlang.jq | apt install jq)" >&2; exit 1; }
  mkdir -p "$CFG"
  if [ -s "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" != "$SELF" ]; then cp "${BASH_SOURCE[0]}" "$SELF"
  elif [ ! -s "$SELF" ] || [ -z "${BASH_SOURCE[0]:-}" ]; then curl -fsSL "$RAW_URL" -o "$SELF"; fi
  chmod +x "$SELF"
  [ -s "$SETTINGS" ] || printf '{}\n' >"$SETTINGS"
  cp "$SETTINGS" "$SETTINGS.bak-usage-guard"
  local cur tmp
  cur=$(jq -r '.statusLine.command // empty' "$SETTINGS")
  if [ -n "$cur" ] && [[ "$cur" != *usage-guard.sh* ]]; then printf '%s' "$cur" >"$PREV"; fi
  tmp=$(mktemp)
  jq --arg sl "bash '$SELF' statusline" --arg st "bash '$SELF' stop" '
    .statusLine = {type:"command", command:$sl}
    | .hooks //= {} | .hooks.Stop //= []
    | if ([.hooks.Stop[]?.hooks[]?.command // ""] | any(contains("usage-guard.sh"))) then .
      else .hooks.Stop += [{hooks:[{type:"command", command:$st, timeout:10}]}] end
  ' "$SETTINGS" >"$tmp" && mv "$tmp" "$SETTINGS"
  echo "installed: $SELF"
  echo "status line + Stop hook written to $SETTINGS (backup: $SETTINGS.bak-usage-guard)"
  [ -s "$PREV" ] && echo "previous status line preserved and chained: $PREV"
  echo "restart Claude Code (or open /hooks once) to load it. threshold ${PCT}%"
}

cmd_uninstall() {
  local tmp
  tmp=$(mktemp)
  jq --arg prev "$( [ -s "$PREV" ] && cat "$PREV" || true )" '
    if $prev == "" then del(.statusLine) else .statusLine = {type:"command", command:$prev} end
    | if .hooks.Stop then .hooks.Stop |= map(select(([.hooks[]?.command // ""] | any(contains("usage-guard.sh"))) | not)) else . end
  ' "$SETTINGS" >"$tmp" && mv "$tmp" "$SETTINGS"
  rm -f "$SELF" "$PREV"
  echo "removed. restart Claude Code."
}

cmd_selftest() {
  local d out
  d=$(mktemp -d); export CLAUDE_CONFIG_DIR="$d" TMPDIR="$d"
  hi='{"session_id":"t1","rate_limits":{"five_hour":{"used_percentage":91.4,"resets_at":1758640000},"seven_day":{"used_percentage":40}},"context_window":{"used_percentage":33},"model":{"display_name":"Test"}}'
  lo='{"session_id":"t1","rate_limits":{"five_hour":{"used_percentage":10},"seven_day":{"used_percentage":12}},"context_window":{"used_percentage":5}}'
  out=$(printf '%s' "$hi" | bash "$0" statusline);                 [[ "$out" == "5h 91% ("*") | 7d 40% | ctx 33% | Test" ]] || { echo "FAIL statusline: $out"; exit 1; }
  out=$(printf '{"session_id":"t1"}' | bash "$0" stop);            [[ "$out" == *'"decision":"block"'* ]]            || { echo "FAIL stop should block: $out"; exit 1; }
  out=$(printf '{"session_id":"t1"}' | bash "$0" stop);            [ -z "$out" ]                                    || { echo "FAIL stop should block once: $out"; exit 1; }
  out=$(printf '{"session_id":"t1","stop_hook_active":true}' | bash "$0" stop); [ -z "$out" ]                       || { echo "FAIL stop_hook_active loop guard: $out"; exit 1; }
  printf '%s' "$lo" | bash "$0" statusline >/dev/null
  out=$(printf '{"session_id":"t1"}' | bash "$0" stop);            [ -z "$out" ]                                    || { echo "FAIL stop below threshold: $out"; exit 1; }
  out=$(printf '{"session_id":"t2"}' | bash "$0" statusline);      [[ "$out" == "5h - | 7d - | ctx -" ]]            || { echo "FAIL statusline without rate_limits: $out"; exit 1; }
  rm -rf "$d"; echo "selftest ok"
}

case "${1:-install}" in
  statusline) cmd_statusline ;;
  stop)       cmd_stop ;;
  install)    cmd_install ;;
  uninstall)  cmd_uninstall ;;
  selftest)   cmd_selftest ;;
  *) echo "usage: $0 {install|uninstall|statusline|stop|selftest}" >&2; exit 2 ;;
esac
