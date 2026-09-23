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
# Threshold: CLAUDE_USAGE_GUARD_PCT (default 98). Config dir: CLAUDE_CONFIG_DIR (default ~/.claude).
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
BADGES="$CFG/usage-guard.badges"     # one shell command per line; each gets the payload on stdin, output is prefixed to the line
PCT="${CLAUDE_USAGE_GUARD_PCT:-98}"
CACHE_DIR="${TMPDIR:-/tmp}"

# a previous statusLine that is itself a plugin badge is already covered by the badges file
is_badge_cmd() { case "$1" in *ponytail-statusline*|*caveman-statusline*) return 0 ;; *) return 1 ;; esac; }

cache_path() { printf '%s/cc-limits-%s.json' "${CACHE_DIR%/}" "$1"; }

cmd_statusline() {
  local input sid
  input=$(cat)
  [ -n "$input" ] || exit 0
  sid=$(jq -r '.session_id // "unknown"' <<<"$input")
  local cache; cache=$(cache_path "$sid")
  # ctx: fall back to tokens/size when used_percentage is absent; keep last cached value when nothing usable arrives
  local prev; prev=$(cat "$cache" 2>/dev/null || true); [ -n "$prev" ] || prev=null
  input=$(jq -c --argjson c "[$prev]" '
    .context_window.used_percentage = (
      .context_window.used_percentage
      // (if (.context_window.current_usage and (.context_window.context_window_size // 0) > 0)
          then ((.context_window.current_usage | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)) / .context_window.context_window_size * 100)
          else null end)
      // ($c[0].ctx? // null))' <<<"$input")
  # rate_limits is only present on some refreshes; keep the last seen values so the line stays populated
  if [ "$(jq -r '.rate_limits.five_hour.used_percentage // .rate_limits.seven_day.used_percentage // empty' <<<"$input")" != "" ]; then
    jq -c '{f:(.rate_limits.five_hour.used_percentage // null),
            w:(.rate_limits.seven_day.used_percentage // null),
            fr:(.rate_limits.five_hour.resets_at // null),
            ctx:(.context_window.used_percentage // null)}' <<<"$input" >"$cache" 2>/dev/null || true
  elif [ -s "$cache" ]; then
    input=$(jq -c --slurpfile c "$cache" '.rate_limits = {five_hour:{used_percentage:$c[0].f, resets_at:$c[0].fr}, seven_day:{used_percentage:$c[0].w}}' <<<"$input")
    jq -c --slurpfile c "$cache" '$c[0] + {ctx:(.context_window.used_percentage // $c[0].ctx)}' <<<"$input" >"$cache.tmp" 2>/dev/null && mv "$cache.tmp" "$cache" || true
  fi
  local badges="" b
  if [ -s "$BADGES" ]; then
    while IFS= read -r cmd || [ -n "$cmd" ]; do
      [ -n "$cmd" ] && [ "${cmd#\#}" = "$cmd" ] || continue
      b=$(printf '%s' "$input" | bash -c "$cmd" 2>/dev/null || true)
      [ -n "$b" ] && badges="$badges$b "
    done <"$BADGES"
  fi
  printf '%s' "$badges"
  # colours: each box its own colour; % inherits it, orange from 50%, bold red from the threshold. CLAUDE_USAGE_GUARD_COLOR=0 disables
  jq -r --argjson pct "$PCT" --argjson color "${CLAUDE_USAGE_GUARD_COLOR:-1}" '
    def esc(c): if $color == 1 then "\u001b[" + c + "m" else "" end;
    def rst: esc("0");
    def tone(x; base): if x == null then esc("2") elif x >= $pct then esc("1;38;5;167") elif x >= 50 then esc("38;5;173") else esc(base) end;
    def pc(x): if x == null then "-" else ((x|floor)|tostring) + "%" end;
    def rs(x): if x == null then "" else esc("2") + " " + (x|floor|strflocaltime("%H:%M")) + rst end;
    def val(x; base): tone(x; base) + pc(x) + rst;
    def box(word; base; body): esc(base) + "[" + word + " " + body + esc(base) + "]" + rst;
    ("38;5;67") as $u | ("38;5;139") as $c | ("38;5;73") as $m |
    [ box("USAGE"; $u; "5h " + val(.rate_limits.five_hour.used_percentage; $u) + rs(.rate_limits.five_hour.resets_at) + esc($u) + " · 7d " + val(.rate_limits.seven_day.used_percentage; $u)),
      box("CONTEXT"; $c; val(.context_window.used_percentage; $c)),
      (.model.display_name // empty | box("MODEL"; $m; .)) ] | join(" ")' <<<"$input"
  # chain whatever status line command was configured before install
  if [ -s "$PREV" ] && ! is_badge_cmd "$(cat "$PREV")"; then printf '%s' "$input" | bash -c "$(cat "$PREV")" 2>/dev/null || true; fi
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
  elif [ ! -s "$SELF" ] || [ -z "${BASH_SOURCE[0]:-}" ]; then curl -fsSL "$RAW_URL?$(date +%s)" -o "$SELF"; fi
  chmod +x "$SELF"
  [ -s "$SETTINGS" ] || printf '{}\n' >"$SETTINGS"
  cp "$SETTINGS" "$SETTINGS.bak-usage-guard"
  local cur tmp
  cur=$(jq -r '.statusLine.command // empty' "$SETTINGS")
  if [ -n "$cur" ] && [[ "$cur" != *usage-guard.sh* ]] && ! is_badge_cmd "$cur"; then printf '%s' "$cur" >"$PREV"; fi
  # badges: known plugin statusline scripts, resolved at runtime so plugin version bumps survive
  if [ ! -e "$BADGES" ]; then
    {
      echo '# one command per line; payload on stdin; output is shown before the usage line'
      echo 'f=$(ls -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/ponytail/ponytail/*/hooks/ponytail-statusline.sh 2>/dev/null | tail -1); [ -n "$f" ] && bash "$f"'
      echo 'f=$(ls -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/caveman/caveman/*/src/hooks/caveman-statusline.sh 2>/dev/null | tail -1); [ -n "$f" ] && bash "$f"'
    } >"$BADGES"
  fi
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
  rm -f "$SELF" "$PREV" "$BADGES"
  echo "removed. restart Claude Code."
}

cmd_selftest() {
  local d out
  d=$(mktemp -d); export CLAUDE_CONFIG_DIR="$d" TMPDIR="$d" CLAUDE_USAGE_GUARD_COLOR=0 CLAUDE_USAGE_GUARD_PCT=85
  out=$(printf '{"session_id":"c","rate_limits":{"five_hour":{"used_percentage":90},"seven_day":{"used_percentage":10}}}' | CLAUDE_USAGE_GUARD_COLOR=1 bash "$0" statusline)
  [[ "$out" == *$'\e[1;38;5;167m90%'* && "$out" == *$'\e[38;5;67m10%'* ]] || { echo "FAIL colour: $(printf '%q' "$out")"; exit 1; }
  hi='{"session_id":"t1","rate_limits":{"five_hour":{"used_percentage":91.4,"resets_at":1758640000},"seven_day":{"used_percentage":40}},"context_window":{"used_percentage":33},"model":{"display_name":"Test"}}'
  lo='{"session_id":"t1","rate_limits":{"five_hour":{"used_percentage":10},"seven_day":{"used_percentage":12}},"context_window":{"used_percentage":5}}'
  out=$(printf '%s' "$hi" | bash "$0" statusline);                 [[ "$out" == "[USAGE 5h 91% "*" · 7d 40%] [CONTEXT 33%] [MODEL Test]" ]] || { echo "FAIL statusline: $out"; exit 1; }
  printf '# comment\nprintf "[B1]"\njq -r .model.display_name\n' >"$d/usage-guard.badges"
  out=$(printf '%s' "$hi" | bash "$0" statusline);                 [[ "$out" == "[B1] Test [USAGE 5h 91% "* ]]                   || { echo "FAIL badges: $out"; exit 1; }
  rm "$d/usage-guard.badges"
  printf 'bash /x/ponytail-statusline.sh' >"$d/usage-guard.prev-statusline"; printf 'printf "[P]"' >"$d/usage-guard.badges"
  out=$(printf '%s' "$hi" | bash "$0" statusline);                 [[ "$out" == "[P] [USAGE 5h 91% "*"[MODEL Test]" ]]                     || { echo "FAIL badge prev should be skipped: $out"; exit 1; }
  rm "$d/usage-guard.prev-statusline" "$d/usage-guard.badges"
  out=$(printf '{"session_id":"t1"}' | bash "$0" stop);            [[ "$out" == *'"decision":"block"'* ]]            || { echo "FAIL stop should block: $out"; exit 1; }
  out=$(printf '{"session_id":"t1"}' | bash "$0" stop);            [ -z "$out" ]                                    || { echo "FAIL stop should block once: $out"; exit 1; }
  out=$(printf '{"session_id":"t1","stop_hook_active":true}' | bash "$0" stop); [ -z "$out" ]                       || { echo "FAIL stop_hook_active loop guard: $out"; exit 1; }
  printf '%s' "$lo" | bash "$0" statusline >/dev/null
  out=$(printf '{"session_id":"t1"}' | bash "$0" stop);            [ -z "$out" ]                                    || { echo "FAIL stop below threshold: $out"; exit 1; }
  out=$(printf '{"session_id":"t2"}' | bash "$0" statusline);      [[ "$out" == "[USAGE 5h - · 7d -] [CONTEXT -]" ]]            || { echo "FAIL statusline without rate_limits: $out"; exit 1; }
  printf '%s' "$hi" | bash "$0" statusline >/dev/null
  out=$(printf '{"session_id":"t1","context_window":{"used_percentage":50}}' | bash "$0" statusline); [[ "$out" == "[USAGE 5h 91% "*" · 7d 40%] [CONTEXT 50%]" ]] || { echo "FAIL sticky limits: $out"; exit 1; }
  out=$(printf '{"session_id":"t1","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":40000,"cache_read_input_tokens":20000}}}' | bash "$0" statusline); [[ "$out" == *"[CONTEXT 30%]" ]] || { echo "FAIL ctx from tokens: $out"; exit 1; }
  out=$(printf '{"session_id":"t1"}' | bash "$0" statusline);      [[ "$out" == *"[CONTEXT 30%]" ]]                      || { echo "FAIL sticky ctx: $out"; exit 1; }
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
