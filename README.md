# claude-preheat

**English** | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md)

For Claude subscribers who work in the Claude Code CLI on Windows. One job: the 5-hour usage window is anchored by the first message sent while no window is active — a scheduled tiny ping anchors it at the time you choose, so your real session starts with a window already ticking and your work spans two windows instead of being cut mid-flow.

## Web panel

Local address: `localhost:7878` (bilingual English/中文, one-click toggle in the header)

Modules: live quota strip (5-hour + weekly, with exact reset times — run `preheat statusline on` once to feed it) / weekly reset-time editor (writes `schedule.json` and applies it) / one-shot preheats / 7-day window-utilization line (`preheat learn` under the hood)

![panel](docs/panel.png)

## Quick start

**Requirements**: Windows 10/11; [Claude Code CLI](https://code.claude.com/docs) installed and logged in; a Claude subscription; PowerShell 7 (pwsh); no admin rights needed

**Recommended: paste this into Claude Code (or any AI coding tool) and let it install everything for you:**

```text
Clone https://github.com/MagicYangG/claude-preheat and set it up:
1. git clone, then run install.ps1 inside the repo directory
2. Ask me for the weekly times I want the window to reset, write them into schedule.json
   (reset = the target reset time; the fire time is automatically reset minus 5 hours)
3. Run ./test.ps1 and confirm every case passes
4. Run preheat apply, then show me the output of preheat status
Do not register or change anything beyond what install.ps1 and preheat apply create.
```

When it's done, open `http://localhost:7878` in your browser and drive everything from the panel.

**Manual install is three steps**: `git clone` → `./install.ps1` → run `preheat apply` in a new terminal. Full commands in the [command reference](#command-reference).

## Notes

1. **Claude Code CLI required**: a preheat is a tiny headless prompt executed through the CLI
2. **Pinging an active window is a harmless no-op**: it costs one trivial message and moves nothing
3. **Waking from sleep**: a scheduled fire can only wake the PC if wake timers are enabled in the active power plan — `preheat status` warns when they are off

## Where did the relay go?

v0.2.0 shipped a cross-window auto-resume ("relay") that revived limit-killed sessions when the quota returned. Claude Code v2.1.234 added native auto-continue — on by default, toggle in `/config` under "Continue automatically at usage limit" — which handles the stay-at-the-keyboard case in-process, with exact reset times, and better than an external watcher ever could. v0.3.0 retired relay rather than compete with the platform; the last relay release is preserved at tag [v0.2.0](https://github.com/MagicYangG/claude-preheat/releases/tag/v0.2.0). What the native feature does not do — start your window before you sit down — is exactly what preheat does.

## Command reference

The panel covers everyday use; the commands below are for terminal people and scripts.

```powershell
preheat apply           # register weekly preheat tasks from schedule.json (re-run after edits)
preheat status          # local activity + registered tasks + recent journal
preheat reset 20:00     # one-shot: make the window reset at 20:00 (fires at 15:00)
preheat at 15:00        # one-shot: fire at 15:00
preheat +2h             # one-shot: fire 2 hours from now
preheat learn           # schedule suggestions from your last 30 days + window-utilization report (learn auto applies)
preheat statusline on   # tap the statusline so exact reset times feed the panel quota strip (pure passthrough; off restores)
preheat off             # remove all preheat tasks
claude-panel            # open the local web panel
```

In `schedule.json`, `reset` is the **target reset time**; the fire time is automatically reset − 5h. An empty `proxy` means no proxy.

## Uninstall

```powershell
preheat off             # remove all preheat tasks
preheat statusline off  # restore the original statusline (if you enabled the tap)
```

Then delete the lines between `# >>> claude-preheat functions >>>` and
`# <<< claude-preheat functions <<<` in your PowerShell profile (older installs
may have `claude-limit-relay` markers instead), and remove the repo directory.
