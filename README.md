# Curator — AI Desktop Curator for Omarchy

A third-party plugin for Omarchy 4.0 "Quattro" that uses your default coding agent (or a local Ollama model) to reason about your stated preferences and live desktop context, then recommend the ideal desktop state: apps, workspaces, theme, notifications, night light.

It is deliberately **advisory-first**: every plan is previewed and nothing runs until you hit Apply. Undo restores the pre-apply snapshot. Auto-apply exists but is double-gated (a global setting *and* a per-mode `trusted` flag).

Plugin id: `curator.desktop` · Kinds: `service` + `panel` + `bar-widget`

## How it works

```
bar badge ──click──▶ panel (chat + plan preview + Apply/Undo)
                        │ omarchy-shell curator <method>
                        ▼
service (always loaded) ── context probe (hyprctl -j, time, battery, theme, DND)
                        ── learned habits (aggregated from ~/.local/state/omarchy/curator.db)
                        ── prompt = skill + prefs + context + habits + request
                        ── bin/curator-agent (default agent, headless — or Ollama)
                        ── JSON plan → validated against the action allowlist
                        ── Apply: snapshot first, then run · Undo: restore snapshot
```

All plan actions pass through a validator (`Model.js`) before anything executes:

- `theme`, `background`, `workspace` (1–10), `dnd`, `nightlight` — mapped to `omarchy-theme-set`, `omarchy-theme-bg-next`, and `omarchy-shell` IPC calls
- `hyprctl` — `dispatch` only, from a fixed dispatcher allowlist (no `exec`, no `keyword`), with shell metacharacters rejected
- `exec` — bare command names only, and only apps listed in your prefs (`allowedApps` plus every mode's `preferredApps`), launched via `omarchy-launch-or-focus`

Anything else the model returns is shown struck-through in the preview with the rejection reason, and never runs. There is no arbitrary shell execution path.

## Install

```bash
omarchy plugin add https://github.com/aphexddb/omarchy-curator.git
# review the code, then:
omarchy plugin enable curator.desktop
omarchy bar put curator.desktop --section right
```

Optional hotkey (in your Hyprland bindings):

```
bindd = SUPER SHIFT, C, Curator, exec, omarchy-shell shell toggle curator.desktop "{}"
```

The plugin needs a model to talk to: either a default agent with a headless mode (`omarchy default agent claude|codex|opencode|crush|grok`) or Ollama with at least one model pulled.

## Usage

- **Bar badge** — shows the inferred mode (`✦ deep-work · 87%`), or `✦ learning · 3/7d` during the listen-only period. Left-click opens the panel, right-click asks for a suggestion in the background (you get a notification when it's ready).
- **Panel** — free-text requests ("set up for deep work", "what should I be seeing right now?"), the rationale, the validated action plan, an optional layout silhouette, and Suggest / Apply / Undo / Dismiss. `Ctrl+Enter` applies, `Ctrl+U` undoes, `Esc` closes.
- **CLI** — everything is also scriptable:

```bash
omarchy-shell curator suggest "set up for a meeting"
omarchy-shell curator status
omarchy-shell curator apply
omarchy-shell curator undo
omarchy-shell curator dismiss
omarchy-shell curator finishListening   # end the listen-only period early
```

## Learning

On first run Curator enters a **listen-only period of 7 days**. During it there are **no AI calls at all** — the service just samples your desktop cheaply (every 90 seconds by default) and stores what it sees:

- timestamp, hour of day, day of week
- focused window class (never titles, never screenshots)
- open windows per workspace and the active workspace
- battery percentage and charging state (from `/sys/class/power_supply/BAT*`)
- current theme, DND state, night light state

While listening, `suggest` answers `listening (day 3/7)` instead of calling the agent, the bar badge shows `✦ learning · 3/7d`, and the panel shows the learning status plus a read-only list of your installed themes. The listen period start is tracked in the shared state file, so it survives shell restarts.

Escape hatches:

- `omarchy-shell curator finishListening` — end the period early and unlock suggestions now.
- `"learning": { "enabled": false }` in prefs — disable listen mode and sampling entirely.

Samples land in a SQLite database at `~/.local/state/omarchy/curator.db` (`PRAGMA user_version = 1`, one `samples` table: `ts, hour, dow, focused_class, active_workspace, window_count, workspace_windows, battery, charging, theme, dnd, nightlight`). Inserts are buffered in memory and flushed in batches — one `sqlite3` invocation per handful of samples — so the cost stays negligible. If the `sqlite3` CLI is missing, learning degrades gracefully: a warning is logged, `sqliteMissing` is noted in the state file, and everything else keeps working.

**After the listen period, sampling continues forever at one fifth of the rate** (every 7.5 minutes by default) so the habit picture keeps tracking how your usage drifts. From then on, every `suggest` runs one aggregation query over the last 30 days — top focused apps by time of day, theme usage share, battery/charging patterns, DND share — and injects the result as a compact `## Learned habits` JSON section into the prompt. All aggregation SQL lives in `Learnings.js`.

## Preferences

`~/.config/omarchy/curator/prefs.json` is created with defaults on first load and hot-reloads on save:

```json
{
  "version": 1,
  "modes": {
    "deep-work": {
      "description": "Focused coding or writing. Terminal and editor only, notifications silenced.",
      "preferredApps": ["alacritty", "nvim", "obsidian"],
      "theme": "",
      "dnd": true,
      "trusted": false
    }
  },
  "timeRules": [
    { "from": "09:00", "to": "12:00", "prefer": "deep-work" }
  ],
  "allowedApps": ["alacritty", "nautilus", "chromium", "obsidian", "spotify"],
  "autoApplyTrusted": false,
  "learning": {
    "enabled": true,
    "sampleIntervalSeconds": 90
  },
  "privacy": {
    "preferLocalLLM": false,
    "ollamaModel": "",
    "sendWindowTitles": true
  }
}
```

- `modes` — free-form; the whole object is handed to the model, so extra keys (music, gaps, whatever) are fine and become part of the reasoning.
- `autoApplyTrusted` + per-mode `trusted: true` — both must be set before a plan applies without confirmation.
- `learning.enabled` — set `false` to turn off the listen-only period and all sampling. `learning.sampleIntervalSeconds` sets the listen-period sampling cadence (post-listen sampling runs at 5x that interval).
- `privacy.preferLocalLLM` — route to Ollama first; `ollamaModel` pins a model (otherwise the first installed one is used).
- `privacy.sendWindowTitles` — set `false` to send only window classes, never titles.

## Testing

Model logic (no Omarchy needed):

```bash
node test/model-test.js
```

Manifest against the shell's schema (from an omarchy checkout):

```bash
omarchy plugin validate /path/to/omarchy-curator
```

On an Omarchy box, without waiting for a git install:

```bash
git clone https://github.com/aphexddb/omarchy-curator.git ~/.config/omarchy/plugins/curator.desktop
omarchy-shell shell rescanPlugins
omarchy plugin enable curator.desktop
omarchy bar put curator.desktop --section right
omarchy-shell curator suggest ""          # then watch: omarchy-shell curator status
```

Debug artifacts land in `~/.local/state/omarchy/`: `curator-prompt.txt` (the exact prompt sent), `curator-response.txt` (the raw model output), `curator.json` (shared state), `curator.db` (the habit samples — inspect with `sqlite3 ~/.local/state/omarchy/curator.db 'SELECT * FROM samples ORDER BY ts DESC LIMIT 20'`). Saving any file in the plugin directory hot-reloads it.

## Privacy, safety, limitations

- Context sent to the model: window classes (titles optional), workspace ids, time, battery, current theme, DND state, plus the aggregated learned habits. Never screenshots, never pids or addresses.
- Learned samples never leave your machine: they live in a local SQLite file, contain window classes but never titles, and only the compact aggregates reach the model.
- Undo restores theme, focused workspace, DND, and night light from the pre-apply snapshot — it cannot un-move windows or close launched apps.
- Headless agent support: claude, codex, opencode, crush, grok. Others (pi, omp, ori, agy, copilot) fall through to Ollama.
- Same trust model as every Omarchy plugin: it runs unsandboxed inside `omarchy-shell`. Review before enabling.

## License

MIT
