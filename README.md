# claude-usage-guard

A small bash tool for [Claude Code](https://code.claude.com) (one script plus an optional spinner-verb installer) that does two things:

1. **Shows your plan-limit usage in the status line**, with the 5-hour and 7-day windows, context-window fill, and current model, next to any plugin badges you already have.
2. **Stops cleanly before the limit cuts you off.** When a window crosses a threshold (default 98%), a `Stop` hook tells Claude to commit work in progress, write a handoff note, and stop, instead of getting killed mid-task.

```
[PONYTAIL] [CAVEMAN] [USAGE 5h 42% 15:45 · 7d 18%] [CONTEXT 31%] [MODEL Opus]
```

Each box has its own muted colour. A percentage keeps that colour, turns orange from 50%, and bold red at the threshold (default 98%). `15:45` is when the 5-hour window resets.

It makes no API calls and costs no usage. It only reads data Claude Code already hands to the status line.

## Requirements

- Claude Code with a **claude.ai Pro or Max** login. Only those accounts receive `rate_limits` in the status-line payload. Team, Enterprise, API-key, Bedrock, Vertex and gateway logins do not, so on those you get the CONTEXT and MODEL boxes but `-` for usage, and the Stop hook never fires.
- `bash` and `jq`.
  - macOS: `brew install jq`
  - Debian/Ubuntu: `sudo apt install jq`
  - Windows: `winget install --id Git.Git -e` (Git Bash) and `winget install jqlang.jq`. Run everything below in **Git Bash**, not PowerShell. Restart Claude Code from a fresh terminal after installing jq so it is on PATH.

## Install

```bash
curl -fsSL "https://raw.githubusercontent.com/alexanderleitch/claude-usage-guard/main/claude-usage-guard.sh?$(date +%s)" | bash -s install
```

What it does:

- Copies itself to `~/.claude/usage-guard.sh` (or `$CLAUDE_CONFIG_DIR/usage-guard.sh`).
- Sets `statusLine` in `~/.claude/settings.json` to run it. An existing status-line command is saved to `~/.claude/usage-guard.prev-statusline` and still runs after this one, unless it is itself a ponytail or caveman badge (those are covered by the badge chain below).
- Adds one `Stop` hook entry. Existing hooks are untouched.
- Backs up `settings.json` to `settings.json.bak-usage-guard`.
- Writes `~/.claude/usage-guard.badges` with the ponytail and caveman badge scripts pre-wired if those plugins are installed.

Re-running the same line is safe and is how you update. Claude Code picks the new status line up live; if it does not, open `/hooks` once or restart.

Verify:

```bash
bash ~/.claude/usage-guard.sh selftest      # expect: selftest ok
```

## What you see and when

- The usage numbers appear after the first API response in a session. Until then, and on refreshes where Claude Code omits them, the script shows the last values it saw for that session (cached in `$TMPDIR/cc-limits-<session_id>.json`).
- Claude Code drops a window from the payload once its reset time passes, so `5h -` right after a reset is normal until the next response.
- CONTEXT falls back to computing from token counts when `used_percentage` is missing, and otherwise keeps the last value.

## The Stop hook

At the end of every turn the hook reads the cached numbers. If the 5-hour or 7-day window is at or above the threshold it returns:

```json
{"decision":"block","reason":"Claude usage limit is at 98% (guard threshold 98%). Do not start new work. Commit work in progress, write a handoff note to the project PROGRESS.md (done / next / how to resume), then stop and tell the user the usage limit is nearly reached."}
```

Claude Code feeds that reason back to Claude, which does the commit and note, then stops. The hook fires **once per session per window**; after the window resets and usage drops below the threshold it re-arms. It never fires while `stop_hook_active` is set, so it cannot loop.

Threshold: set `CLAUDE_USAGE_GUARD_PCT` (default `98`, so the guard only fires right before the cut-off and saves state; lower it if you want more headroom) in the environment Claude Code runs in, or in `settings.json` under `"env"`.

### What it cannot do

- Subagents (`Agent` tool), `claude -p`, and background sessions do not run the status line, so their usage is never cached and they are not stopped. Bound subagents with `maxTurns` in their frontmatter and headless runs with `--max-budget-usd`.
- No hook event exists for an approaching limit, and hooks never receive `rate_limits`. This script bridges that gap by having the status line cache the numbers. If Anthropic adds the field to hook payloads, the cache becomes unnecessary.
- `StopFailure` fires *after* a limit is hit and its output is ignored, so it can only alert, not steer. Pair this guard with `autoContinueAtUsageLimit` (on by default for subscriptions) so a hit becomes a pause rather than a loss.

## Badges

`~/.claude/usage-guard.badges` is a plain file with one shell command per line. Each command receives the status-line JSON on stdin and whatever it prints is shown before the usage boxes. Lines starting with `#` are ignored. The installer pre-fills:

```bash
f=$(ls -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/ponytail/ponytail/*/hooks/ponytail-statusline.sh 2>/dev/null | tail -1); [ -n "$f" ] && bash "$f"
f=$(ls -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/caveman/caveman/*/src/hooks/caveman-statusline.sh 2>/dev/null | tail -1); [ -n "$f" ] && bash "$f"
```

Add your own, for example a git branch:

```bash
printf '\033[38;5;103m[%s]\033[0m' "$(git -C "$(jq -r .workspace.current_dir)" branch --show-current 2>/dev/null)"
```

Delete a line to drop a badge. Delete the file and re-run install to regenerate the defaults.

## Colours

256-colour ANSI, chosen to sit next to the ponytail (108) and caveman (172) badges:

| Box | Colour |
|---|---|
| USAGE | 67 steel blue |
| CONTEXT | 139 mauve |
| MODEL | 73 teal |
| ≥ 50% | 173 orange |
| ≥ threshold | 167 red, bold |

`CLAUDE_USAGE_GUARD_COLOR=0` renders plain text. Legacy Windows `conhost` does not render 256 colours; use Windows Terminal.

## Commands

```bash
bash ~/.claude/usage-guard.sh install     # install or update (default)
bash ~/.claude/usage-guard.sh uninstall   # restore previous statusLine, remove hook and files
bash ~/.claude/usage-guard.sh selftest    # run the built-in checks
bash ~/.claude/usage-guard.sh statusline  # what Claude Code calls; JSON on stdin
bash ~/.claude/usage-guard.sh stop        # what the Stop hook calls; JSON on stdin
```

## Troubleshooting

- **Blank status line.** Pipe a payload by hand and read the error:
  ```bash
  echo '{"session_id":"t","context_window":{"used_percentage":5}}' | bash ~/.claude/usage-guard.sh statusline
  ```
  Usually `jq` is missing from PATH inside Claude Code. Restart Claude Code from a terminal where `jq --version` works.
- **`[USAGE 5h - · 7d -]` forever.** The account is not a Pro/Max claude.ai login (see Requirements), or no API response has happened yet in this session.
- **A badge shows twice.** An older status-line command that prints the same badge is stored in `~/.claude/usage-guard.prev-statusline`. Delete that file.
- **Update not taking effect.** `raw.githubusercontent.com` caches for a few minutes; the `?$(date +%s)` in the install line bypasses that. Compare `md5sum ~/.claude/usage-guard.sh` with the file in this repo.
- **Windows: hooks run under PowerShell.** Claude Code needs Git Bash. Install Git for Windows, or point `CLAUDE_CODE_GIT_BASH_PATH` at `C:\Program Files\Git\bin\bash.exe`, then restart.

## How it works

Claude Code passes a JSON payload to the `statusLine` command on every refresh. On Pro/Max that payload includes:

```json
"rate_limits": {
  "five_hour": {"used_percentage": 42, "resets_at": 1758640000},
  "seven_day": {"used_percentage": 18, "resets_at": 1759000000}
}
```

Hook payloads do not carry this field and no hook fires on an approaching limit. So the status line command writes the numbers to a per-session cache file, and the `Stop` hook reads that file at the end of each turn. `Stop` supports `decision: "block"` with a `reason`, which is what turns "nearly out of usage" into "commit and write a handoff note".

Docs: [status line](https://code.claude.com/docs/en/statusline), [hooks](https://code.claude.com/docs/en/hooks), [costs and limits](https://code.claude.com/docs/en/costs).

## Spinner verbs (bonus)

`spinner-verbs.json` is an unrelated extra: a set of grumpy spinner verbs with ASCII art and emoji. Install them into `~/.claude/settings.json` (replaces `spinnerVerbs`, backup at `settings.json.bak-spinner`, restart Claude Code after):

```bash
curl -fsSL "https://raw.githubusercontent.com/alexanderleitch/claude-usage-guard/main/install-spinner.sh?$(date +%s)" | bash
```

Edit `spinner-verbs.json` in a clone and run `bash install-spinner.sh` to install your own list.

## Uninstall

```bash
bash ~/.claude/usage-guard.sh uninstall
```

Restores the previous `statusLine`, removes the `Stop` hook entry and the files under `~/.claude`. `settings.json.bak-usage-guard` is left in place.

## License

MIT
