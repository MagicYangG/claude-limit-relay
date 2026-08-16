#Requires -Version 5.1
<#
claude-limit-relay panel -- local web control panel (P4)

Pure PowerShell HttpListener server that serves web/index.html and implements
the JSON API the page talks to. It owns no state of its own: every read/write
goes through preheat.ps1 / relay.ps1 (single source of truth) so the CLI and
the web panel can never disagree.

Usage: panel.ps1 [-Port 7878] [-NoBrowser]

Endpoints (see web/index.html for the client side):
  GET  /                     web/index.html
  GET  /api/status           {preheat:{tasks}, relay:{armed,done}}
  GET  /api/sessions         latest 10 session transcripts
  GET  /api/schedule         raw parsed schedule.json {rules:[...], proxy:"..."}
  POST /api/preheat/once      {kind:"reset"|"at"|"plus", value:"HH:mm"|"2h"}
  POST /api/preheat/apply     {rules:[{days:[...], reset:"HH:mm"}, ...]}
  POST /api/relay/arm        {session, watch, maxLegs, fallback}   fallback: '' = default opus hop, 'none' = park on model cap
  POST /api/relay/disarm     {session} or {} for all
  POST /api/relay/legs       {session, maxLegs}   change leg budget in place
  POST /api/relay/takeover   {session} or {all:true}
  POST /api/relay/dismiss    {session} or {all:true}   clear finished-relay records

Ctrl+C stops the listener cleanly (polling GetContextAsync, not a blocking
GetContext, so the console break can actually land).
#>
[CmdletBinding()]
param(
    [int]$Port = 7878,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
# the panel is often started from inside a Claude Code session, whose shells
# carry CLAUDE_CODE_CHILD_SESSION=1 - anything spawned from here (takeover
# tabs, resume legs) would inherit it and silently stop saving transcripts.
# Scrub it once so no descendant can ever be marked.
Remove-Item Env:CLAUDE_CODE_CHILD_SESSION -ErrorAction SilentlyContinue
# see relay.ps1: this var would beat the --effort flag on every claude the
# relay spawns below us and silently disable ultracode orchestration
Remove-Item Env:CLAUDE_CODE_EFFORT_LEVEL -ErrorAction SilentlyContinue
# and NO_COLOR=1 (Claude Code tool shells set it) would strip every ANSI
# color from takeover TUIs spawned below us - one flat monochrome wall
Remove-Item Env:NO_COLOR -ErrorAction SilentlyContinue
if ($env:TERM -eq 'dumb') { Remove-Item Env:TERM -ErrorAction SilentlyContinue }
$Root         = $PSScriptRoot
$WebDir       = Join-Path $Root 'web'
$IndexPath    = Join-Path $WebDir 'index.html'
$PreheatScript = Join-Path $Root 'preheat.ps1'
$RelayScript  = Join-Path $Root 'relay.ps1'
$PreheatLog    = Join-Path $Root 'preheat-log.jsonl'
$RelayLog     = Join-Path $Root 'relay-log.jsonl'
$PanelLog     = Join-Path $Root 'panel-log.txt'
$ConfigPath   = Join-Path $Root 'schedule.json'

# cache for the preheat-status shell-out: the call is cheap now (scheduled-task
# query + one metadata scan; ccusage is gone) but each uncached poll still
# spawns a pwsh, so keep a short TTL
$script:PreheatStatusCache = @{ value = $null; ts = [datetime]::MinValue }
$PreheatStatusCacheTtlSec  = 30

# cache for the relay-status / sessions shell-outs: every uncached poll spawns a
# fresh pwsh (module load = CPU spike); with a 15s browser poll that produced
# periodic fan roar. POSTs to /api/relay/* invalidate RelayStatusCache.
$script:RelayStatusCache   = @{ value = $null; ts = [datetime]::MinValue }
$RelayStatusCacheTtlSec    = 45
$script:SessionsCache      = @{ value = $null; ts = [datetime]::MinValue }
$SessionsCacheTtlSec       = 120

# learn report shells out to preheat.ps1 (history scan); long TTL, lazy
$script:LearnCache         = @{ value = $null; ts = [datetime]::MinValue }
$LearnCacheTtlSec          = 600

# full-UUID validator shared by relay session-id inputs (Finding 7)
$script:UuidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

function Resolve-HostShell {
    $p = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($p) { return $p.Source }
    (Get-Command powershell).Source
}
$Shell = Resolve-HostShell

function Write-PanelLog([string]$line) {
    $ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    try {
        if ((Test-Path $PanelLog) -and ((Get-Item $PanelLog).Length -gt 2MB)) {
            $keep = Get-Content $PanelLog -Tail 1000 -Encoding UTF8
            Set-Content -Path $PanelLog -Value $keep -Encoding UTF8
        }
        Add-Content -Path $PanelLog -Value ('[{0}] {1}' -f $ts, $line) -Encoding UTF8
    } catch { }
}

# ---------- shelling out to preheat.ps1 / relay.ps1 ----------

function Quote-Arg([string]$a) {
    if ($a -notmatch '[\s"]') { return $a }
    # Windows argv rules: a backslash run is literal UNLESS it precedes a quote.
    # Escaping only the quote (" -> \") lets a value ending in \" splice extra
    # argv tokens into the child process - double every backslash run before a
    # quote (and before the closing quote), then escape the quote itself.
    $escaped = [regex]::Replace($a, '(\\*)"', { param($m) ($m.Groups[1].Value * 2) + '\"' })
    $escaped = [regex]::Replace($escaped, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
    '"' + $escaped + '"'
}

function Invoke-BackendCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$CmdArgs = @()
    )
    $quoted = @($CmdArgs | ForEach-Object { Quote-Arg $_ })
    $argStr = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $ScriptPath, ($quoted -join ' ')
    $stamp   = [guid]::NewGuid().ToString('N')
    $outFile = Join-Path $Root (".panel-out-$stamp.tmp")
    $errFile = Join-Path $Root (".panel-err-$stamp.tmp")
    try {
        # no stdin redirect: every call path here always supplies an explicit session/id
        # (panel refuses ambiguous takeover requests below) so nothing ever needs to read stdin
        $p = Start-Process -FilePath $Shell -ArgumentList $argStr -WorkingDirectory $Root `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
            -PassThru -NoNewWindow
        if (-not $p.WaitForExit(120000)) {
            try { $p.Kill() } catch { }
            return @{ ExitCode = -1; StdOut = ''; StdErr = 'timeout after 120s' }
        }
        $stdout = ''; if (Test-Path $outFile) { $stdout = Get-Content $outFile -Raw -Encoding UTF8 }
        $stderr = ''; if (Test-Path $errFile) { $stderr = Get-Content $errFile -Raw -Encoding UTF8 }
        @{ ExitCode = $p.ExitCode; StdOut = $stdout; StdErr = $stderr }
    } finally {
        Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
    }
}

function Get-ResultMessage($res) {
    $txt = ''
    if ($res.StdOut) { $txt = $res.StdOut.Trim() }
    if (-not $txt -and $res.StdErr) { $txt = $res.StdErr.Trim() }
    if (-not $txt) {
        if ($res.ExitCode -eq 0) { return 'ok' }
        return "exit code $($res.ExitCode)"
    }
    # strip ANSI escapes, then drop pipe/table-format noise lines, keeping the
    # first remaining non-empty line (Finding 4)
    $esc = [char]27
    $ansiPattern = [regex]::Escape($esc) + '\[[0-9;]*m'
    $clean = $txt -replace $ansiPattern, ''
    $lines = @($clean -split "`r?`n" | Where-Object {
        $_.Trim() -ne '' -and $_ -notmatch '^\s*(\||\+|At line|Line \|)'
    })
    if ($lines.Count -gt 0) { return $lines[0].Trim() }
    $txt
}

# ---------- in-process status readers ----------
# GET polls used to shell out to preheat.ps1/relay.ps1 - a fresh pwsh per poll
# meant a JIT/CPU spike every minute (periodic fan roar, observed live). These
# read-only views are cheap to compute in-process; POST actions still shell out.

$ArmedDir = Join-Path $Root 'armed'
$DoneDir  = Join-Path $Root 'done'

function Get-PreheatStatusObject {
    $tasks = @()
    try {
        foreach ($t in @(Get-ScheduledTask -TaskName 'ClaudePreheat*' -ErrorAction SilentlyContinue)) {
            $info = $t | Get-ScheduledTaskInfo
            $next = $null
            if ($info.NextRunTime) { $next = $info.NextRunTime.ToString('yyyy-MM-ddTHH:mm:ss') }
            $tasks += @{ name = $t.TaskName; next = $next }
        }
    } catch { }
    @{ tasks = $tasks }
}

function Get-SessionSnippetById($id) {
    $sf = Get-ChildItem -Path (Join-Path $env:USERPROFILE ('.claude\projects\*\{0}.jsonl' -f $id)) -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $sf) { return '' }
    Get-TranscriptSnippet $sf.FullName (Get-TailLines $sf.FullName)
}

function Get-RelayStatusObject {
    $armedOut = @()
    foreach ($af in @(Get-ChildItem -Path (Join-Path $ArmedDir '*.json') -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '*.lock.json' })) {
        try {
            $e = Get-Content $af.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $m = 'wait'
            if ($e.PSObject.Properties['mode'] -and $e.mode) { $m = $e.mode }
            $snip = ''; $actIso = $null
            $sf = Get-ChildItem -Path (Join-Path $env:USERPROFILE ('.claude\projects\*\{0}.jsonl' -f $e.session)) -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($sf) {
                $tailA = Get-TailLines $sf.FullName
                $snip = Get-TranscriptSnippet $sf.FullName $tailA
                # activity rides along so the page can warn before a takeover
                # that would double-write a conversation that is still moving
                $a = Get-ActivityFromTail $tailA $sf.LastWriteTime
                if ($a) { $actIso = ([datetime]$a).ToString('s') }
            }
            $armedOut += @{
                session = $e.session; mode = $m; legs = [int]$e.legs; maxLegs = [int]$e.maxLegs
                cwd = $e.cwd; running = (Test-Path (Join-Path $ArmedDir ($e.session + '.lock.json')))
                snippet = $snip; activity = $actIso
            }
        } catch { }
    }
    $doneOut = @()
    foreach ($df in @(Get-ChildItem -Path (Join-Path $DoneDir '*.json') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        try {
            $d = Get-Content $df.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $snip = ''
            if ($doneOut.Count -lt 10) { $snip = Get-SessionSnippetById $d.session }   # cap enrichment
            $dsum = ''
            if ($d.PSObject.Properties['summary'] -and $d.summary) { $dsum = [string]$d.summary }
            $doneOut += @{ session = $d.session; cwd = $d.cwd; ok = [bool]$d.ok; finishedAt = $d.finishedAt; snippet = $snip; summary = $dsum }
        } catch { }
    }
    @{ armed = $armedOut; done = $doneOut }
}

function Get-TailLines($file, [int]$maxBytes = 2097152) {
    # bounded tail read: transcript lines can be multi-MB (tool results), and
    # Get-Content -Tail N must decode ALL of them just to count lines (20s+
    # stall observed live); a fixed byte window keeps the cost flat
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

function Get-TranscriptCwd($file, $tail) {
    # verified against the transcript's bucket dir name (same rule as
    # relay.ps1 Get-SessionCwd): only a bucket-matching cwd can resume, so
    # only that one is worth displaying
    $bucket = Split-Path (Split-Path $file -Parent) -Leaf
    $cands  = New-Object System.Collections.Generic.List[string]
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

function Get-TranscriptSnippet($file, $tail) {
    # newest real user message, skipping slash-command dumps / caveats /
    # tool results (same heuristic as relay.ps1 Get-SessionSnippet)
    $fallback = ''
    for ($i = $tail.Count - 1; $i -ge 0; $i--) {
        $line = $tail[$i]
        if ($line -notmatch '"type"\s*:\s*"user"') { continue }
        if ($line -match '"tool_result"') { continue }
        # one record can hold several text items (a compact-continuation
        # message buries the human text behind meta blocks) - scan them all
        foreach ($m in [regex]::Matches($line, '"(?:text|content)"\s*:\s*"((?:[^"\\]|\\.){1,70})')) {
            $t = $m.Groups[1].Value -replace '\\n', ' '
            if ($t -match '^\s*(<|#|\[|Caveat|Base directory)') {
                if (-not $fallback) { $fallback = $t }
                continue
            }
            return $t
        }
    }
    # tail had no REAL user text: scan the head too - an early real line
    # beats a meta line captured from the tail
    try {
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

function Get-ActivityFromTail($tail, $fallback) {
    # Newest REAL turn in the tail, as local time. Two traps, both observed live:
    #  1. file mtime lies - indexers/backups bump it without appending a byte,
    #     so a dead session renders as active "just now"
    #  2. attachment / away_summary / turn_duration records are appended to an
    #     OPEN-BUT-IDLE session, so file growth alone is not a turn either
    # Only user/assistant records count.
    $best = $null
    foreach ($line in $tail) {
        if ($line -notmatch '"type"\s*:\s*"(assistant|user)"') { continue }
        if ($line -notmatch '"timestamp"\s*:\s*"([^"]+)"') { continue }
        $v = $Matches[1]
        if ((-not $best) -or ($v -gt $best)) { $best = $v }   # ISO-8601 UTC sorts lexically
    }
    if ($best) { try { return ([datetimeoffset]::Parse($best)).LocalDateTime } catch { } }
    $fallback
}

function Get-SessionsObject {
    $out = @()
    $files = @(Get-ChildItem -Path (Join-Path $env:USERPROFILE '.claude\projects\*\*.jsonl') -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 10)
    foreach ($f in $files) {
        $tail = Get-TailLines $f.FullName
        $out += @{
            session = $f.BaseName
            cwd     = Get-TranscriptCwd $f.FullName $tail
            mtime   = (Get-ActivityFromTail $tail $f.LastWriteTime).ToString('s')
            snippet = Get-TranscriptSnippet $f.FullName $tail
        }
    }
    $out
}

# ---------- HTTP plumbing ----------

function Read-RequestBody($request) {
    if (-not $request.HasEntityBody) { return '' }
    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
    try { $reader.ReadToEnd() } finally { $reader.Close() }
}

function Send-Bytes($context, [int]$statusCode, [byte[]]$bytes, [string]$contentType) {
    $context.Response.StatusCode = $statusCode
    $context.Response.ContentType = $contentType
    $context.Response.ContentLength64 = $bytes.Length
    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $context.Response.OutputStream.Close()
}

function Send-Json($context, [int]$statusCode, $obj) {
    # -InputObject (never pipe): a bare 0- or 1-element top-level array must
    # still serialize as a JSON array, not unwrap to a scalar
    $json = ConvertTo-Json -InputObject $obj -Compress -Depth 8
    Send-Bytes $context $statusCode ([System.Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8'
}

function Send-Html($context, [int]$statusCode, [string]$html) {
    # never let the browser heuristically cache the page - stale UI after a
    # redesign kept masquerading as a bug (observed live twice)
    $context.Response.Headers['Cache-Control'] = 'no-cache'
    Send-Bytes $context $statusCode ([System.Text.Encoding]::UTF8.GetBytes($html)) 'text/html; charset=utf-8'
}

# ---------- POST security gate (Finding 7) ----------

function Test-PostSecurity($context) {
    $req = $context.Request

    $ct = $req.ContentType
    if (-not $ct -or $ct -notlike '*application/json*') {
        Send-Json $context 400 @{ ok = $false; message = 'Content-Type must be application/json' }
        return $false
    }

    $origin  = $req.Headers['Origin']
    $referer = $req.Headers['Referer']
    foreach ($h in @($origin, $referer)) {
        if ($h) {
            if (-not ($h.StartsWith('http://localhost:') -or $h.StartsWith('http://127.0.0.1:'))) {
                Send-Json $context 403 @{ ok = $false; message = 'origin not allowed' }
                return $false
            }
        }
    }

    $isLoopback = $false
    try {
        $remote = $req.RemoteEndPoint
        if ($remote -and $remote.Address) { $isLoopback = [System.Net.IPAddress]::IsLoopback($remote.Address) }
    } catch { }
    if (-not $isLoopback) {
        Send-Json $context 403 @{ ok = $false; message = 'forbidden' }
        return $false
    }

    $true
}

# ---------- API handlers ----------

function Handle-ApiStatus($context) {
    $preheatObj = $null
    $now = Get-Date
    $cacheAgeSec = [double]::PositiveInfinity
    if ($script:PreheatStatusCache.value) { $cacheAgeSec = ($now - $script:PreheatStatusCache.ts).TotalSeconds }
    if ($script:PreheatStatusCache.value -and $cacheAgeSec -lt $PreheatStatusCacheTtlSec) {
        # cache still fresh: serve it immediately, no shell-out (Finding 3)
        $preheatObj = $script:PreheatStatusCache.value
    } else {
        try {
            $preheatObj = Get-PreheatStatusObject
            $script:PreheatStatusCache.value = $preheatObj
            $script:PreheatStatusCache.ts = $now
        } catch { }
        if (-not $preheatObj -and $script:PreheatStatusCache.value) {
            # shell-out failed (or returned nothing): fall back to stale cache rather than blank
            $preheatObj = $script:PreheatStatusCache.value
        }
    }
    if (-not $preheatObj) { $preheatObj = @{ tasks = @() } }

    $relayObj = $null
    $rAge = [double]::PositiveInfinity
    if ($script:RelayStatusCache.value) { $rAge = ($now - $script:RelayStatusCache.ts).TotalSeconds }
    if ($script:RelayStatusCache.value -and $rAge -lt $RelayStatusCacheTtlSec) {
        $relayObj = $script:RelayStatusCache.value
    } else {
        try {
            $relayObj = Get-RelayStatusObject
            $script:RelayStatusCache.value = $relayObj
            $script:RelayStatusCache.ts = $now
        } catch { }
        if (-not $relayObj -and $script:RelayStatusCache.value) { $relayObj = $script:RelayStatusCache.value }
    }
    if (-not $relayObj) { $relayObj = @{ armed = @(); done = @() } }

    Send-Json $context 200 @{ preheat = $preheatObj; relay = $relayObj }
}

function Handle-ApiSessions($context) {
    $now = Get-Date
    $age = [double]::PositiveInfinity
    if ($script:SessionsCache.value) { $age = ($now - $script:SessionsCache.ts).TotalSeconds }
    if ($script:SessionsCache.value -and $age -lt $SessionsCacheTtlSec) {
        Send-Json $context 200 $script:SessionsCache.value
        return
    }
    $out = @()
    try { $out = @(Get-SessionsObject) } catch { }
    $script:SessionsCache.value = $out
    $script:SessionsCache.ts = $now
    Send-Json $context 200 $out
}

function Handle-ApiRateLimits($context) {
    # cached usage windows, written by statusline-tap.cjs (empty {} until the
    # tap is installed and a statusline has rendered once)
    $obj = $null
    try {
        $p = Join-Path $Root 'state-ratelimits.json'
        if (Test-Path $p) { $obj = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json }
    } catch { }
    if (-not $obj) { $obj = @{} }
    Send-Json $context 200 $obj
}

function Handle-ApiLearn($context) {
    # 30-day rhythm + 7-day window-utilization report from preheat.ps1 learn
    $now = Get-Date
    $age = [double]::PositiveInfinity
    if ($script:LearnCache.value) { $age = ($now - $script:LearnCache.ts).TotalSeconds }
    if ($script:LearnCache.value -and $age -lt $LearnCacheTtlSec) {
        Send-Json $context 200 $script:LearnCache.value
        return
    }
    $obj = $null
    try {
        $res = Invoke-BackendCommand -ScriptPath $PreheatScript -CmdArgs @('learn', '-Json')
        if ($res.ExitCode -eq 0 -and $res.StdOut) { $obj = $res.StdOut.Trim() | ConvertFrom-Json }
    } catch { }
    if (-not $obj) { $obj = @{ days = @(); waste = $null } }
    $script:LearnCache.value = $obj
    $script:LearnCache.ts = $now
    Send-Json $context 200 $obj
}

function Handle-ApiSchedule($context) {
    $obj = $null
    try {
        if (Test-Path $ConfigPath) {
            $raw = Get-Content $ConfigPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($raw) { $obj = $raw | ConvertFrom-Json }
        }
    } catch { }
    if (-not $obj) { $obj = [ordered]@{ rules = @(); proxy = '' } }
    Send-Json $context 200 $obj
}

function Handle-PreheatOnce($context) {
    $data = $null
    try { $data = (Read-RequestBody $context.Request) | ConvertFrom-Json } catch { }
    if (-not $data -or -not $data.kind -or -not $data.value) {
        Send-Json $context 400 @{ ok = $false; message = 'expected {kind, value}' }; return
    }
    $kind  = [string]$data.kind
    $value = [string]$data.value
    # server-side validation, mirroring the UUID gate on the relay endpoints:
    # the client checks these too, but a non-browser caller bypasses the client
    $cmdArgs = $null
    if ($kind -eq 'reset' -or $kind -eq 'at') {
        if ($value -notmatch '^\d{1,2}:\d{2}$') {
            Send-Json $context 400 @{ ok = $false; message = 'invalid time, expected HH:mm' }; return
        }
        $cmdArgs = @($kind, $value)
    } elseif ($kind -eq 'plus') {
        $v = $value
        if ($v -notmatch '^\+') { $v = '+' + $v }
        if ($v -notmatch '^\+\d{1,3}[hm]$') {
            Send-Json $context 400 @{ ok = $false; message = 'invalid offset, expected +Nh or +Nm' }; return
        }
        $cmdArgs = @($v)
    } else {
        Send-Json $context 400 @{ ok = $false; message = "unknown kind '$kind'" }; return
    }
    $res = Invoke-BackendCommand -ScriptPath $PreheatScript -CmdArgs $cmdArgs
    $script:PreheatStatusCache.ts = [datetime]::MinValue   # next poll shows the new task
    Send-Json $context 200 @{ ok = ($res.ExitCode -eq 0); message = (Get-ResultMessage $res) }
}

function Handle-PreheatApply($context) {
    $data = $null
    try { $data = (Read-RequestBody $context.Request) | ConvertFrom-Json } catch { }
    if (-not $data -or -not $data.rules) {
        Send-Json $context 400 @{ ok = $false; message = 'expected {rules:[...]}' }; return
    }

    $existing = $null
    try { if (Test-Path $ConfigPath) { $existing = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } } catch { }
    $proxy = ''
    if ($existing -and $existing.PSObject.Properties['proxy']) { $proxy = $existing.proxy }
    # always write the canonical hint: preserving the old value once kept a
    # stale command name alive in personal configs long after a rename
    $readme = 'days: Mon..Sun | reset = HH:mm target reset time (previous 5h window expiry); fire time auto = reset - 5h | edit then run: preheat apply'

    $rulesOut = @()
    foreach ($r in @($data.rules)) {
        $days = @($r.days)
        $rulesOut += [ordered]@{ days = $days; reset = [string]$r.reset }
    }
    $newConfig = [ordered]@{ _readme = $readme; proxy = $proxy; rules = $rulesOut }

    try {
        if (Test-Path $ConfigPath) {
            $probe = Get-Content $ConfigPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($probe) { Copy-Item $ConfigPath ($ConfigPath + '.bak') -Force }
        }
        (ConvertTo-Json -InputObject $newConfig -Depth 6) | Set-Content -Path $ConfigPath -Encoding UTF8
    } catch {
        Send-Json $context 500 @{ ok = $false; message = "failed to write schedule.json: $($_.Exception.Message)" }
        return
    }

    $res = Invoke-BackendCommand -ScriptPath $PreheatScript -CmdArgs @('apply')
    $script:PreheatStatusCache.ts = [datetime]::MinValue   # next poll shows the new tasks
    Send-Json $context 200 @{ ok = ($res.ExitCode -eq 0); message = (Get-ResultMessage $res) }
}

function Handle-RelayArm($context) {
    $data = $null
    try { $data = (Read-RequestBody $context.Request) | ConvertFrom-Json } catch { }
    if (-not $data -or -not $data.session) {
        Send-Json $context 400 @{ ok = $false; message = 'expected {session, watch, maxLegs}' }; return
    }
    $sessionVal = [string]$data.session
    if ($sessionVal -notmatch $script:UuidPattern) {
        Send-Json $context 400 @{ ok = $false; message = 'invalid session id' }; return
    }
    $cmdArgs = @('arm', $sessionVal)
    if ($data.PSObject.Properties['watch'] -and $data.watch) { $cmdArgs += '-Watch' }
    if ($data.PSObject.Properties['maxLegs'] -and $data.maxLegs) {
        $cmdArgs += '-MaxLegs'
        $cmdArgs += [string]([int]$data.maxLegs)
    }
    if ($data.PSObject.Properties['fallback'] -and $data.fallback) {
        $fbVal = [string]$data.fallback
        if ($fbVal -notmatch '^[a-z0-9][a-z0-9.,-]{0,59}$') {
            Send-Json $context 400 @{ ok = $false; message = 'invalid fallback' }; return
        }
        $cmdArgs += '-Fallback'
        $cmdArgs += $fbVal
    }
    $res = Invoke-BackendCommand -ScriptPath $RelayScript -CmdArgs $cmdArgs
    Send-Json $context 200 @{ ok = ($res.ExitCode -eq 0); message = (Get-ResultMessage $res) }
}

function Handle-RelayDisarm($context) {
    $data = $null
    try { $data = (Read-RequestBody $context.Request) | ConvertFrom-Json } catch { }
    $cmdArgs = @('disarm')
    if ($data -and $data.PSObject.Properties['session'] -and $data.session) {
        $sessionVal = [string]$data.session
        if ($sessionVal -notmatch $script:UuidPattern) {
            Send-Json $context 400 @{ ok = $false; message = 'invalid session id' }; return
        }
        $cmdArgs += $sessionVal
    }
    $res = Invoke-BackendCommand -ScriptPath $RelayScript -CmdArgs $cmdArgs
    Send-Json $context 200 @{ ok = ($res.ExitCode -eq 0); message = (Get-ResultMessage $res) }
}

function Handle-RelayLegs($context) {
    $data = $null
    try { $data = (Read-RequestBody $context.Request) | ConvertFrom-Json } catch { }
    if (-not $data -or -not $data.PSObject.Properties['session'] -or -not $data.session -or
        -not $data.PSObject.Properties['maxLegs']) {
        Send-Json $context 400 @{ ok = $false; message = 'expected {session, maxLegs}' }; return
    }
    $sessionVal = [string]$data.session
    if ($sessionVal -notmatch $script:UuidPattern) {
        Send-Json $context 400 @{ ok = $false; message = 'invalid session id' }; return
    }
    $n = 0
    try { $n = [int]$data.maxLegs } catch { }
    if ($n -lt 1 -or $n -gt 9) {
        Send-Json $context 400 @{ ok = $false; message = 'maxLegs must be 1-9' }; return
    }
    $res = Invoke-BackendCommand -ScriptPath $RelayScript -CmdArgs @('legs', $sessionVal, [string]$n)
    Send-Json $context 200 @{ ok = ($res.ExitCode -eq 0); message = (Get-ResultMessage $res) }
}

function Handle-RelayTakeover($context) {
    $data = $null
    try { $data = (Read-RequestBody $context.Request) | ConvertFrom-Json } catch { }
    $hasAll     = ($data -and $data.PSObject.Properties['all'] -and $data.all)
    $hasSession = ($data -and $data.PSObject.Properties['session'] -and $data.session)
    if (-not $hasAll -and -not $hasSession) {
        # relay.ps1's interactive picker needs a real console; a headless caller must always
        # say which session (or "all"), so refuse here rather than risk a hung child process
        Send-Json $context 400 @{ ok = $false; message = 'expected {session} or {all:true}' }; return
    }
    $cmdArgs = @('takeover')
    if ($hasAll) {
        $cmdArgs += 'all'
    } else {
        $sessionVal = [string]$data.session
        if ($sessionVal -notmatch $script:UuidPattern) {
            Send-Json $context 400 @{ ok = $false; message = 'invalid session id' }; return
        }
        $cmdArgs += $sessionVal
    }
    $res = Invoke-BackendCommand -ScriptPath $RelayScript -CmdArgs $cmdArgs
    Send-Json $context 200 @{ ok = ($res.ExitCode -eq 0); message = (Get-ResultMessage $res) }
}

function Handle-RelayDismiss($context) {
    # clear finished-relay records: purely local file deletes, no backend needed
    $data = $null
    try { $data = (Read-RequestBody $context.Request) | ConvertFrom-Json } catch { }
    $hasAll = ($data -and $data.PSObject.Properties['all'] -and $data.all)
    $n = 0
    if ($hasAll) {
        foreach ($f in @(Get-ChildItem -Path (Join-Path $DoneDir '*.json') -ErrorAction SilentlyContinue)) {
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue; $n++
        }
    } else {
        $sessionVal = ''
        if ($data -and $data.PSObject.Properties['session']) { $sessionVal = [string]$data.session }
        if ($sessionVal -notmatch $script:UuidPattern) {
            Send-Json $context 400 @{ ok = $false; message = 'expected {session} or {all:true}' }; return
        }
        $target = Join-Path $DoneDir ($sessionVal + '.json')
        if (Test-Path $target) { Remove-Item $target -Force -ErrorAction SilentlyContinue; $n = 1 }
    }
    $script:RelayStatusCache.ts = [datetime]::MinValue
    Send-Json $context 200 @{ ok = $true; message = ('removed {0} record(s)' -f $n) }
}

# ---------- request dispatch ----------

function Handle-Request($context) {
    $req    = $context.Request
    $path   = $req.Url.AbsolutePath
    $method = $req.HttpMethod
    Write-PanelLog ('{0} {1}' -f $method, $path)

    if ($method -eq 'GET' -and $path -eq '/') {
        if (Test-Path $IndexPath) {
            Send-Html $context 200 (Get-Content $IndexPath -Raw -Encoding UTF8)
        } else {
            Send-Html $context 404 '<h1>web/index.html not found</h1>'
        }
        return
    }
    if ($method -eq 'GET' -and $path -eq '/api/status')   { Handle-ApiStatus $context; return }
    if ($method -eq 'GET' -and $path -eq '/api/sessions') { Handle-ApiSessions $context; return }
    if ($method -eq 'GET' -and $path -eq '/api/schedule') { Handle-ApiSchedule $context; return }
    if ($method -eq 'GET' -and $path -eq '/api/ratelimits') { Handle-ApiRateLimits $context; return }
    if ($method -eq 'GET' -and $path -eq '/api/learn')      { Handle-ApiLearn $context; return }

    if ($method -eq 'POST' -and -not (Test-PostSecurity $context)) { return }

    # relay mutations must be visible on the next poll: drop the relay caches
    if ($method -eq 'POST' -and $path -like '/api/relay/*') {
        $script:RelayStatusCache.ts = [datetime]::MinValue
        $script:SessionsCache.ts = [datetime]::MinValue
    }

    if ($method -eq 'POST' -and $path -eq '/api/preheat/once')    { Handle-PreheatOnce $context; return }
    if ($method -eq 'POST' -and $path -eq '/api/preheat/apply')   { Handle-PreheatApply $context; return }
    if ($method -eq 'POST' -and $path -eq '/api/relay/arm')      { Handle-RelayArm $context; return }
    if ($method -eq 'POST' -and $path -eq '/api/relay/disarm')   { Handle-RelayDisarm $context; return }
    if ($method -eq 'POST' -and $path -eq '/api/relay/legs')     { Handle-RelayLegs $context; return }
    if ($method -eq 'POST' -and $path -eq '/api/relay/takeover') { Handle-RelayTakeover $context; return }
    if ($method -eq 'POST' -and $path -eq '/api/relay/dismiss')  { Handle-RelayDismiss $context; return }

    Send-Json $context 404 @{ ok = $false; message = "not found: $method $path" }
}

# ---------- main ----------

$Prefix = "http://localhost:$Port/"
# singleton guard: a second instance must fail loudly, never zombie (observed live)
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
    Write-Host ('port {0} already listening - panel is probably running; open {1}' -f $Port, $Prefix)
    exit 2
}
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($Prefix)
$bound = $false
for ($bindTry = 1; $bindTry -le 3 -and -not $bound; $bindTry++) {
    try {
        $listener.Start()
        $bound = $true
    } catch {
        if ($bindTry -ge 3) {
            Write-Host ('failed to start listener on {0}: {1}' -f $Prefix, $_.Exception.Message)
            Write-PanelLog ('FATAL: bind failed - ' + $_.Exception.Message)
            exit 1
        }
        # the port can linger briefly after a killed instance (observed live) - wait and retry
        Start-Sleep -Seconds 3
    }
}

Write-Host ''
Write-Host ('claude-limit-relay panel running at {0}' -f $Prefix)
Write-Host 'press Ctrl+C to stop'
Write-Host ''
Write-PanelLog ('start ' + $Prefix)

if (-not $NoBrowser) {
    try { Start-Process $Prefix } catch { }
}

try {
    while ($listener.IsListening) {
        $contextTask = $listener.GetContextAsync()
        # poll instead of a blocking GetContext() so Ctrl+C actually has a chance to land
        while (-not $contextTask.AsyncWaitHandle.WaitOne(500)) { }
        $context = $null
        try {
            $context = $contextTask.GetAwaiter().GetResult()
        } catch {
            if (-not $listener.IsListening) {
                # listener died: exit visibly instead of looping on a corpse
                Write-PanelLog ('FATAL: listener died - ' + $_.Exception.Message)
                break
            }
            Write-PanelLog ('WARN: accept failed - ' + $_.Exception.Message)
            continue
        }
        try {
            Handle-Request $context
        } catch {
            Write-PanelLog ('ERROR: ' + $_.Exception.Message)
            try {
                $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"message":"internal error"}')
                $context.Response.StatusCode = 500
                $context.Response.ContentType = 'application/json; charset=utf-8'
                $context.Response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                $context.Response.OutputStream.Close()
            } catch { }
        }
    }
} finally {
    try { $listener.Stop() } catch { }
    try { $listener.Close() } catch { }
    Write-PanelLog 'stop'
    Write-Host ''
    Write-Host 'panel stopped'
}
