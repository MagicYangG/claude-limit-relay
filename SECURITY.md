# Security

Plain words, no legalese.

Nothing in v0.3 ever runs Claude unattended on your code — the v0.2
relay feature and its `--dangerously-skip-permissions` flag are gone.

## the panel binds localhost only

The status page (`claude-panel`) serves `http://localhost:7878` and does
not bind to any other network interface. It is not reachable from other
machines on your network by default. If you reverse-proxy or forward
this port yourself, that exposure is on you.

## nothing phones home

This repo makes no outbound network calls of its own. The only network
traffic it causes is:

- the scheduled preheat ping — `claude -p "hi" --model haiku`, run in
  `firepit/`, an empty scratch directory inside the repo, so the ping
  never sees your code — subject to whatever proxy/network config your
  `claude` CLI already uses (see `schedule.json`'s `proxy` field),
- your browser loading `localhost:7878` for the panel.

Optional BurntToast notifications are local toasts on your own machine,
and the statusline tap writes rate-limit numbers to a local file only
(`state-ratelimits.json`). No telemetry, no analytics, no third-party
services.

## state stays local

Tool **data** (`schedule.json`, logs, `state.json`,
`state-ratelimits.json`) lives inside the repo directory, and nothing is
uploaded anywhere. Two things are written outside the repo, both by
design and both removed by the uninstall steps in the README:

- a function block in your PowerShell profile (`preheat` /
  `claude-panel`), added by `install.ps1` with a timestamped backup,
- per-user scheduled tasks (`ClaudePreheat-*`), registered without
  elevation and running as you.

## single-user assumption

This tool is built for one person on their own machine. The panel's
POST protection blocks cross-site (browser) requests, but it has no auth
token, so any local process running as you can drive it — the same
privilege you already have to run the scripts directly. On a shared
machine, keep the repo directory writable only by your own account:
scheduled tasks execute the scripts from that directory as you.

## reporting a vulnerability

Please report security issues privately through GitHub's **Report a
vulnerability** button (repository → Security → Advisories), not as a
public issue.
