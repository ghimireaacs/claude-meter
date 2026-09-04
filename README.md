# claude-meter

Claude Code plan usage on your status bar — how much of the 5-hour session
window and the 7-day window you have burned, and when each one resets.

```
$ claude-meter
plan pro
Session (5h)   [######..............]  31%  resets in 2h 45m
Weekly         [####................]  20%  resets in 4d 7h
```

Two pieces that work independently:

- **`claude-meter`** — a dependency-free Python 3 CLI that prints usage as a
  table, a Waybar JSON object, or a full JSON report.
- **A [Noctalia](https://noctalia.dev) v5 bar widget** that draws what the CLI
  reports — for Niri, Hyprland, or any compositor Noctalia runs on. No Waybar
  required.

If you are on Waybar (Omarchy and friends), skip the widget and use the CLI's
`--json` mode directly.

## Features

- Session (5h) and weekly windows, plus the per-model weekly windows when the
  API reports them (Opus, Sonnet).
- Reset countdowns, and a pace note when usage runs more than 10 points ahead
  of or behind the time elapsed in the window.
- On-disk cache with a 300-second default lifetime, because the usage endpoint
  rate-limits aggressively below roughly five minutes.
- A failed read keeps the last good numbers and flags them `stale` instead of
  blanking the bar.
- Automatic OAuth token refresh, written back atomically with `0600`
  permissions under a lock file, so two bars cannot race the same refresh
  token.
- No dependencies beyond Python 3.9+: no `jq`, no `curl`, no crates, no
  node_modules.

## Requirements

- Python 3.9 or newer.
- [Claude Code](https://claude.com/claude-code), logged in — the CLI reuses the
  credentials it already wrote to disk. Subscription (Pro/Max) accounts only;
  the usage endpoint does not cover pay-as-you-go API keys.
- For the widget: Noctalia v5 (plugin API 3 or newer).

## Install

### Everything, from a checkout

```bash
git clone https://github.com/ghimireaacs/claude-meter.git
cd claude-meter
./install.sh
```

`install.sh` symlinks the CLI into `~/.local/bin`, registers `plugins/` as a
Noctalia plugin source pointing at the checkout, and enables the plugin.
Nothing is copied, so editing a file in the checkout changes what runs — pull
and reload, no reinstall.

Then place the widget: **Settings → Bar → (pick a section) → Claude Meter**, or
open its settings directly:

```bash
noctalia msg settings-open-plugin ghimireaacs/claude-meter
```

### CLI only

```bash
install -m755 bin/claude-meter ~/.local/bin/claude-meter
```

### Noctalia plugin, manually

```bash
noctalia msg plugins source add claude-meter path /path/to/claude-meter/plugins
noctalia msg plugins enable ghimireaacs/claude-meter
```

### Uninstall

```bash
noctalia msg plugins disable ghimireaacs/claude-meter
noctalia msg plugins source remove claude-meter
rm ~/.local/bin/claude-meter
rm -rf ~/.cache/claude-meter
```

## CLI usage

```bash
claude-meter                                              # table for humans
claude-meter --json                                       # Waybar object
claude-meter --report                                     # full JSON report
claude-meter --metric seven_day --format '{label} {pct}% ({reset})'
claude-meter --refresh                                    # bypass the cache
claude-meter --watch 300                                  # reprint on a timer
```

| Flag | Meaning |
| --- | --- |
| `--json` | Waybar-compatible object on one line (`text`, `tooltip`, `percentage`, `class`) |
| `--report` | Full JSON report; this is what the Noctalia widget consumes |
| `--metric` | `auto` (busiest window), `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet` |
| `--format` | Template over `{pct}`, `{remaining}`, `{label}`, `{reset}`, `{plan}`, `{stale}` |
| `--ttl` | Cache lifetime in seconds (default `300`) |
| `--refresh` | Ignore the cache for this read |
| `--watch N` | Reprint every N seconds (floored at 60) |

Exit status is `1` when no usage could be read, cached or otherwise.

### Report shape

`--report` is stable enough to script against:

```json
{
  "ok": true,
  "fetched_at": 1788525092,
  "stale": false,
  "plan": "pro",
  "tier": "default_claude_ai",
  "metrics": [
    {
      "id": "five_hour",
      "label": "Session (5h)",
      "percent": 31,
      "severity": "ok",
      "resets_at": 1788535200.31,
      "resets_in": 9908,
      "elapsed_percent": 45
    }
  ],
  "error": null
}
```

`severity` is `ok` under 60%, `warning` from 60%, `critical` from 85%. When a
read fails but the cache holds a report, `stale` is `true` and `error` names
the failure while the numbers stay put.

### Waybar

```jsonc
"custom/claude": {
  "exec": "claude-meter --json",
  "return-type": "json",
  "interval": 300,
  "format": "󰧑 {}",
  "on-click": "claude-meter --refresh"
}
```

Style on the `class` the module reports:

```css
#custom-claude.warning  { color: @yellow; }
#custom-claude.critical { color: @red; }
#custom-claude.stale    { opacity: 0.6; }
```

Keep `interval` at 300 or above. Lower values earn HTTP 429s, and the widget
will spend its time showing you cached numbers.

## Noctalia widget

Per-instance settings, so a second capsule can follow a second window:

- **Window** — which usage window this capsule tracks; `auto` follows whichever
  is closest to running out.
- **Show icon / window name / countdown** — what goes in the capsule.
- **Color by usage** — neutral, then warning, then error as the reading climbs.

Plugin-wide: **Refresh interval** in minutes, floored at 5.

Left-click forces a read. The tooltip lists every window, the plan, the reset
countdowns, and the pace note.

## How it works

The CLI reads the OAuth credentials Claude Code already stored in
`~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR/.credentials.json`) and
calls `GET https://api.anthropic.com/api/oauth/usage` — the same undocumented
endpoint behind Claude Code's own `/usage` command — with the
`anthropic-beta: oauth-2025-04-20` header.

When the stored access token has expired, it exchanges the refresh token at
`https://platform.claude.com/v1/oauth/token` using the public Claude CLI client
id, then rewrites the credentials file atomically at `0600`. The exchange runs
under an exclusive lock in `~/.cache/claude-meter/`, because a refresh token is
spent once and two simultaneous refreshes would leave one of them holding a
dead credential.

Reports are cached in `$XDG_CACHE_HOME/claude-meter/report.json`. The Noctalia
widget polls the CLI rather than the network, so several capsules on the same
interval cost one request between them.

## Security notes

- Credentials are read from and written back to the file Claude Code owns.
  Nothing is copied elsewhere, and no request goes anywhere but
  `api.anthropic.com` and `platform.claude.com`.
- Tokens never appear in a command line, so they never land in `/proc/<pid>/cmdline`
  where other users on the machine could read them.
- The cache holds usage percentages and reset timestamps only — no tokens.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `no_credentials` | Claude Code has not been logged in, or `CLAUDE_CONFIG_DIR` points elsewhere. Run `claude` and sign in. |
| `rate_limited` | Polling faster than the endpoint tolerates. Raise the interval to 300s or more. |
| `refresh_failed` | The refresh token was rejected — usually an expired or revoked session. Log in with `claude` again. |
| Widget shows the icon only | The CLI is not on the PATH Noctalia inherited. Check `command -v claude-meter` in the session that launched the shell, or symlink it into `/usr/local/bin`. |
| A window vanished from the tooltip | The endpoint stopped reporting that field. It is undocumented and can change without notice. |

## Prior art

The endpoint knowledge here comes from two projects worth a look if you want
more providers or a richer Waybar module:

- [claudebar](https://github.com/mryll/claudebar) — pure Bash, Omarchy theming.
- [ai-usagebar](https://github.com/akitaonrails/ai-usagebar) — Rust, many
  vendors, TUI included.

## License

MIT. See [LICENSE](LICENSE).
