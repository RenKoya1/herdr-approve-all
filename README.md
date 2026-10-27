# herdr-approve-all

A [herdr](https://herdr.dev) plugin that approves every blocked agent at once —
or automatically, the moment one blocks.

When you run a fleet of coding agents (Claude Code, Codex, Gemini CLI, ...),
permission prompts pile up and you end up pressing **Yes** pane by pane. This
plugin sends the confirm key to every waiting pane, accepting the highlighted
default option (usually **Yes**) in one keystroke — or with zero keystrokes in
auto mode — then checks each pane actually moved on and answers whatever queued
up behind it.

Works with any agent herdr detects; the confirm key defaults to `Enter`, which
accepts the highlighted default in Claude Code, Codex, Gemini CLI, and the rest
of herdr's supported agents.

## Install

```sh
herdr plugin install RenKoya1/herdr-approve-all
```

For a local checkout, link the checkout instead of installing from GitHub:

```powershell
herdr plugin link C:\path\to\herdr-approve-all --enabled
```

Windows uses the action IDs `approve-blocked-windows`, `auto-on-windows` and
`auto-off-windows` (all prefixed with `renkoya1.approve-all.`). For example:

```powershell
herdr plugin action invoke renkoya1.approve-all.approve-blocked-windows
herdr plugin action invoke renkoya1.approve-all.auto-on-windows
herdr plugin action invoke renkoya1.approve-all.auto-off-windows
```

Use `renkoya1.approve-all.approve-blocked-windows` in the keybinding below on
Windows. Windows sweeps process panes sequentially; repeat the action for new
prompts. Hold-to-repeat and idle debounce described below apply to Unix only.
Existing auto-approve configuration is retained when switching plugin sources.

On Windows, enabling auto mode also starts one hidden PowerShell monitor. It
rechecks the fleet every `APPROVE_AUTO_POLL_SEC` seconds (default `1`), so later
prompts are handled even when Herdr does not emit another status-change event.
The monitor also checks the visible prompt fallback, uses the same pane locks as
manual/event actions, and exits when auto mode is turned off. A Windows startup
hook restores it when the persisted toggle is on. Event hooks can restart it if
it has stopped. Enabling auto mode again starts it for an already-running Herdr.
The worker's PID and latest result/error are written to `monitor.pid` and
`monitor.log` under `HERDR_PLUGIN_STATE_DIR` (or `state` under the config dir).

## Manual sweep

Bind the sweep to a key in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "ctrl+enter"
type = "plugin_action"
command = "renkoya1.approve-all.approve-blocked"
```

> `ctrl+enter` only reaches herdr if your terminal distinguishes it from plain
> `Enter` (e.g. Ghostty / Kitty with the kitty keyboard protocol). If it does
> not, bind a prefix chord instead, e.g. `key = "prefix+y"`.

Reload the config after editing: `herdr server reload-config`

Or invoke from the CLI:

```sh
herdr plugin action invoke renkoya1.approve-all.approve-blocked
```

A toast reports how many agents were **verified** approved, plus how many are
still blocked after the sweep gave up on them.

## Auto-approve mode

Approve every prompt the instant an agent blocks — no keypress at all:

```sh
herdr plugin action invoke renkoya1.approve-all.auto-on
herdr plugin action invoke renkoya1.approve-all.auto-off
```

The plugin subscribes to agent status changes; when a pane turns `blocked`, it
sends the confirm key immediately and then drains whatever queued up behind it.
The toggle persists across restarts (it's a marker file in the plugin config
dir).

**This is the YOLO switch.** It approves *every* prompt in *every* pane,
including "run this destructive command?". Turn it on only when you'd answer
Yes to anything your fleet asks.

## Per-agent confirm keys

`Enter` is right for every agent we know of. If some agent needs a different
sequence, create `keys.conf` in the plugin config dir
(`herdr plugin config-dir renkoya1.approve-all`) with one line per agent:

```
codex=y enter
```

Key names follow `herdr agent send-keys` (e.g. `enter`, `esc`, `y`).

## Stacked prompts

A pane rarely asks once. A fleet of subagents queues several permission prompts
behind each other, and herdr reports `blocked` -> `blocked` across them: the
status never changes, so no new event fires and a single confirm key clears only
the first one.

So the sweep does not fire and forget. Per pane it sends the confirm key, waits
for the pane to leave `blocked`, then looks again — up to `APPROVE_MAX_SENDS`
(5) prompts per run. Auto mode runs the same drain, which is what makes it
survive a burst.

## Which panes get swept

Every agent pane is a candidate, not only the ones herdr reports as `blocked`.
herdr derives that status by scraping the terminal, and a live prompt can lose
to a higher-priority detection rule (a spinner in the OSC title, the composer's
own idle rule) — leaving a pane that is visibly waiting reported as
`working`/`idle` and, before this, silently skipped.

The fallback therefore also matches the visible screen: an `esc to cancel`
footer (only rendered while a dialog is live) plus a numbered/highlighted option
line. Set `APPROVE_SCRAPE_FALLBACK=0` to trust herdr's status alone.

## Hold the key to keep approving

Auto-repeat is used rather than fought. **Hold the key down and the sweep stays
alive**, re-checking the fleet every ~240ms, so prompts that appear while you
are still holding get approved as they arrive. Let go and it stops.

Mechanically: the first instance takes the lock and loops; every repeat that
lands while it runs drops a marker and exits in ~10ms, so herdr's concurrent
plugin command cap (32) is never approached. When the markers stop arriving,
the grace window lapses and the sweeper exits (with a `HOLD_MAX` backstop for a
wedged key).

The only debounce left applies to a sweep that found **nothing**: a 1s window,
so a held key over a quiet fleet doesn't re-list it as fast as bash can fork. A
sweep that *did* approve something sets no window at all, so a deliberate
re-press is always honoured immediately. (Before 0.3.0 a flat 10s window applied
to every sweep, which silently ate exactly the presses that mattered: the ones
aimed at the next prompt in a burst.)

## Tuning

Env vars, read by both the sweep and the auto handler:

| Var | Default | Meaning |
| --- | --- | --- |
| `APPROVE_MAX_SENDS` | `5` | confirm keys per pane, per pass |
| `APPROVE_LEAVE_TIMEOUT_MS` | `1200` | how long to wait for a pane to leave `blocked` |
| `APPROVE_SETTLE_SEC` | `0.15` | pause before re-checking, so a queued prompt can paint |
| `APPROVE_SCRAPE_FALLBACK` | `1` | also sweep panes whose live prompt herdr missed |
| `APPROVE_IDLE_DEBOUNCE_SEC` | `1` | window after an empty sweep |
| `APPROVE_HOLD_POLL_SEC` | `0.08` | hold-detection granularity |
| `APPROVE_HOLD_POLLS` | `3` | grace windows before a hold is considered released |
| `APPROVE_HOLD_MAX_SEC` | `60` | backstop: longest a single hold keeps sweeping |
| `APPROVE_AUTO_POLL_SEC` | `1` | Windows auto monitor pause between fleet checks (minimum `0.1`) |

## Windows verification

Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/windows-smoke.ps1`.
The test uses a mock Herdr in a temporary directory and checks stacked prompts,
configured keys, repeated automatic prompts without events, visible-prompt
fallback when the reported status stays working, stopping auto mode, and
restoring the persisted toggle at startup.

## What it does (and doesn't)

- Sends the confirm key, i.e. accepts whatever option is highlighted. For
  permission prompts that is **Yes**; for other blocking dialogs (question
  cards, plan approvals, trust dialogs) it picks the default option.
- A pane still blocked after `APPROVE_MAX_SENDS` is reported in the toast rather
  than passed off as approved.

**Caution**: this is indiscriminate by design. If a pending prompt is asking to
run a destructive command, this approves it too. Glance at your panes before
pressing the key — or accept the risk knowingly with auto mode.

## Requirements

- herdr ≥ 0.7.4
- macOS / Linux: `bash` on PATH, plus `jq` (fast path) or `python3` (fallback)
- Windows: Windows PowerShell (`powershell.exe`); Herdr's Windows plugin support
  may depend on the installed Herdr release.

## License

MIT
