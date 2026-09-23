# claude-usage-guard

One bash script. Shows Claude Code plan-limit usage in the status line and asks Claude to
commit + write a handoff note before the limit cuts the session off.

```
[PONYTAIL] [CAVEMAN] 5h 42% (15:45) | 7d 18% | ctx 31% | Opus
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/alexanderleitch/claude-usage-guard/main/claude-usage-guard.sh | bash -s install
```

Needs `bash` and `jq`. Windows: install Git for Windows (`winget install --id Git.Git -e`) and
`winget install jqlang.jq`, then run the line above in Git Bash. Restart Claude Code afterwards.

An existing `statusLine` command is preserved and still runs after this one. Existing `Stop`
hooks are untouched. `~/.claude/settings.json` is backed up to `settings.json.bak-usage-guard`.

## What it does

- `statusline`: prints the line above and caches `rate_limits` to `$TMPDIR/cc-limits-<session_id>.json`.
- `stop`: at the end of each turn, if the 5-hour or 7-day window is at or above the threshold
  (default 85%, `CLAUDE_USAGE_GUARD_PCT`), returns `decision: "block"` with a reason telling
  Claude to commit, write `PROGRESS.md`, and stop. Fires once per session per window.
- Badges: `~/.claude/usage-guard.badges` holds one shell command per line; each gets the payload on
  stdin and its output is shown before the usage line. Install pre-fills it with the ponytail and
  caveman plugin badges when those plugins are present. Edit the file to add or remove badges.
- Zero API calls. Costs no usage.

## Limits

- `rate_limits` is only sent to the status line on Pro/Max, and only after the first API response.
- The status line does not run in `-p`, background, or subagent contexts, so subagents are not covered.
  Bound them with `maxTurns` in agent frontmatter.

## Other commands

```bash
bash ~/.claude/usage-guard.sh selftest
bash ~/.claude/usage-guard.sh uninstall
```
