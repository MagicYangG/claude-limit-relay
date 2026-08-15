# Security

Plain words, no legalese.

## relay resumes sessions unattended

`relay` resumes a Claude Code session headless via:

```
claude --resume <id> -p --dangerously-skip-permissions
```

That flag means the resumed leg runs **without asking for tool-use
confirmation**. It exists because the whole point of `relay` is to keep
work moving while you are away and cannot approve anything.

Consequences:

- Only arm `relay` on sessions running in a project directory you are
  comfortable letting act unattended (file writes, shell commands, git
  operations, etc. all proceed without a human in the loop).
- Do not arm `relay` on a session sitting in a directory with secrets,
  production credentials, or systems you would not want touched without
  review.
- Prefer isolated / disposable project directories for anything you plan
  to `relay arm -Watch` and walk away from.
- Review `relay-out-*.log` and the session transcript after a leg
  finishes, same as you would review any unattended agent run.

## the panel binds localhost only

The status page (`claude-panel`) serves `http://localhost:7878` and does
not bind to any other network interface. It is not reachable from other
machines on your network by default. If you reverse-proxy or forward
this port yourself, that exposure is on you.

## nothing phones home

This repo makes no outbound network calls of its own. The only network
traffic it causes is:

- the `claude` CLI calls it invokes (preheat pings, relay resumes,
  probes) — subject to whatever proxy/network config your `claude` CLI
  already uses (see `schedule.json`'s `proxy` field),
- your browser loading `localhost:7878` for the panel.

No telemetry, no analytics, no third-party services.

## state stays local

Tool **data** (`schedule.json`, logs, `armed/`, `done/`, `state.json`)
lives inside the repo directory, and nothing is uploaded anywhere. Two
things are written outside the repo, both by design and both removed by
the uninstall steps in the README:

- a function block in your PowerShell profile (`preheat` / `relay` /
  `claude-panel`), added by `install.ps1` with a timestamped backup,
- per-user scheduled tasks (`ClaudePreheat-*`, `ClaudeRelay-Probe`),
  registered without elevation and running as you.

## single-user assumption

This tool is built for one person on their own machine. The panel's
POST protection blocks cross-site (browser) requests, but it has no auth
token, so any local process running as you can drive it — the same
privilege you already have to run `relay.ps1` directly. On a shared
machine, keep the repo directory writable only by your own account:
scheduled tasks execute the scripts from that directory as you.

## reporting a vulnerability

Please report security issues privately through GitHub's **Report a
vulnerability** button (repository → Security → Advisories), not as a
public issue.
