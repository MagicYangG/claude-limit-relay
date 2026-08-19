#Requires -Version 5.1
<#
claude-preheat panel -- local web control panel

Pure PowerShell HttpListener server that serves web/index.html and implements
the JSON API the page talks to. It owns no state of its own: every read/write
goes through preheat.ps1 (single source of truth) so the CLI and the web
panel can never disagree.

Usage: panel.ps1 [-Port 7878] [-NoBrowser]

Endpoints (see web/index.html for the client side):
  GET  /                     web/index.html
  GET  /api/status           {preheat:{tasks}}
  GET  /api/schedule         raw parsed schedule.json {rules:[...], proxy:"..."}
  GET  /api/ratelimits       cached usage windows written by statusline-tap.cjs
  GET  /api/learn            30-day rhythm + 7-day window-utilization report
  POST /api/preheat/once     {kind:"reset"|"at"|"plus", value:"HH:mm"|"2h"}
  POST /api/preheat/apply    {rules:[{days:[...], reset:"HH:mm"}, ...]}

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
# carry CLAUDE_CODE_CHILD_SESSION=1 - the claude pings preheat.ps1 spawns
# below us would inherit it and silently stop saving transcripts. Scrub it
# once so no descendant can ever be marked.
Remove-Item Env:CLAUDE_CODE_CHILD_SESSION -ErrorAction SilentlyContinue
$Root         = $PSScriptRoot
$WebDir       = Join-Path $Root 'web'
$IndexPath    = Join-Path $WebDir 'index.html'
$PreheatScript = Join-Path $Root 'preheat.ps1'
$PanelLog     = Join-Path $Root 'panel-log.txt'
$ConfigPath   = Join-Path $Root 'schedule.json'

# cache for the preheat-status read: it runs in-process, but each uncached
# poll is still a Get-ScheduledTask + Get-ScheduledTaskInfo query, so keep a
# short TTL
$script:PreheatStatusCache = @{ value = $null; ts = [datetime]::MinValue }
$PreheatStatusCacheTtlSec  = 30

# learn report shells out to preheat.ps1 (history scan); long TTL, lazy
$script:LearnCache         = @{ value = $null; ts = [datetime]::MinValue }
$LearnCacheTtlSec          = 600

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

# ---------- shelling out to preheat.ps1 ----------

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
        # no stdin redirect: every preheat.ps1 command invoked here is fully
        # specified by its argv, so nothing ever needs to read stdin
        $p = Start-Process -FilePath $Shell -ArgumentList $argStr -WorkingDirectory $Root `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
            -PassThru -NoNewWindow
        $null = $p.Handle   # PS 5.1: without touching Handle first, ExitCode reads null forever
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
# GET polls used to shell out to preheat.ps1 - a fresh pwsh per poll meant a
# JIT/CPU spike every minute (periodic fan roar, observed live). This
# read-only view is cheap to compute in-process; POST actions still shell out.

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
        # cache still fresh: serve it immediately, no task-scheduler query (Finding 3)
        $preheatObj = $script:PreheatStatusCache.value
    } else {
        try {
            $preheatObj = Get-PreheatStatusObject
            $script:PreheatStatusCache.value = $preheatObj
            $script:PreheatStatusCache.ts = $now
        } catch { }
        if (-not $preheatObj -and $script:PreheatStatusCache.value) {
            # query failed (or returned nothing): fall back to stale cache rather than blank
            $preheatObj = $script:PreheatStatusCache.value
        }
    }
    if (-not $preheatObj) { $preheatObj = @{ tasks = @() } }

    Send-Json $context 200 @{ preheat = $preheatObj }
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
    # server-side validation: the client checks these too, but a non-browser
    # caller bypasses the client
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
    if ($method -eq 'GET' -and $path -eq '/api/schedule') { Handle-ApiSchedule $context; return }
    if ($method -eq 'GET' -and $path -eq '/api/ratelimits') { Handle-ApiRateLimits $context; return }
    if ($method -eq 'GET' -and $path -eq '/api/learn')      { Handle-ApiLearn $context; return }

    if ($method -eq 'POST' -and -not (Test-PostSecurity $context)) { return }

    if ($method -eq 'POST' -and $path -eq '/api/preheat/once')    { Handle-PreheatOnce $context; return }
    if ($method -eq 'POST' -and $path -eq '/api/preheat/apply')   { Handle-PreheatApply $context; return }

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
Write-Host ('claude-preheat panel running at {0}' -f $Prefix)
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
