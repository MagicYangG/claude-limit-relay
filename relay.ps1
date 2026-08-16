#Requires -Version 5.1
<#
claude-relay -- resume interrupted work when the Max 5h usage limit resets (P2)
Multi-relay: any number of sessions can be armed at once (one file per session
under armed\); a single global probe task serves them all, because the limit is
account-wide. When the window reopens, ALL waiting sessions resume in parallel.

Commands:
  arm [sessionIdPrefix]   Arm a session (latest by default, picker confirms).
                          -Watch = sentry mode: limit has NOT hit yet; watch the
                          task, auto-switch to wait mode if the limit trips.
  disarm [prefix]         Disarm one session (prefix) or ALL (no arg); kills
                          in-flight resumes.
  legs <prefix> <1-9>     Change an armed session's leg budget in place,
                          without disarming.
  status                  Armed sessions, probe task, running resumes, log tail
                          -Json = print one compact JSON object instead (for panel.ps1)
  probe                   Internal: fired by the scheduled probe task (also
                          usable manually to force a tick)
  takeover [prefix]       Sit back down in a relayed session: cd to its cwd and
                          open the interactive TUI on it
  sessions                Latest 10 session transcripts as a JSON array
                          (for panel.ps1's session picker)

Design: at limit-exhaustion every Claude surface is dead, so this script is
pure PowerShell until a probe ping passes. Rejected pings consume nothing.
Each resumed leg runs headless in the session's original cwd (same
conversation, appended). A leg that hits the limit again (or fails) re-arms,
up to per-session maxLegs (default 3) to protect the weekly quota.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'status',
    [Parameter(Position = 1)][string]$Arg,
    [Parameter(Position = 2)][string]$Arg2,
    [string]$Prompt,
    [int]$MaxLegs = 3,
    [switch]$Yes,
    [switch]$Watch,
    [switch]$Json,
    [string]$Effort = '',       # reasoning effort for legs and takeover TUIs. Empty = INHERIT:
                                # read the last assistant record's "effort" field from the armed
                                # session's transcript - it holds the RESOLVED tier (ultracode
                                # sessions record plain xhigh), so any mode inherits cleanly.
                                # Explicit value overrides. A resume left alone does not reliably
                                # keep the tier (one leg observed dropping to LOW live 08-02).
    [string]$Fallback = 'opus'   # fallback when a MODEL-specific weekly cap rejects a leg while
                                # the shared 5h window is open. In practice the top-tier model
                                # carries its own (smaller) weekly bucket while the rest draw on
                                # the shared weekly cap, so ONE hop down usually suffices - if
                                # that is refused too, the shared cap is gone and further hops
                                # cannot help. Comma list = ladder, tried left to right; 'none'
                                # disables (the entry parks instead of degrading).
)

$ErrorActionPreference = 'Stop'
$Root      = $PSScriptRoot
$ArmedDir  = Join-Path $Root 'armed'
$DoneDir   = Join-Path $Root 'done'
$LogPath   = Join-Path $Root 'relay-log.jsonl'
$StatePath = Join-Path $Root 'state.json'      # shared with preheat.ps1
$EmptyMcp  = Join-Path $Root 'mcp-empty.json'
$FirePit   = Join-Path $Root 'firepit'
# stdout must be UTF-8: the panel reads our redirected output as UTF-8, but on
# zh-CN Windows the child-process console codepage defaults to GBK, which turns
# every CJK char into U+FFFD on the way through (mojibake observed live)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
# if this script's ancestry passes through a Claude Code session (the panel is
# often started from one), the environment carries CLAUDE_CODE_CHILD_SESSION=1
# - any claude spawned below would inherit it and SILENTLY STOP SAVING
# TRANSCRIPTS: quota still burns, the conversation record never lands
# (observed live 07-31: a 34-min takeover work session left zero trace).
Remove-Item Env:CLAUDE_CODE_CHILD_SESSION -ErrorAction SilentlyContinue
# CLAUDE_CODE_EFFORT_LEVEL beats the --effort flag, rejects 'ultracode', and
# when set to anything but xhigh it silently keeps ultracode's orchestration
# OFF (docs: model-config). Our legs pin effort explicitly - a stray env var
# must not overrule the tier we sniffed from the user's own window.
Remove-Item Env:CLAUDE_CODE_EFFORT_LEVEL -ErrorAction SilentlyContinue
# third leaked variable on the same wt-penetrating path as the child-session
# marker: a Claude Code tool shell carries NO_COLOR=1 (tool output stays
# plain) - inherited into a takeover TUI it strips every ANSI color from
# claude and the statusline, one flat monochrome wall (observed live 08-02
# and 08-09). TERM=dumb is the same suppression in other harnesses.
Remove-Item Env:NO_COLOR -ErrorAction SilentlyContinue
if ($env:TERM -eq 'dumb') { Remove-Item Env:TERM -ErrorAction SilentlyContinue }

$TaskName  = 'ClaudeRelay-Probe'
# the CLI keeps rephrasing this. Seen live: "resets at 3pm", "your limit will
# reset at 3pm", and (07-30) "You've hit your session limit · resets 1:40pm" -
# the "session limit" noun and the at-less "resets 1:40pm" form each slipped
# past an earlier regex and cost a real relay
# verified corpus 2026-08-04, workflow-audited against code.claude.com/docs/en/errors,
# support.claude.com #12466728 and gh issues #9564 #10333 #5085 #45033:
#   "You've hit your session|weekly|Opus limit · resets <time|weekday|date>"  (current CLI)
#   "Weekly|Opus weekly|5-hour limit reached <../-> resets ..."               (older CLI)
#   "Claude AI usage limit reached|<epoch>"                    (legacy, lives in old transcripts)
#   "You're out of extra usage ..." / "Out of usage credits"   (usage-credit exhaustion)
# 'limit [·∙] resets' is the future-proof net: any "<model> limit · resets" matches
# without hard-coding model names (reset part may be a weekday/date with NO digit).
# Deliberately NOT matched:
#   "...(not your usage limit)"            transient server throttle - lookbehind-excluded
#   "Approaching weekly limit"             non-blocking warning     - lookbehind-excluded
#   "would exceed your account's rate limit"  transient 429: the failure-rearm path retries it
#   "Usage credits required for 1M context"   entitlement gate, not quota - matches nothing here
$LimitRx   = '(?<!not your )usage limit|session limit|(?<!approaching )weekly limit|limit reached|limit [·∙] resets|resets? at|resets? \d|out of extra usage|out of .{0,20}credits'
$DefaultPrompt = 'Continue the unfinished task from the previous instructions in this conversation and work it to FULL completion: if a background process, test or download is still running, wait for it and report its result - do not stop while anything is pending. If everything was already completed, reply exactly DONE.'
$WatchIdleMinutes = 45
$LegTimeoutMs     = 14400000   # 4h per resumed leg

foreach ($d in @($ArmedDir, $DoneDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force -ErrorAction SilentlyContinue | Out-Null }
}
# one-time migration from the single-relay layout
$legacyLast = Join-Path $Root 'last-relay.json'
if (Test-Path $legacyLast) {
    try {
        $l = Get-Content $legacyLast -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($l.session) { Copy-Item $legacyLast (Join-Path $DoneDir ($l.session + '.json')) -Force }
    } catch { }
    Remove-Item $legacyLast -ErrorAction SilentlyContinue
}
foreach ($legacy in @('armed.json', 'relay-prompt.txt', 'relay-running.json')) {
    Remove-Item (Join-Path $Root $legacy) -ErrorAction SilentlyContinue
}

function Write-Log($obj) {
    $obj.ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    try {
        # rotation: keep the journal bounded (runtime telemetry, lossy by design)
        if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 2MB)) {
            $keep = Get-Content $LogPath -Tail 1000 -Encoding UTF8
            Set-Content -Path $LogPath -Value $keep -Encoding UTF8
        }
    } catch { }
    ($obj | ConvertTo-Json -Compress -Depth 5) | Add-Content -Path $LogPath -Encoding UTF8
}

function Send-Toast($text) {
    try {
        if (Get-Module -ListAvailable -Name BurntToast) {
            Import-Module BurntToast -ErrorAction Stop
            New-BurntToastNotification -Text 'claude-relay', $text | Out-Null
        }
    } catch { }
}

function Resolve-ClaudeExe {
    param([switch]$NoCache)
    if (-not $NoCache -and (Test-Path $StatePath)) {
        try {
            $state = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($state.claude -and (Test-Path $state.claude)) { return $state.claude }
        } catch { }
    }
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($cmd) {
        $src = $cmd.Source
        if ($src -like '*.ps1') {
            $sib = [System.IO.Path]::ChangeExtension($src, '.cmd')
            if (Test-Path $sib) { return $sib }
        }
        return $src
    }
    foreach ($cand in @("$env:APPDATA\npm\claude.cmd", "$env:USERPROFILE\.local\bin\claude.exe")) {
        if (Test-Path $cand) { return $cand }
    }
    throw 'claude CLI not found'
}

function Resolve-HostShell {
    $p = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($p) { return $p.Source }
    (Get-Command powershell).Source
}

function Get-Proxy {
    # empty/missing config proxy -> $null (callers must skip setting HTTPS_PROXY/HTTP_PROXY)
    $cfg = Join-Path $Root 'schedule.json'
    if (Test-Path $cfg) {
        try {
            $c = Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($c.proxy) { return $c.proxy }
        } catch { }
    }
    $null
}

# ---------- session transcript helpers ----------

function Get-SessionFiles {
    $projRoot = Join-Path $env:USERPROFILE '.claude\projects'
    Get-ChildItem -Path (Join-Path $projRoot '*\*.jsonl') -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' } |
        Sort-Object LastWriteTime -Descending
}

function Get-SessionFileById($id) {
    Get-ChildItem -Path (Join-Path $env:USERPROFILE ('.claude\projects\*\{0}.jsonl' -f $id)) -ErrorAction SilentlyContinue |
        Select-Object -First 1
}

function Get-TailLines($file, [int]$maxBytes = 2097152) {
    # bounded tail read: transcript lines can be multi-MB (tool results), and
    # Get-Content -Tail must decode EVERY line just to count them - on a 40MB
    # transcript that burned CPU for tens of seconds per arm click AND came
    # back empty, leaving the armed entry with no cwd at all (observed live)
    try {
        $fs = [System.IO.File]::Open($file, 'Open', 'Read', 'ReadWrite')
        try {
            $len  = $fs.Length
            $take = [int][Math]::Min([int64]$maxBytes, $len)
            $null = $fs.Seek(-$take, [System.IO.SeekOrigin]::End)
            $buf  = New-Object byte[] $take
            $read = $fs.Read($buf, 0, $take)
            $txt  = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally { $fs.Close() }
        $lines = @($txt -split "`n")
        if ($lines.Count -gt 1 -and $len -gt $take) { $lines = @($lines[1..($lines.Count - 1)]) }
        return ,$lines
    } catch { return ,@() }
}

function Get-SessionCwd($file) {
    # The cwd matters for exactly one reason: `claude --resume` looks a session
    # up in the bucket derived from the CURRENT directory (every non-alphanumeric
    # char becomes '-'). A session that cd'd mid-way carries a LAST cwd whose
    # bucket differs from where its transcript lives - resuming there fails with
    # "No conversation found" (observed live). So every candidate is verified
    # against the transcript's own bucket dir name; only a verified cwd can
    # actually resume.
    $bucket = Split-Path (Split-Path $file -Parent) -Leaf
    $cands  = New-Object System.Collections.Generic.List[string]
    $tail = Get-TailLines $file 262144
    for ($i = $tail.Count - 1; $i -ge 0; $i--) {
        if ($tail[$i] -match '"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"') {
            $c = $Matches[1] -replace '\\\\', '\'
            if (-not $cands.Contains($c)) { $cands.Add($c) }
        }
    }
    try {
        foreach ($line in @(Get-Content $file -TotalCount 25 -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if ($line -match '"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"') {
                $c = $Matches[1] -replace '\\\\', '\'
                if (-not $cands.Contains($c)) { $cands.Add($c) }
            }
        }
    } catch { }
    foreach ($c in $cands) {
        if (($c -replace '[^A-Za-z0-9]', '-') -eq $bucket) { return $c }
    }
    if ($cands.Count -gt 0) { return $cands[0] }
    $null
}

function Get-SessionSnippet($file) {
    # newest real user message wins - that's what a human recognizes a
    # conversation by. Meta lines (slash-command dumps, caveats, tool
    # results) are skipped; they're only a last resort.
    $fallback = ''
    try {
        $tail = Get-TailLines $file
        for ($i = $tail.Count - 1; $i -ge 0; $i--) {
            $line = $tail[$i]
            if ($line -notmatch '"type"\s*:\s*"user"') { continue }
            if ($line -match '"tool_result"') { continue }
            foreach ($m in [regex]::Matches($line, '"(?:text|content)"\s*:\s*"((?:[^"\\]|\\.){1,70})')) {
                $t = $m.Groups[1].Value -replace '\\n', ' '
                if ($t -match '^\s*(<|#|\[|Caveat|Base directory)') {
                    if (-not $fallback) { $fallback = $t }
                    continue
                }
                return $t
            }
        }
        foreach ($line in @(Get-Content $file -TotalCount 120 -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if ($line -match '"tool_result"') { continue }
            if ($line -notmatch '"type"\s*:\s*"user"') { continue }
            foreach ($m in [regex]::Matches($line, '"(?:text|content)"\s*:\s*"((?:[^"\\]|\\.){1,70})')) {
                $t = $m.Groups[1].Value -replace '\\n', ' '
                if ($t -match '^\s*(<|#|\[|Caveat|Base directory)') {
                    if (-not $fallback) { $fallback = $t }
                    continue
                }
                return $t
            }
        }
    } catch { }
    $fallback
}

function Get-SessionEffort($file) {
    # every assistant record carries the RESOLVED reasoning tier ("effort":
    # "xhigh") - /effort ultracode also lands as plain xhigh (orchestration is
    # session behavior, not a tier), so inheriting this field sidesteps the
    # "can a headless leg run ultracode" question entirely. Last record wins
    # (mid-session /effort changes). Cheap string prefilter, then the last few
    # candidates are JSON-validated backwards: a user/tool_result line quoting
    # an assistant record stores it \"-escaped so the prefilter already skips
    # it, but this tool's own transcripts are FULL of effort strings - belt
    # and braces.
    # ultracode is invisible in assistant records (they log the resolved tier,
    # xhigh) - but the /effort toggle itself lands as a user record whose
    # content STRING starts with "<local-command-stdout>Set effort level to
    # ultracode". --effort ultracode is accepted at launch (verified live on
    # 2.1.221: bogus values warn loudly and fall back, ultracode is taken
    # silently), so returning 'ultracode' restores the FULL mode - parallel
    # orchestration included - on legs and takeover alike.
    $cands = New-Object System.Collections.Generic.List[string]
    $ultraCands = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($line in [System.IO.File]::ReadLines($file)) {
            if ($line -match '"effort"\s*:\s*"(?:low|medium|high|xhigh|max)"' -and
                $line -match '"type"\s*:\s*"assistant"') {
                [void]$cands.Add($line)
                if ($cands.Count -gt 24) { $cands.RemoveAt(0) }
            }
            if ($line -match 'local-command-stdout>Set effort level to ' -and
                $line -match '"type"\s*:\s*"user"') {
                [void]$ultraCands.Add($line)
                if ($ultraCands.Count -gt 24) { $ultraCands.RemoveAt(0) }
            }
        }
    } catch { }
    # the /effort toggle wins only when its LAST real occurrence says ultracode
    # (assistant records then read xhigh - consistent). A later /effort back to
    # a plain tier hits the same last-wins scan and falls through to the
    # assistant-record tier below. Content must be a plain STRING record -
    # tool results quoting the phrase store content as an array and are skipped.
    for ($i = $ultraCands.Count - 1; $i -ge 0; $i--) {
        try {
            $j = $ultraCands[$i] | ConvertFrom-Json
            if ($j.type -ne 'user' -or -not $j.message) { continue }
            $c = $j.message.content
            if ($c -isnot [string]) { continue }
            $mm = [regex]::Matches($c, 'local-command-stdout>Set effort level to (ultracode|low|medium|high|xhigh|max)')
            if ($mm.Count -gt 0) {
                if ($mm[$mm.Count - 1].Groups[1].Value -eq 'ultracode') { return 'ultracode' }
                break   # last real /effort was a plain tier - assistant records carry it
            }
        } catch { }
    }
    for ($i = $cands.Count - 1; $i -ge 0; $i--) {
        try {
            $j = $cands[$i] | ConvertFrom-Json
            if ($j.type -eq 'assistant' -and $j.PSObject.Properties['effort'] -and
                ($j.effort -match '^(low|medium|high|xhigh|max)$')) { return [string]$j.effort }
        } catch { }
    }
    try {
        # no per-turn field (older CLI): the session ran at the account default
        $st = Get-Content (Join-Path $HOME '.claude\settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($st.PSObject.Properties['effortLevel'] -and ($st.effortLevel -match '^(low|medium|high|xhigh|max)$')) { return [string]$st.effortLevel }
    } catch { }
    'high'
}

function Get-TranscriptActivity($file) {
    # Newest REAL turn in a transcript, as local time. Two traps this avoids,
    # both observed live:
    #  1. file mtime lies - local tools (indexers, backups) bump it without
    #     appending a single byte, so a dead task looks alive forever and the
    #     sentry never stands down
    #  2. not every record is an API turn - Claude Code appends attachment /
    #     away_summary / turn_duration bookkeeping to an OPEN-BUT-IDLE session,
    #     which would keep resetting the idle clock on a task that is finished
    # Only user/assistant records count as a turn.
    try {
        $fs = [System.IO.File]::Open($file, 'Open', 'Read', 'ReadWrite')
        try {
            $take = [int][Math]::Min(2097152, $fs.Length)
            $null = $fs.Seek(-$take, [System.IO.SeekOrigin]::End)
            $buf  = New-Object byte[] $take
            $read = $fs.Read($buf, 0, $take)
            $txt  = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally { $fs.Close() }
        $best = $null
        foreach ($line in ($txt -split "`n")) {
            if ($line -notmatch '"type"\s*:\s*"(assistant|user)"') { continue }
            if ($line -notmatch '"timestamp"\s*:\s*"([^"]+)"') { continue }
            $v = $Matches[1]
            if ((-not $best) -or ($v -gt $best)) { $best = $v }   # ISO-8601 UTC sorts lexically
        }
        if ($best) { return ([datetimeoffset]::Parse($best)).LocalDateTime }
    } catch { }
    $null
}

function Get-SessionTailState($file) {
    # 'finished' = ends with a completed assistant text reply
    # 'limit'    = ends with the limit-kill record
    # 'stalled'  = ends mid-flight | 'unknown' = unreadable (treat as stalled)
    # The limit kill writes an ASSISTANT record whose text reads like a normal
    # completed reply ("You've hit your session limit · resets 1:40pm") - only
    # its structured fields give it away, and misreading it as 'finished' made
    # the sentry stand down on a limit-killed task (observed live 07-30). Only
    # those structured fields may flip the verdict: transcripts around this
    # tool are full of limit words in ordinary prose.
    # The verdict comes from the MAIN chain only: subagent records (isSidechain)
    # land in the same file, and parallel agents draining after a kill can bury
    # the kill record under dozens of their own assistant lines - reading one of
    # those as the tail flipped a limit-killed task to 'finished'. Record types
    # are an ALLOW-LIST (user/assistant); anything else is bookkeeping and a
    # future new record type can never masquerade as a turn.
    $all = Get-TailLines $file 262144
    if ($all.Count -eq 0) { return 'unknown' }
    # 200 lines, not 40: sidechain turns + hook/attachment bookkeeping pile up after a kill
    $tail = @($all | Select-Object -Last 200)
    for ($i = $tail.Count - 1; $i -ge 0; $i--) {
        $line = $tail[$i]
        if ($line -match '"isSidechain"\s*:\s*true') { continue }   # subagent turn, not the conversation
        if ($line -match '"type"\s*:\s*"assistant"') {
            if (($line -match '"isApiErrorMessage"\s*:\s*true') -or
                ($line -match '"error"\s*:\s*"rate_limit"')) { return 'limit' }
            if ($line -match '"type"\s*:\s*"tool_use"') { return 'stalled' }
            return 'finished'
        }
        if ($line -match '"type"\s*:\s*"user"') { return 'stalled' }
    }
    'unknown'
}

function Resolve-FireGate($e) {
    # THE eligibility rule, applied at the moment of fire - not at arm time,
    # because hours pass in between and anyone may have driven the conversation
    # since: the returning human, a finished leg whose bookkeeping crashed, or
    # the CLI's own limit-picker auto-continue in the original window.
    #   fire     -> tail is still the kill record (all-clear), or the task was
    #               cut off mid-flight and is idle (the watch-stall path)
    #   yield    -> a real turn landed minutes ago: someone is driving
    #   finished -> ends with a completed reply that is NOT the kill: it was
    #               finished without us - never fire into it
    #   missing  -> transcript is gone (cleaned up?): nothing left to resume
    #   skip     -> transcript unreadable right now: fail safe, retry next tick
    $sf = Get-SessionFileById $e.session
    if (-not $sf) { return 'missing' }
    $sty = Get-SessionTailState $sf.FullName
    if ($sty -eq 'limit') { return 'fire' }
    $acty = Get-TranscriptActivity $sf.FullName
    if ($acty -and (((Get-Date) - $acty).TotalMinutes -lt 10)) { return 'yield' }
    if ($sty -eq 'finished') { return 'finished' }
    if ($sty -eq 'stalled') { return 'fire' }
    'skip'
}

# ---------- armed-entry state layer (one file per session) ----------

function Get-ArmedAll {
    # *.json also matches <session>.lock.json - a lock must never be parsed
    # as an armed entry (it would surface as a phantom session-less task)
    @(Get-ChildItem -Path (Join-Path $ArmedDir '*.json') -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*.lock.json' } | ForEach-Object {
        try { Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
    }) | Where-Object { $_ }
}

function Save-Entry($e) {
    $e | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $ArmedDir ($e.session + '.json')) -Encoding UTF8
}

function Remove-Entry($session) {
    Remove-Item (Join-Path $ArmedDir ($session + '.json')) -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $ArmedDir ($session + '.prompt.txt')) -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $ArmedDir ($session + '.lock.json')) -ErrorAction SilentlyContinue
}

function Complete-Entry($e, $ok, $out, $summary = '') {
    # summary = the last assistant reply's head, so "what did that leg do all
    # night" is answerable from the panel without hunting for the raw log
    @{ session = $e.session; cwd = $e.cwd; ok = $ok; out = $out; summary = $summary; finishedAt = (Get-Date).ToString('s') } |
        ConvertTo-Json -Compress | Set-Content -Path (Join-Path $DoneDir ($e.session + '.json')) -Encoding UTF8
    Remove-Entry $e.session
}

function Test-LegInFlight($session) {
    # an alive lock pid = OUR leg is still writing this conversation. The tick
    # must skip such entries entirely: relaunching would double-drive, and the
    # yield guard would misread the leg's own writes as a human taking over
    # (observed live 08-02: both in-flight entries got flipped back to watch).
    # A lock whose pid is dead is stale - clear it so the session can relaunch.
    $lockPath = Join-Path $ArmedDir ($session + '.lock.json')
    if (-not (Test-Path $lockPath)) { return $false }
    try {
        $lock = Get-Content $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($lock.pid -and (Get-Process -Id $lock.pid -ErrorAction SilentlyContinue)) { return $true }
    } catch { }
    Remove-Item $lockPath -ErrorAction SilentlyContinue
    $false
}

function Register-ProbeTask {
    # DelayMinutes: 2 for a fresh arm (probe soon); 10 for the per-tick horizon
    # renewal - renewing with 2 would hijack the 10-min period down to 2 min
    # (observed live: fan-roaring claude spawn every ~2 min)
    param([int]$DelayMinutes = 2)
    # via run-hidden.vbs: a console action flashes a cmd window EVERY 10 min
    # while armed (observed live - the popups the sentry was leaking)
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' `
        -Argument ('//B //Nologo "{0}" "{1}" "-NoProfile" "-ExecutionPolicy" "Bypass" "-File" "{2}" "probe"' -f `
            (Join-Path $Root 'run-hidden.vbs'), (Resolve-HostShell), (Join-Path $Root 'relay.ps1'))
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($DelayMinutes) `
        -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Hours 24)
    $settings = New-ScheduledTaskSettingsSet -WakeToRun -ExecutionTimeLimit (New-TimeSpan -Hours 5) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
}

function Unregister-ProbeTask {
    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
}

# ---------- ping ----------

function Invoke-ClaudePing {
    # tri-state: 'open' | 'limit' | 'error' -- rejected pings consume nothing
    $claude = Resolve-ClaudeExe
    $proxy = Get-Proxy
    if ($proxy) { $env:HTTPS_PROXY = $proxy; $env:HTTP_PROXY = $proxy }
    if (-not (Test-Path $FirePit)) { New-Item -ItemType Directory -Path $FirePit -Force -ErrorAction SilentlyContinue | Out-Null }
    $outFile = Join-Path $Root ('.probe-out-{0}.tmp' -f $PID)
    $errFile = Join-Path $Root ('.probe-err-{0}.tmp' -f $PID)
    try {
        $pingArgs = '-p "hi" --model haiku --no-session-persistence --strict-mcp-config --mcp-config "{0}" --output-format json' -f $EmptyMcp
        $p = Start-Process -FilePath $claude -ArgumentList $pingArgs -WorkingDirectory $FirePit `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -NoNewWindow
        if (-not $p.WaitForExit(240000)) { try { $p.Kill() } catch { }; return 'error' }
        $stdout = ''; if (Test-Path $outFile) { $stdout = Get-Content $outFile -Raw }
        $stderrTxt = ''; if (Test-Path $errFile) { $stderrTxt = Get-Content $errFile -Raw }
        # the CLI keeps rephrasing rejections ("You've hit your session limit ·
        # resets 1:40pm" matched neither) - a mislabeled 'error' behaves the
        # same as 'limit' by luck, but the journal lied for hours (seen 08-02)
        if (($stdout + ' ' + $stderrTxt) -match 'Claude AI usage limit reached') { return 'limit' }
        if (($stdout + ' ' + $stderrTxt) -match $LimitRx) { return 'limit' }
        if ($p.ExitCode -eq 0 -and $stdout) { return 'open' }
        return 'error'
    } catch {
        return 'error'
    } finally {
        Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
    }
}

# ---------- commands ----------

function Invoke-Arm {
    $files = @(Get-SessionFiles)
    if (-not $files) { throw 'no session transcripts found under ~\.claude\projects' }
    $target = $null
    if ($Arg) {
        $target = $files | Where-Object { $_.BaseName -like "$Arg*" } | Select-Object -First 1
        if (-not $target) { throw "no session matching id prefix '$Arg'" }
    } elseif ($Yes) {
        $target = $files[0]
    } else {
        $top = @($files | Select-Object -First 3)
        Write-Host ''
        for ($i = 0; $i -lt $top.Count; $i++) {
            $cwd0 = Get-SessionCwd $top[$i].FullName
            $snip = Get-SessionSnippet $top[$i].FullName
            Write-Host ('[{0}] {1}  {2}...' -f ($i + 1), $top[$i].LastWriteTime.ToString('MM-dd HH:mm:ss'), $top[$i].BaseName.Substring(0, 8))
            Write-Host ('    cwd: {0}' -f $cwd0)
            if ($snip) { Write-Host ('    1st: {0}' -f $snip) }
        }
        $pick = Read-Host 'which session to relay? [1]'
        if (-not $pick) { $pick = '1' }
        $idx = [int]$pick - 1
        if ($idx -lt 0 -or $idx -ge $top.Count) { throw "invalid pick '$pick'" }
        $target = $top[$idx]
    }
    if (Test-Path (Join-Path $ArmedDir ($target.BaseName + '.json'))) {
        throw ('session {0} is already armed - "relay status" to inspect, "relay disarm {1}" to reset' -f $target.BaseName.Substring(0, 8), $target.BaseName.Substring(0, 8))
    }
    $cwd = Get-SessionCwd $target.FullName
    if (-not $cwd) { $cwd = (Get-Location).Path }
    $p = $DefaultPrompt
    if ($Prompt) { $p = $Prompt }
    # prompt reaches the resume via stdin file - immune to argv quoting issues
    Set-Content -Path (Join-Path $ArmedDir ($target.BaseName + '.prompt.txt')) -Value $p -Encoding UTF8
    $mode = 'wait'
    if ($Watch) { $mode = 'watch' }
    $eff = $Effort
    if (-not $eff) { $eff = Get-SessionEffort $target.FullName }   # inherit the window's tier
    Save-Entry @{
        session = $target.BaseName
        cwd     = $cwd
        armedAt = (Get-Date).ToString('s')
        legs    = 0
        maxLegs = $MaxLegs
        mode    = $mode
        fallback = $Fallback
        effort  = $eff
        model   = ''
    }
    Register-ProbeTask   # -Force refresh: also renews the 24h horizon
    Write-Log @{ ev = 'arm'; mode = $mode; session = $target.BaseName; cwd = $cwd }
    $count = @(Get-ArmedAll).Count
    Write-Host ''
    if ($Watch) { Write-Host '=== relay WATCHING - you can walk away ===' }
    else        { Write-Host '=== relay armed - you can walk away ===' }
    Write-Host ('session   : {0}' -f $target.BaseName)
    Write-Host ('cwd       : {0}' -f $cwd)
    Write-Host ('last seen : {0}' -f $target.LastWriteTime)
    Write-Host ('probing   : every 10 min from now (+2 min), horizon 24h')
    if ($Watch) {
        Write-Host 'trigger   : limit trips -> auto-switch to wait-and-resume'
        Write-Host ('standdown : idle {0} min + transcript ends with a completed reply' -f $WatchIdleMinutes)
    }
    Write-Host ('max legs  : {0}' -f $MaxLegs)
    Write-Host ('armed now : {0} session(s) on this relay' -f $count)
}

function Start-ResumeLeg($e) {
    # spawn one headless resume; returns a record for the wait/verdict phase
    $claude = Resolve-ClaudeExe
    $stamp   = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $sid8    = $e.session.Substring(0, 8)
    $outFile = Join-Path $Root ('relay-out-{0}-{1}.log' -f $sid8, $stamp)
    $rawFile = Join-Path $Root ('relay-raw-{0}-{1}.json' -f $sid8, $stamp)
    $errFile = Join-Path $Root ('relay-err-{0}-{1}.log' -f $sid8, $stamp)
    $workDir = $e.cwd
    if (-not (Test-Path $workDir)) { $workDir = $Root }
    $pf = Join-Path $ArmedDir ($e.session + '.prompt.txt')
    if (-not (Test-Path $pf)) { Set-Content -Path $pf -Value $DefaultPrompt -Encoding UTF8 }
    # snapshot the newest real turn BEFORE launching: the verdict phase compares
    # against it to prove the leg actually moved the conversation
    $preAct = $null
    $sfL = Get-SessionFileById $e.session
    if ($sfL) { $preAct = Get-TranscriptActivity $sfL.FullName }
    # a leg MUST persist its turns - the top-of-script marker scrub is the
    # primary defense, this is the belt
    $env:CLAUDE_CODE_FORCE_SESSION_PERSISTENCE = '1'
    # print mode only waits ~10 min for background workflows by default before
    # wrapping up - an ultracode leg's orchestration would get clipped. Align
    # the ceiling with our own 4h leg timeout (harmless for plain legs).
    $env:CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS = '14400000'
    $rArgs = '--resume {0} -p --dangerously-skip-permissions --output-format json' -f $e.session
    if ($e.PSObject.Properties['model'] -and $e.model) { $rArgs = $rArgs + ' --model ' + $e.model }
    $legEffort = 'high'
    if ($e.PSObject.Properties['effort'] -and $e.effort) { $legEffort = $e.effort }
    $rArgs = $rArgs + ' --effort ' + $legEffort
    $p = Start-Process -FilePath $claude -ArgumentList $rArgs -WorkingDirectory $workDir `
        -RedirectStandardInput $pf -RedirectStandardOutput $rawFile -RedirectStandardError $errFile `
        -PassThru -NoNewWindow
    @{ pid = $p.Id; leg = $e.legs; startedAt = (Get-Date).ToString('s'); out = $rawFile } |
        ConvertTo-Json -Compress | Set-Content -Path (Join-Path $ArmedDir ($e.session + '.lock.json')) -Encoding UTF8
    @{ entry = $e; proc = $p; raw = $rawFile; err = $errFile; out = $outFile; started = Get-Date; preAct = $preAct }
}

function Resolve-LegVerdict($rec) {
    # wait for one leg and judge it from STRUCTURED signals only - never grep
    # the assistant's own prose for limit words
    $e = $rec.entry
    $ok = $false; $hitLimit = $false; $errMsg = $null; $resultText = ''
    try {
        $remaining = $LegTimeoutMs - [int]((Get-Date) - $rec.started).TotalMilliseconds
        if ($remaining -lt 1000) { $remaining = 1000 }
        if (-not $rec.proc.WaitForExit($remaining)) {
            try { & taskkill /T /F /PID $rec.proc.Id 2>$null | Out-Null } catch { }
            throw 'resume timeout after 4h'
        }
        $raw = ''; if (Test-Path $rec.raw) { $raw = Get-Content $rec.raw -Raw -ErrorAction SilentlyContinue }
        $stderrTxt = ''; if (Test-Path $rec.err) { $stderrTxt = Get-Content $rec.err -Raw -ErrorAction SilentlyContinue }
        $j = $null
        if ($raw) { try { $j = $raw | ConvertFrom-Json } catch { } }
        if ($j) {
            $resultText = [string]$j.result
            $isErr = $false
            if ($j.PSObject.Properties['is_error']) { $isErr = [bool]$j.is_error }
            $ok = ($rec.proc.ExitCode -eq 0 -and -not $isErr)
            $hitLimit = ($isErr -and ($resultText -match $LimitRx)) -or
                        ($resultText -match '^\s*Claude AI usage limit reached')
        } else {
            $hitLimit = (($raw + ' ' + $stderrTxt) -match 'Claude AI usage limit reached')
        }
        if ($stderrTxt -and ($stderrTxt -match $LimitRx)) { $hitLimit = $true }
        if ($ok) {
            # trust-but-verify: exit 0 plus a result string is not proof the
            # conversation moved - a resume can "succeed" while writing nothing
            # (bucket mismatch, silent persistence failure; tools in the wild
            # have shipped RESUMED banners over exactly this). Ground truth is
            # the transcript: a real turn newer than launch must exist.
            $sfV = Get-SessionFileById $e.session
            $postAct = $null
            if ($sfV) { $postAct = Get-TranscriptActivity $sfV.FullName }
            if (-not ($postAct -and ((-not $rec.preAct) -or ($postAct -gt $rec.preAct)))) {
                $ok = $false
                $errMsg = 'leg exited ok but the transcript did not move - treated as failure'
            }
        }
        if ($resultText) { Set-Content -Path $rec.out -Value $resultText -Encoding UTF8 }
        elseif ($raw)    { Set-Content -Path $rec.out -Value $raw -Encoding UTF8 }
    } catch {
        $errMsg = $_.Exception.Message
    } finally {
        Remove-Item (Join-Path $ArmedDir ($e.session + '.lock.json')) -ErrorAction SilentlyContinue
    }
    $entry = @{ ev = 'resume'; session = $e.session; leg = $e.legs; ok = $ok; hitLimitAgain = $hitLimit; out = $rec.out }
    if ($errMsg) { $entry.err = $errMsg }
    Write-Log $entry

    # honor a disarm issued while this leg was running
    $efPath = Join-Path $ArmedDir ($e.session + '.json')
    if (-not (Test-Path $efPath)) { return }
    # re-read the entry: legs run for hours, and maxLegs may have been changed
    # mid-flight (relay legs / the panel dropdown) - saving the stale in-memory
    # copy below would silently undo that change
    try {
        $disk = Get-Content $efPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($disk -and $disk.session) { $e = $disk }
    } catch { }

    # MODEL-cap discriminator: the shared 5h window was probed open seconds ago,
    # so a limit rejection that kills the leg within 3 minutes cannot be the 5h
    # window - it is the session model's own weekly cap (the top-tier bucket).
    # Waiting 10 more minutes will not refill that bucket; fall back to another
    # model on the SAME conversation instead.
    $durSec = ((Get-Date) - $rec.started).TotalSeconds
    if ($hitLimit -and ($durSec -lt 180) -and ([int]$e.legs -lt [int]$e.maxLegs)) {
        $ladder = @()
        if ($e.PSObject.Properties['fallback'] -and $e.fallback -and ($e.fallback -ne 'none')) {
            $ladder = @(($e.fallback -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        $cur = ''
        if ($e.PSObject.Properties['model'] -and $e.model) { $cur = $e.model }
        $next = ''
        if ($ladder.Count -gt 0) {
            if (-not $cur) { $next = $ladder[0] }
            else {
                $ix = [array]::IndexOf($ladder, $cur)
                if (($ix -ge 0) -and ($ix -lt ($ladder.Count - 1))) { $next = $ladder[$ix + 1] }
            }
        }
        if ($next) {
            $e | Add-Member -NotePropertyName model -NotePropertyValue $next -Force
            Save-Entry $e
            Write-Log @{ ev = 'model-fallback'; session = $e.session; to = $next; legSec = [int]$durSec }
            Send-Toast ('{0}: model weekly cap suspected - next leg falls back to {1}' -f $e.session.Substring(0, 8), $next)
            return   # entry stays armed; next probe tick relaunches on the fallback model
        }
        # no hop left: the user chose model purity (-Fallback none) or the
        # ladder is exhausted. Re-arming would relaunch the same dead model
        # every tick and burn the remaining legs on nothing - park the entry
        # untouched and let the human decide (takeover / disarm / re-arm
        # after the weekly reset).
        $e | Add-Member -NotePropertyName mode -NotePropertyValue 'parked' -Force
        Save-Entry $e
        Write-Log @{ ev = 'model-cap-parked'; session = $e.session; legSec = [int]$durSec }
        Send-Toast ('{0}: model weekly cap hit, no fallback configured - parked, task left untouched' -f $e.session.Substring(0, 8))
        return
    }

    if (((-not $ok) -or $hitLimit) -and ([int]$e.legs -lt [int]$e.maxLegs)) {
        $reason = 'failure'; if ($hitLimit) { $reason = 'limit' }
        Write-Log @{ ev = 'rearm'; session = $e.session; leg = $e.legs; reason = $reason }
        Send-Toast ('{0}: leg {1} ended ({2}) - re-armed' -f $e.session.Substring(0, 8), $e.legs, $reason)
        return   # entry stays armed; next probe tick handles it
    }
    $summ = ''
    if ($resultText) {
        $summ = $resultText.Trim()
        if ($summ.Length -gt 200) { $summ = $summ.Substring(0, 200) }
    }
    Complete-Entry $e $ok $rec.out $summ
    if ($ok) { Send-Toast ('{0}: relay done after leg {1} - "relay takeover" to pick up' -f $e.session.Substring(0, 8), $e.legs) }
    else     { Send-Toast ('{0}: relay stopped after leg {1}/{2} without success' -f $e.session.Substring(0, 8), $e.legs, $e.maxLegs) }
}

function Invoke-Probe {
    $entries = @(Get-ArmedAll)
    if (-not $entries) { Unregister-ProbeTask; return }

    # housekeeping: leg artifacts age out after 14 days (guarded, never blocks the tick)
    try {
        Get-ChildItem -Path (Join-Path $Root 'relay-out-*.log'), (Join-Path $Root 'relay-err-*.log'), (Join-Path $Root 'relay-raw-*.json') -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }

    # a ping is not free in PHASE: it is a real message, so when no window is
    # active it ANCHORS a new one - stealing the phase a scheduled preheat was
    # aiming for. Watch mode never needs one: a stall is visible in the
    # transcript alone. Only wait entries (which are about to resume, and must
    # know whether the window is open) ping.
    $needPing = $false
    foreach ($e in $entries) {
        $m = 'wait'
        if ($e.PSObject.Properties['mode'] -and $e.mode) { $m = $e.mode }
        if ($m -ne 'watch' -and $m -ne 'parked') { $needPing = $true; break }
    }
    $ping = 'skip'
    if ($needPing) { $ping = Invoke-ClaudePing }
    $ready = @()

    foreach ($e in $entries) {
        $mode = 'wait'
        if ($e.PSObject.Properties['mode'] -and $e.mode) { $mode = $e.mode }
        if ($mode -eq 'parked') {
            # model weekly cap hit and no fallback hop allowed: frozen until a
            # human decides (takeover / disarm / re-arm after the weekly
            # reset). No pings, no legs, no quota burned while parked.
            Write-Log @{ ev = 'parked'; session = $e.session }
            continue
        }
        if ($mode -eq 'watch') {
            $sf = Get-SessionFileById $e.session
            # limit kill FIRST, before any idle math: the kill record is
            # unambiguous the moment it lands, and judging by idle+ending alone
            # made the sentry mistake a limit-killed task for one that finished
            # naturally and stand down (observed live 07-30 - the relay never
            # fired and the user ended up resuming by hand)
            $tailState = 'unknown'
            if ($sf) { $tailState = Get-SessionTailState $sf.FullName }
            if ($tailState -eq 'limit') {
                $e | Add-Member -NotePropertyName mode -NotePropertyValue 'wait' -Force
                Save-Entry $e
                Write-Log @{ ev = 'watch-limit-detected'; session = $e.session }
                Send-Toast ('{0}: limit hit - switching to wait-and-resume' -f $e.session.Substring(0, 8))
                if ($ping -eq 'open') { $ready += , $e }
                continue
            }
            $act = $null
            if ($sf) {
                $act = Get-TranscriptActivity $sf.FullName
                if (-not $act) { $act = $sf.LastWriteTime }   # unreadable tail: fall back to mtime
            }
            if (-not ($act -and (((Get-Date) - $act).TotalMinutes -gt $WatchIdleMinutes))) {
                Write-Log @{ ev = 'watch'; session = $e.session; ping = $ping }
                continue   # task alive (or too fresh to judge)
            }
            if ($tailState -eq 'finished') {
                Complete-Entry $e $true ''
                Write-Log @{ ev = 'watch-standdown'; session = $e.session; reason = 'idle and transcript ends with completed reply' }
                Send-Toast ('{0}: watch ended - task finished without hitting the limit' -f $e.session.Substring(0, 8))
                continue
            }
            # idle + mid-flight tail: the task was cut off. Flip to wait mode; if
            # this tick already pinged (some other entry needed it) and the window
            # is open, resume now - otherwise the next tick pings and resumes.
            $e | Add-Member -NotePropertyName mode -NotePropertyValue 'wait' -Force
            Save-Entry $e
            Write-Log @{ ev = 'watch-stall-detected'; session = $e.session; tail = $tailState }
            if ($ping -eq 'open') { $ready += , $e }
            continue
        }
        # wait mode
        if (Test-LegInFlight $e.session) {
            Write-Log @{ ev = 'leg-inflight'; session = $e.session }
            continue
        }
        if ($ping -eq 'open') { $ready += , $e }
    }

    if ($ping -ne 'open' -or -not $ready) {
        Write-Log @{ ev = 'probe'; ping = $ping; armed = @(Get-ArmedAll).Count }
        if (@(Get-ArmedAll).Count -gt 0) { Register-ProbeTask -DelayMinutes 10 }   # renew horizon, keep 10-min period
        else { Unregister-ProbeTask }
        return
    }

    # window is open: launch ALL ready sessions in parallel, then judge each
    $proxy = Get-Proxy
    if ($proxy) { $env:HTTPS_PROXY = $proxy; $env:HTTP_PROXY = $proxy }
    $records = @()
    foreach ($e in $ready) {
        # fire-time gate: re-judge the transcript NOW, not at arm time. A leg
        # into an occupied conversation double-writes it (last time this raced,
        # the user WAS the relay and got a useless double-driver); a leg into a
        # finished one burns quota appending noise to completed work.
        $gate = Resolve-FireGate $e
        if ($gate -eq 'yield') {
            $e | Add-Member -NotePropertyName mode -NotePropertyValue 'watch' -Force
            Save-Entry $e
            Write-Log @{ ev = 'leg-yield'; session = $e.session; to = 'watch' }
            Send-Toast ('{0}: conversation is live again - watching instead of resuming' -f $e.session.Substring(0, 8))
            continue
        }
        if ($gate -eq 'finished') {
            Complete-Entry $e $true ''
            Write-Log @{ ev = 'fire-skip'; session = $e.session; reason = 'finished-by-others' }
            Send-Toast ('{0}: conversation was already finished - standing down' -f $e.session.Substring(0, 8))
            continue
        }
        if ($gate -eq 'missing') {
            Complete-Entry $e $false ''
            Write-Log @{ ev = 'fire-skip'; session = $e.session; reason = 'transcript-missing' }
            Send-Toast ('{0}: transcript disappeared - relay cancelled' -f $e.session.Substring(0, 8))
            continue
        }
        if ($gate -eq 'skip') {
            Write-Log @{ ev = 'fire-skip'; session = $e.session; reason = 'transcript-unreadable' }
            continue
        }
        $e.legs = [int]$e.legs + 1   # count BEFORE launching: crash cannot loop forever
        Save-Entry $e
        $records += , (Start-ResumeLeg $e)
    }
    Write-Log @{ ev = 'legs-launched'; count = $records.Count }
    foreach ($rec in $records) { Resolve-LegVerdict $rec }

    if (@(Get-ArmedAll).Count -gt 0) { Register-ProbeTask -DelayMinutes 10 }
    else { Unregister-ProbeTask }
}

function Invoke-Disarm {
    $entries = @(Get-ArmedAll)
    if ($Arg) { $entries = @($entries | Where-Object { $_.session -like "$Arg*" }) }
    if (-not $entries) { Write-Host 'nothing matched to disarm'; return }
    foreach ($e in $entries) {
        $lockPath = Join-Path $ArmedDir ($e.session + '.lock.json')
        if (Test-Path $lockPath) {
            try {
                $lock = Get-Content $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($lock.pid -and (Get-Process -Id $lock.pid -ErrorAction SilentlyContinue)) {
                    & taskkill /T /F /PID $lock.pid 2>$null | Out-Null
                    Write-Host ('killed in-flight resume for {0} (pid {1})' -f $e.session.Substring(0, 8), $lock.pid)
                }
            } catch { }
        }
        Remove-Entry $e.session
        Write-Log @{ ev = 'disarm'; session = $e.session }
        Write-Host ('disarmed {0}' -f $e.session.Substring(0, 8))
    }
    if (@(Get-ArmedAll).Count -eq 0) { Unregister-ProbeTask }
}

function Invoke-SetLegs {
    # change a session's leg budget in place - no disarm/re-arm dance; the
    # probe reads the entry fresh every tick, so the new cap applies to the
    # next leg automatically
    $n = 0
    if (-not $Arg -or -not [int]::TryParse($Arg2, [ref]$n) -or $n -lt 1 -or $n -gt 9) {
        Write-Host 'usage: relay legs <sessionIdPrefix> <1-9>'; return
    }
    $entries = @(Get-ArmedAll | Where-Object { $_.session -like "$Arg*" })
    if (-not $entries) { Write-Host ('no armed session matches ''{0}''' -f $Arg); return }
    foreach ($e in $entries) {
        $e | Add-Member -NotePropertyName maxLegs -NotePropertyValue $n -Force
        Save-Entry $e
        Write-Log @{ ev = 'set-legs'; session = $e.session; maxLegs = $n }
        Write-Host ('{0}: max legs -> {1} ({2} used)' -f $e.session.Substring(0, 8), $n, $e.legs)
    }
}

function Invoke-Status {
    Write-Host ''
    Write-Host '=== claude-relay ==='
    $entries = @(Get-ArmedAll)
    if ($entries) {
        foreach ($e in $entries) {
            $m = 'wait'
            if ($e.PSObject.Properties['mode'] -and $e.mode) { $m = $e.mode }
            $running = ''
            $lockPath = Join-Path $ArmedDir ($e.session + '.lock.json')
            if (Test-Path $lockPath) {
                try {
                    $lock = Get-Content $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $running = ('  RUNNING pid {0}' -f $lock.pid)
                } catch { }
            }
            Write-Host ('armed  : {0}  mode {1}  leg {2}/{3}{4}' -f $e.session.Substring(0, 8), $m, $e.legs, $e.maxLegs, $running)
            Write-Host ('         cwd {0}' -f $e.cwd)
        }
    } else {
        Write-Host 'armed  : none'
    }
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        $info = $task | Get-ScheduledTaskInfo
        Write-Host ('probe  : registered, next run {0}' -f $info.NextRunTime)
    } else {
        Write-Host 'probe  : no task'
    }
    Write-Host ''
    Write-Host '-- recent events --'
    if (Test-Path $LogPath) {
        Get-Content $LogPath -Encoding UTF8 | Select-Object -Last 8 | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host '(no log yet)'
    }
    Write-Host ''
}

function Invoke-StatusJson {
    # single compact JSON object for panel.ps1 -- nothing else on stdout
    $armedOut = @()
    foreach ($e in @(Get-ArmedAll)) {
        $m = 'wait'
        if ($e.PSObject.Properties['mode'] -and $e.mode) { $m = $e.mode }
        $running = $false
        $lockPath = Join-Path $ArmedDir ($e.session + '.lock.json')
        if (Test-Path $lockPath) { $running = $true }
        $armedOut += @{ session = $e.session; mode = $m; legs = [int]$e.legs; maxLegs = [int]$e.maxLegs; cwd = $e.cwd; running = $running }
    }
    $doneOut = @()
    $doneFiles = @(Get-ChildItem -Path (Join-Path $DoneDir '*.json') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    foreach ($df in $doneFiles) {
        try {
            $d = Get-Content $df.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $doneOut += @{ session = $d.session; cwd = $d.cwd; ok = [bool]$d.ok; finishedAt = $d.finishedAt }
        } catch { }
    }
    $out = @{ armed = $armedOut; done = $doneOut }
    ConvertTo-Json -InputObject $out -Compress -Depth 6
}

function Invoke-Sessions {
    # latest 10 session transcripts as a JSON array -- nothing else on stdout
    $files = @(Get-SessionFiles | Select-Object -First 10)
    $out = @()
    foreach ($f in $files) {
        $cwd = Get-SessionCwd $f.FullName
        $snip = Get-SessionSnippet $f.FullName
        $act = Get-TranscriptActivity $f.FullName
        if (-not $act) { $act = $f.LastWriteTime }
        $out += @{ session = $f.BaseName; cwd = $cwd; mtime = $act.ToString('s'); snippet = $snip }
    }
    # -InputObject (never pipe): a 0- or 1-element array must still serialize as a JSON array
    ConvertTo-Json -InputObject $out -Compress -Depth 5
}

function Open-TakeoverTab($session, $cwd) {
    if (-not (Test-Path $cwd)) { $cwd = $Root }
    # the takeover TUI inherits the conversation's own recorded tier straight
    # from the transcript (works even for entries armed before this existed).
    # Only the tier survives - run /effort inside if you want ultracode back.
    $eff = 'high'
    $sfE = Get-SessionFileById $session
    if ($sfE) { $eff = Get-SessionEffort $sfE.FullName }
    # --dangerously-skip-permissions carries over into the takeover TUI: the
    # relayed legs already ran with approvals skipped, and stopping to approve
    # every tool call after taking over defeats the point (user decision)
    #
    # persistence armor, twice: once in our own env (inherited down the spawn
    # chain) and once inside the new shell itself (Windows Terminal may source
    # a tab's environment elsewhere than the wt.exe launcher). Without it a
    # takeover TUI that inherited CLAUDE_CODE_CHILD_SESSION silently stops
    # saving transcripts - the user worked 34 min in one and the conversation
    # record simply never existed (observed live 07-31).
    $env:CLAUDE_CODE_FORCE_SESSION_PERSISTENCE = '1'
    $inner = 'Remove-Item Env:CLAUDE_CODE_CHILD_SESSION, Env:CLAUDE_CODE_EFFORT_LEVEL, Env:NO_COLOR -ErrorAction SilentlyContinue; $env:CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=''1''; claude --resume {0} --dangerously-skip-permissions --effort {1}' -f $session, $eff
    if (Get-Command wt -ErrorAction SilentlyContinue) {
        # new Windows Terminal tab: current terminal stays free for more takeovers.
        # NO semicolons inside the wt argument: wt treats ; as ITS OWN subcommand
        # separator even inside quotes, so an inline env-var statement got split
        # into three "programs" and three broken tabs (observed live 08-02).
        # The env armor above is inherited through wt into the tab - proven by
        # the child-session marker having leaked through the same path.
        Start-Process wt -ArgumentList ('-w 0 nt -d "{0}" pwsh -NoLogo -NoExit -Command "claude --resume {1} --dangerously-skip-permissions --effort {2}"' -f $cwd, $session, $eff)
        Write-Host ('opened tab for {0}  ({1})' -f $session.Substring(0, 8), $cwd)
    } else {
        # detached launch: running this in-process would block/break when called
        # from panel.ps1's redirected child
        Start-Process (Resolve-HostShell) -ArgumentList '-NoLogo', '-NoExit', '-Command', $inner -WorkingDirectory $cwd
        Write-Host ('opened detached shell for {0}  ({1})' -f $session.Substring(0, 8), $cwd)
    }
}

function Invoke-Takeover {
    $armed = @(Get-ArmedAll)
    $done = @()
    $doneFiles = @(Get-ChildItem -Path (Join-Path $DoneDir '*.json') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    foreach ($df in $doneFiles) {
        try {
            $d = Get-Content $df.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $done += , @{ session = $d.session; cwd = $d.cwd; ok = $d.ok; file = $df.FullName }
        } catch { }
    }

    if ($Arg -eq 'all') {
        # one tab per finished relay; armed/running ones stay put (take those over deliberately)
        if (-not $done) { Write-Host 'no finished relays to take over'; return }
        foreach ($d in $done) {
            Remove-Item $d.file -ErrorAction SilentlyContinue   # taken - drop from future lists
            Open-TakeoverTab $d.session $d.cwd
        }
        if ($armed) { Write-Host ('note: {0} session(s) still armed/relaying - "relay takeover <prefix>" to force one' -f $armed.Count) }
        return
    }

    $cands = @()
    foreach ($e in $armed) { $cands += , @{ session = $e.session; cwd = $e.cwd; state = 'armed/' + $e.mode; file = $null } }
    foreach ($d in $done)  {
        $st = 'done'; if (-not $d.ok) { $st = 'stopped' }
        $cands += , @{ session = $d.session; cwd = $d.cwd; state = $st; file = $d.file }
    }
    if ($Arg) { $cands = @($cands | Where-Object { $_.session -like "$Arg*" }) }
    if (-not $cands) { Write-Host 'nothing to take over'; return }
    $pickd = $cands[0]
    if ($cands.Count -gt 1 -and -not $Arg) {
        Write-Host ''
        $show = @($cands | Select-Object -First 6)
        for ($i = 0; $i -lt $show.Count; $i++) {
            Write-Host ('[{0}] {1}  {2}  {3}' -f ($i + 1), $show[$i].session.Substring(0, 8), $show[$i].state, $show[$i].cwd)
        }
        $pick = Read-Host 'which session? [1]'
        if (-not $pick) { $pick = '1' }
        $idx = [int]$pick - 1
        if ($idx -lt 0 -or $idx -ge $show.Count) { throw "invalid pick '$pick'" }
        $pickd = $show[$idx]
    }
    $sfT = Get-SessionFileById $pickd.session
    if ($sfT) {
        $actT = Get-TranscriptActivity $sfT.FullName
        if ($actT -and (((Get-Date) - $actT).TotalMinutes -lt 5) -and ((Get-SessionTailState $sfT.FullName) -ne 'limit')) {
            Write-Host 'WARNING: this conversation had a real turn minutes ago - if its original window is still open, two interactive windows will double-write one transcript'
        }
    }
    if ($pickd.state -like 'armed*') {
        Write-Host 'NOTE: this session is still armed - disarming it so the TUI is the only writer'
        $script:Arg = $pickd.session
        Invoke-Disarm
    }
    if ($pickd.file) { Remove-Item $pickd.file -ErrorAction SilentlyContinue }   # taken - drop from future lists
    Open-TakeoverTab $pickd.session $pickd.cwd
}

switch -Regex ($Command) {
    '^arm$'      { Invoke-Arm; break }
    '^probe$'    { Invoke-Probe; break }
    '^disarm$'   { Invoke-Disarm; break }
    '^status$'   { if ($Json) { Invoke-StatusJson } else { Invoke-Status }; break }
    '^takeover$' { Invoke-Takeover; break }
    '^legs$'     { Invoke-SetLegs; break }
    '^sessions$' { Invoke-Sessions; break }
    default      { Write-Host 'usage: relay arm [sessionIdPrefix] [-Watch] [-Prompt "..."] [-MaxLegs N] | disarm [prefix] | legs <prefix> <1-9> | status [-Json] | takeover [prefix] | sessions | probe' }
}
