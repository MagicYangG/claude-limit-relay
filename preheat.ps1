#Requires -Version 5.1
<#
claude-preheat -- Claude Max 5h usage-window preheater (P1) + phase observer (P3)

Commands:
  apply          Register weekly preheat tasks from schedule.json
  status         Show window phase, scheduled preheats, recent fires
                 -Json = print one compact JSON object instead (for scripts)
  at HH:mm       One-shot: fire at the given wall-clock time (next occurrence)
  reset HH:mm    One-shot: fire so the window RESETS at the given time (fire = reset - 5h)
  +Nh / +Nm      One-shot: fire N hours/minutes from now
  fire           Fire the preheat ping immediately (used by scheduled tasks)
  learn [auto]   Derive a preheat schedule from your last 30 days of prompts
                 (median start per weekday -> suggested reset time) plus a
                 7-day window-utilization report. 'auto' writes the suggested
                 rules into schedule.json (backed up) and applies them.
                 -Json = machine-readable report (for panel.ps1)
  statusline on|off
                 Wire statusline-tap.cjs into the statusLine (pure passthrough)
                 so exact 5h/weekly reset times land in state-ratelimits.json
                 for the panel quota strip
  off            Unregister all preheat tasks

Mechanism: the Max 5h usage window is anchored by the FIRST request when no
window is active. A scheduled tiny headless ping (`claude -p "hi"`) anchors it
at a chosen time with zero model involvement beforehand. Pinging while a
window is already active is a harmless no-op (anchor unchanged).
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'status',
    [Parameter(Position = 1)][string]$Arg,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$Root       = $PSScriptRoot
$ConfigPath = Join-Path $Root 'schedule.json'
$StatePath  = Join-Path $Root 'state.json'
$LogPath    = Join-Path $Root 'preheat-log.jsonl'
$FirePit    = Join-Path $Root 'firepit'
$EmptyMcp   = Join-Path $Root 'mcp-empty.json'
$TaskWkPrefix   = 'ClaudePreheat-Wk'
$TaskOncePrefix = 'ClaudePreheat-Once'
$WindowHours = 5

$DayMap   = @{ Mon = 'Monday'; Tue = 'Tuesday'; Wed = 'Wednesday'; Thu = 'Thursday'; Fri = 'Friday'; Sat = 'Saturday'; Sun = 'Sunday' }
$DayOrder = @('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')

function Read-Config {
    if (-not (Test-Path $ConfigPath)) { throw "schedule.json not found at $ConfigPath" }
    Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Read-State {
    if (Test-Path $StatePath) {
        try { Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
    } else { $null }
}

function Write-State($obj) { $obj | ConvertTo-Json -Depth 5 | Set-Content -Path $StatePath -Encoding UTF8 }

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

function Resolve-ClaudeExe {
    param([switch]$NoCache)
    if (-not $NoCache) {
        $state = Read-State
        if ($state -and $state.claude -and (Test-Path $state.claude)) { return $state.claude }
    }
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($cmd) {
        $src = $cmd.Source
        if ($src -like '*.ps1') {
            # npm shim: prefer the .cmd sibling so Start-Process can launch it directly
            $sib = [System.IO.Path]::ChangeExtension($src, '.cmd')
            if (Test-Path $sib) { return $sib }
        }
        return $src
    }
    foreach ($cand in @("$env:APPDATA\npm\claude.cmd", "$env:USERPROFILE\.local\bin\claude.exe")) {
        if (Test-Path $cand) { return $cand }
    }
    throw 'claude CLI not found (PATH incomplete in this context and no known fallback matched)'
}

function Resolve-HostShell {
    $p = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($p) { return $p.Source }
    (Get-Command powershell).Source
}

function Get-Proxy {
    # empty/missing config proxy -> $null (callers must skip setting HTTPS_PROXY/HTTP_PROXY)
    if (Test-Path $ConfigPath) {
        try {
            $c = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($c.proxy) { return $c.proxy }
        } catch { }
    }
    $null
}

function Get-FireSpecs($config) {
    # rule { days:[Mon..]; reset:'HH:mm' } -> @{ Days = full names (shifted if fire crosses midnight); FireTime = timespan; Reset }
    $specs = @()
    foreach ($rule in $config.rules) {
        $reset = [datetime]::ParseExact($rule.reset, 'HH:mm', $null)
        $fire  = $reset.TimeOfDay - [timespan]::FromHours($WindowHours)
        $shift = 0
        if ($fire -lt [timespan]::Zero) { $fire = $fire + [timespan]::FromDays(1); $shift = -1 }
        $days = @()
        foreach ($d in $rule.days) {
            $full = $DayMap[$d]
            if (-not $full) { throw "Unknown day '$d' in schedule.json (use Mon..Sun)" }
            if ($shift -eq 0) { $days += $full }
            else {
                $i = $DayOrder.IndexOf($full)
                $days += $DayOrder[(($i + 7 + $shift) % 7)]
            }
        }
        $specs += @{ Days = $days; FireTime = $fire; Reset = $rule.reset }
    }
    $specs
}

function New-PreheatAction {
    # via run-hidden.vbs: a console action flashes a cmd window at every fire
    New-ScheduledTaskAction -Execute 'wscript.exe' `
        -Argument ('//B //Nologo "{0}" "{1}" "-NoProfile" "-ExecutionPolicy" "Bypass" "-File" "{2}" "fire"' -f `
            (Join-Path $Root 'run-hidden.vbs'), (Resolve-HostShell), (Join-Path $Root 'preheat.ps1'))
}

function New-PreheatSettings {
    New-ScheduledTaskSettingsSet -WakeToRun -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
}

function Test-WakeTimers {
    # warn if wake timers are disabled in the active power plan (AC)
    try {
        $out = powercfg /query SCHEME_CURRENT SUB_SLEEP RTCWAKE 2>$null
        # locale-invariant: first line containing a 0x value is the AC setting index
        # (localized label text would mojibake under BOM-less UTF-8 on powershell.exe 5.1)
        $line = ($out | Select-String '0x[0-9a-fA-F]{8}' | Select-Object -First 1)
        if ($line) {
            $v = $line.ToString()
            if ($v -match '0x0+$') {
                Write-Warning 'Wake timers DISABLED on AC power - preheat cannot wake the PC from sleep. Enable: powercfg -> Sleep -> Allow wake timers'
            } elseif ($v -match '0x0*2$') {
                Write-Warning 'Wake timers = "important only" - a user scheduled task may NOT wake the PC. Set to Enabled to be safe.'
            }
        }
    } catch { }
}

function Invoke-Apply {
    $config = Read-Config
    $specs  = Get-FireSpecs $config
    # resolve claude path now, in an interactive shell where PATH is complete
    Write-State @{ claude = (Resolve-ClaudeExe); pwsh = (Resolve-HostShell); appliedAt = (Get-Date).ToString('s') }
    Get-ScheduledTask -TaskName "$TaskWkPrefix*" -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
    $action   = New-PreheatAction
    $settings = New-PreheatSettings
    foreach ($s in $specs) {
        # StartBoundary must be in the future, else the scheduler's week alignment
        # can skip the nearest occurrence (observed: Sat task jumping a full week)
        $at = (Get-Date).Date + $s.FireTime
        if ($at -le (Get-Date)) { $at = $at.AddDays(1) }
        $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $s.Days -At $at
        $dayTag  = ($s.Days | ForEach-Object { $_.Substring(0, 3) }) -join ''
        $name    = '{0}-{1}-{2}' -f $TaskWkPrefix, $s.FireTime.ToString('hhmm'), $dayTag
        Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
        Write-Host ('registered  {0}  fire {1}  -> reset {2}  [{3}]' -f $name, $s.FireTime.ToString('hh\:mm'), $s.Reset, ($s.Days -join ','))
    }
    Write-Log @{ ev = 'apply'; tasks = $specs.Count }
    Test-WakeTimers
}

function Get-TranscriptActivity($file) {
    # Newest REAL turn in a transcript, as local time. Two traps this avoids,
    # both observed live:
    #  1. file mtime lies - local tools (indexers, backups) bump it without
    #     appending a single byte, so a dead session looks active "just now"
    #  2. not every record is an API turn - Claude Code appends attachment /
    #     away_summary / turn_duration / stop_hook_summary bookkeeping to an
    #     OPEN-BUT-IDLE session, so "the file grew" does not mean the model
    #     was called and does not mean a usage window was anchored
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

function Get-LastLocalActivity {
    # last locally visible Claude usage, judged by transcript CONTENT.
    # Blind to phone/web usage - like any local observation.
    try {
        $proj = Join-Path $HOME '.claude\projects'
        if (-not (Test-Path $proj)) { return $null }
        $files = @(Get-ChildItem -Path $proj -Filter '*.jsonl' -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 8)
        $best = $null
        foreach ($f in $files) {
            $t = Get-TranscriptActivity $f.FullName
            if (-not $t) { continue }
            if ((-not $best) -or ($t -gt $best)) { $best = $t }
        }
        return $best
    } catch { return $null }
}

function Send-Toast($ok) {
    try {
        if (Get-Module -ListAvailable -Name BurntToast) {
            Import-Module BurntToast -ErrorAction Stop
            $msg = if ($ok) { 'window preheated' } else { 'preheat FAILED - check preheat-log.jsonl' }
            New-BurntToastNotification -Text 'claude-preheat', $msg | Out-Null
        }
    } catch { }
}

function Remove-StaleOnceTasks {
    Get-ScheduledTask -TaskName "$TaskOncePrefix*" -ErrorAction SilentlyContinue | ForEach-Object {
        $info = $_ | Get-ScheduledTaskInfo
        if (-not $info.NextRunTime -or $info.NextRunTime -lt (Get-Date).AddMinutes(-3)) {
            $_ | Unregister-ScheduledTask -Confirm:$false
        }
    }
}

function Invoke-Fire {
    # nothing before the ping may block the ping
    try { Remove-StaleOnceTasks } catch { }
    $proxy = Get-Proxy
    if ($proxy) { $env:HTTPS_PROXY = $proxy; $env:HTTP_PROXY = $proxy }
    if (-not (Test-Path $FirePit)) {
        # -Force + SilentlyContinue: two near-simultaneous fires must not die on check-then-create
        New-Item -ItemType Directory -Path $FirePit -Force -ErrorAction SilentlyContinue | Out-Null
    }

    $claude = $null
    try { $claude = Resolve-ClaudeExe } catch {
        Write-Log @{ ev = 'fire'; ok = $false; err = 'claude CLI not found' }
        Send-Toast $false
        return
    }

    # local-activity snapshot BEFORE the ping (metadata read only): if no
    # transcript changed in the 5h before fire time, no locally visible
    # window was active, so a successful ping anchored a fresh one
    $fireStart = Get-Date
    $lastAct   = Get-LastLocalActivity

    $pingArgs = '-p "hi" --model haiku --no-session-persistence --strict-mcp-config --mcp-config "{0}" --output-format json' -f $EmptyMcp
    $ok = $false; $attempts = 0; $cost = $null; $ms = $null; $errText = $null

    while (-not $ok -and $attempts -lt 3) {
        $attempts++
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        # unique per invocation+attempt: overlapping fires must not share redirect files
        $outFile = Join-Path $Root ('.fire-out-{0}-{1}.tmp' -f $PID, $attempts)
        $errFile = Join-Path $Root ('.fire-err-{0}-{1}.tmp' -f $PID, $attempts)
        try {
            $p = Start-Process -FilePath $claude -ArgumentList $pingArgs -WorkingDirectory $FirePit `
                -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -NoNewWindow
            $null = $p.Handle   # PS 5.1: without touching Handle first, ExitCode reads null forever
            if (-not $p.WaitForExit(240000)) {
                try { $p.Kill() } catch { }
                throw 'timeout after 240s'
            }
            $sw.Stop(); $ms = $sw.ElapsedMilliseconds
            $stdout = ''
            if (Test-Path $outFile) { $stdout = Get-Content $outFile -Raw }
            if ($p.ExitCode -eq 0 -and $stdout) {
                try { $j = $stdout | ConvertFrom-Json; $cost = $j.total_cost_usd } catch { }
                $ok = $true
            } else {
                $errText = ''
                if (Test-Path $errFile) { $errText = Get-Content $errFile -Raw }
                if (-not $errText) { $errText = "exit=$($p.ExitCode) $stdout" }
                $errText = $errText.Substring(0, [Math]::Min(400, $errText.Length))
            }
        } catch {
            $sw.Stop(); $errText = $_.Exception.Message
        } finally {
            Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
        }
        if (-not $ok -and $attempts -eq 1) {
            # self-heal: cached claude path may exist but be broken (e.g. after a CLI reinstall)
            try {
                $fresh = Resolve-ClaudeExe -NoCache
                if ($fresh -and ($fresh -ne $claude)) { $claude = $fresh; $refreshed = $true }
            } catch { }
        }
        if (-not $ok -and $attempts -lt 3) { Start-Sleep -Seconds 90 }
    }

    if ($ok -and $refreshed) {
        try {
            $st = Read-State
            if ($st) { $st.claude = $claude; Write-State $st } else { Write-State @{ claude = $claude } }
        } catch { }
    }

    $entry = @{ ev = 'fire'; ok = $ok; attempts = $attempts; ms = $ms; cost = $cost }
    if (-not $ok) { $entry.err = $errText }
    if ($ok) {
        $entry.anchored = (-not $lastAct) -or (($fireStart - $lastAct).TotalHours -ge $WindowHours)
        if ($lastAct) { $entry.last_local_activity = $lastAct.ToString('yyyy-MM-dd HH:mm') }
    }
    Write-Log $entry
    Send-Toast $ok
}

function Invoke-Once($fireAt, $label) {
    if ($fireAt -le (Get-Date)) { throw "fire time $fireAt is in the past" }
    $trigger = New-ScheduledTaskTrigger -Once -At $fireAt
    $name    = '{0}-{1}' -f $TaskOncePrefix, $fireAt.ToString('yyyyMMdd-HHmm')
    Register-ScheduledTask -TaskName $name -Action (New-PreheatAction) -Trigger $trigger -Settings (New-PreheatSettings) -Force | Out-Null
    Write-Log @{ ev = 'schedule-once'; fireAt = $fireAt.ToString('s'); label = $label }
    Write-Host ('one-shot registered: fire at {0}  ({1})' -f $fireAt.ToString('yyyy-MM-dd HH:mm'), $label)
}

function Get-NextOccurrence([string]$hhmm) {
    $t    = [datetime]::ParseExact($hhmm, 'HH:mm', $null)
    $cand = (Get-Date).Date + $t.TimeOfDay
    if ($cand -le (Get-Date)) { $cand = $cand.AddDays(1) }
    $cand
}

function Invoke-Status {
    Write-Host ''
    Write-Host '=== claude-preheat ==='
    $last = Get-LastLocalActivity
    if ($last) {
        $gapH = ((Get-Date) - $last).TotalHours
        if ($gapH -lt $WindowHours) {
            Write-Host ('activity : last local use {0} ({1:n1}h ago) - a window is likely active; exact reset: /usage' -f $last.ToString('MM-dd HH:mm'), $gapH)
        } else {
            Write-Host ('activity : quiet for {0:n1}h - next message (or preheat) anchors a fresh window' -f $gapH)
        }
    } else {
        Write-Host 'activity : no local transcripts found'
    }
    Write-Host ''
    Write-Host '-- scheduled preheats --'
    $tasks = Get-ScheduledTask -TaskName 'ClaudePreheat*' -ErrorAction SilentlyContinue
    if ($tasks) {
        foreach ($t in $tasks) {
            $info = $t | Get-ScheduledTaskInfo
            Write-Host ('{0}  next: {1}' -f $t.TaskName.PadRight(40), $info.NextRunTime)
        }
    } else {
        Write-Host '(none - run: preheat apply)'
    }
    Write-Host ''
    Write-Host '-- recent events --'
    if (Test-Path $LogPath) {
        Get-Content $LogPath -Encoding UTF8 | Select-Object -Last 8 | ForEach-Object {
            try {
                $e = $_ | ConvertFrom-Json
                if ($e.ev -eq 'fire') {
                    $flag = if ($e.ok) { 'OK  ' } else { 'FAIL' }
                    $anch = ''
                    if ($e.PSObject.Properties['anchored']) {
                        $anch = if ($e.anchored) { 'anchored NEW window' } else { 'local activity <5h before fire - likely landed in existing window' }
                    }
                    Write-Host ('[{0}] fire {1} attempts={2} {3}ms  {4}' -f $e.ts, $flag, $e.attempts, $e.ms, $anch)
                } else {
                    Write-Host ('[{0}] {1}' -f $e.ts, $e.ev)
                }
            } catch { }
        }
    } else {
        Write-Host '(no log yet)'
    }
    Write-Host ''
    # same warning apply gives: a fire that cannot wake the PC is a silent no-show
    Test-WakeTimers
}

function Invoke-StatusJson {
    # single compact JSON object for scripts -- nothing else on stdout
    $last = Get-LastLocalActivity
    $lastIso = $null
    if ($last) { $lastIso = $last.ToString('yyyy-MM-ddTHH:mm:ss') }
    $tasks = @()
    $rawTasks = Get-ScheduledTask -TaskName 'ClaudePreheat*' -ErrorAction SilentlyContinue
    if ($rawTasks) {
        foreach ($t in $rawTasks) {
            $info = $t | Get-ScheduledTaskInfo
            $next = $null
            if ($info.NextRunTime) { $next = $info.NextRunTime.ToString('yyyy-MM-ddTHH:mm:ss') }
            $tasks += @{ name = $t.TaskName; next = $next }
        }
    }
    $out = @{ lastActivity = $lastIso; tasks = $tasks }
    ConvertTo-Json -InputObject $out -Compress -Depth 6
}

# ---------- learn: schedule suggestions + waste report from prompt history ----------

function Get-HistoryTimestamps([int]$days = 30) {
    # ~\.claude\history.jsonl logs one line per user prompt with an epoch-ms
    # timestamp - the cheapest full activity record there is (transcripts
    # would mean reading hundreds of MB for the same numbers)
    $h = Join-Path $env:USERPROFILE '.claude\history.jsonl'
    $out = New-Object System.Collections.Generic.List[datetime]
    if (-not (Test-Path $h)) { return ,$out }
    $cut = (Get-Date).AddDays(-$days)
    try {
        foreach ($line in [System.IO.File]::ReadLines($h)) {
            if ($line -notmatch '"timestamp"\s*:\s*(\d+)') { continue }
            $n = [double]$Matches[1]
            if ($n -gt 1e12) { $n = $n / 1000 }
            $t = [DateTimeOffset]::FromUnixTimeSeconds([long]$n).LocalDateTime
            if ($t -ge $cut) { [void]$out.Add($t) }
        }
    } catch { }
    $out.Sort()
    ,$out
}

function Get-WindowStats($stamps) {
    # reconstruct 5h windows the way the account anchors them: the first
    # prompt while no window is active opens one; everything within 5h of the
    # anchor rides it; the next prompt after expiry anchors the next
    $wins = @()
    $anchor = $null; $lastIn = $null
    foreach ($t in $stamps) {
        if ($anchor -and ($t -lt $anchor.AddHours($WindowHours))) { $lastIn = $t; continue }
        if ($anchor) { $wins += , @{ anchor = $anchor; last = $lastIn } }
        $anchor = $t; $lastIn = $t
    }
    if ($anchor) { $wins += , @{ anchor = $anchor; last = $lastIn } }
    # plain return (callers wrap in @()): a `,`-wrapped return here would
    # double-wrap and hand Where-Object one 54-anchor blob instead of 54 windows
    $wins
}

function Get-MedianTimeOfDay($times) {
    if (-not $times -or $times.Count -eq 0) { return $null }
    $sorted = @($times | Sort-Object { $_.TotalMinutes })
    $sorted[[int][Math]::Floor(($sorted.Count - 1) / 2)]
}

function Get-LearnReport($stamps, $now) {
    $wins = @(Get-WindowStats $stamps)
    $byDay = @{}
    foreach ($w in $wins) {
        $d = $w.anchor.DayOfWeek.ToString().Substring(0, 3)
        if (-not $byDay[$d]) { $byDay[$d] = New-Object System.Collections.Generic.List[object] }
        [void]$byDay[$d].Add($w.anchor.TimeOfDay)
    }
    $dayOrder = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun')
    $days = @()
    foreach ($d in $dayOrder) {
        if (-not $byDay[$d]) { continue }
        $ts = $byDay[$d]
        $median = Get-MedianTimeOfDay $ts
        $suggest = $null
        $suggestDay = $d
        if (($ts.Count -ge 2) -and $median) {
            # reset ~1h after the typical start: early work rides the old
            # window's tail, the bulk of the session gets a fresh one
            $m = [Math]::Round(($median.TotalMinutes + 60) / 30) * 30
            if ($m -ge 1440) {
                # a start near midnight pushes the reset past 24:00 - the rule
                # must carry to the NEXT weekday, or Get-FireSpecs anchors the
                # window a full day early (fire ~23h before the user starts)
                $m = $m - 1440
                $suggestDay = $dayOrder[(([array]::IndexOf($dayOrder, $d) + 1) % 7)]
            }
            $suggest = ([timespan]::FromMinutes($m)).ToString('hh\:mm')
        }
        $days += , @{ day = $d; samples = $ts.Count; median = $median.ToString('hh\:mm'); suggest = $suggest; suggestDay = $suggestDay }
    }
    # utilization, last 7 days: prompts under-count long agent runs, so each
    # window gets a 30-min grace past its last prompt - still an ESTIMATE
    $wk = @($wins | Where-Object { $_.anchor -ge $now.AddDays(-7) })
    $engaged = 0.0; $total = 0.0
    foreach ($w in $wk) {
        $end = $w.anchor.AddHours($WindowHours)
        if ($end -gt $now) { $end = $now }
        $winH = ($end - $w.anchor).TotalHours
        if ($winH -le 0) { continue }
        $total += $winH
        $e = (($w.last - $w.anchor).TotalHours) + 0.5
        if ($e -gt $winH) { $e = $winH }
        $engaged += $e
    }
    $pct = $null
    if ($total -gt 0) { $pct = [int][Math]::Round(100 * $engaged / $total) }
    @{
        days  = $days
        waste = @{ windows = $wk.Count; engagedH = [Math]::Round($engaged, 1); totalH = [Math]::Round($total, 1); usedPct = $pct }
    }
}

function Invoke-Learn {
    $stamps = Get-HistoryTimestamps 30
    if ($stamps.Count -eq 0) {
        if ($Json) { ConvertTo-Json -InputObject @{ days = @(); waste = $null } -Compress }
        else { Write-Host 'no prompt history found (~\.claude\history.jsonl) - nothing to learn from' }
        return
    }
    $rep = Get-LearnReport $stamps (Get-Date)
    if ($Json) { ConvertTo-Json -InputObject $rep -Compress -Depth 6; return }

    Write-Host ''
    Write-Host '=== preheat learn (last 30 days of local prompts) ===' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'day  windows  median-start  suggested-reset'
    foreach ($d in $rep.days) {
        $s = $d.suggest; if (-not $s) { $s = '(need >=2 windows)' }
        Write-Host ('{0}  {1}  {2}         {3}' -f $d.day, ([string]$d.samples).PadLeft(7), $d.median, $s)
    }
    $w = $rep.waste
    if ($w -and $w.windows -gt 0) {
        Write-Host ''
        Write-Host ('last 7 days: {0} window(s) opened, ~{1}h engaged of {2}h window time ({3}% used, estimate)' -f `
            $w.windows, $w.engagedH, $w.totalH, $w.usedPct)
    }
    $groups = [ordered]@{}
    foreach ($d in $rep.days) {
        if (-not $d.suggest) { continue }
        if (-not $groups.Contains($d.suggest)) { $groups[$d.suggest] = @() }
        $groups[$d.suggest] += $d.suggestDay   # carries past midnight to the next weekday
    }
    if ($groups.Count -eq 0) {
        Write-Host ''
        Write-Host 'not enough data for suggestions yet (a weekday needs >=2 observed windows)'
        return
    }
    Write-Host ''
    Write-Host 'suggested rules:'
    foreach ($k in $groups.Keys) { Write-Host ('  {0}: reset {1}' -f ($groups[$k] -join ','), $k) }

    if ($Arg -ne 'auto') {
        Write-Host ''
        Write-Host 'apply them: preheat learn auto   (backs up schedule.json, writes these rules, runs apply)'
        return
    }
    # auto: write + apply, preserving the proxy; days without a suggestion get
    # no rule (no observed rhythm -> nothing worth pre-warming)
    $proxy = ''
    try {
        if (Test-Path $ConfigPath) {
            $probe = Get-Content $ConfigPath -Raw -Encoding UTF8
            if ($probe) {
                Copy-Item $ConfigPath ($ConfigPath + '.bak') -Force
                $c0 = $probe | ConvertFrom-Json
                if ($c0.PSObject.Properties['proxy']) { $proxy = $c0.proxy }
            }
        }
    } catch { }
    $rulesOut = @()
    foreach ($k in $groups.Keys) { $rulesOut += [ordered]@{ days = @($groups[$k]); reset = [string]$k } }
    $newConfig = [ordered]@{
        _readme = 'days: Mon..Sun | reset = HH:mm target reset time (previous 5h window expiry); fire time auto = reset - 5h | edit then run: preheat apply'
        proxy   = $proxy
        rules   = $rulesOut
    }
    (ConvertTo-Json -InputObject $newConfig -Depth 6) | Set-Content -Path $ConfigPath -Encoding UTF8
    Write-Host ''
    Write-Host 'schedule.json written (previous copy saved as schedule.json.bak) - applying:'
    Invoke-Apply
}

function Invoke-Off {
    Get-ScheduledTask -TaskName 'ClaudePreheat*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
    Write-Log @{ ev = 'off' }
    Write-Host 'all preheat tasks removed'
}

function ConvertTo-BashPath([string]$p) {
    # statusLine commands run under sh: C:\x\y -> /c/x/y. The result gets
    # embedded inside double quotes, which stop word-splitting but NOT $ or
    # backtick expansion - escape those so a path like C:\tools\$dev survives
    $x = $p -replace '\\', '/'
    if ($x -match '^([A-Za-z]):(.*)$') { $x = '/' + $Matches[1].ToLower() + $Matches[2] }
    $x -replace '([$"`\\])', '\$1'
}

function Invoke-StatusLineSetup {
    # Wire statusline-tap.cjs into the user's statusLine (or remove it again).
    # The tap is a pure pipe stage - stdin reaches the original command
    # byte-identical - so wrapping is safe for ANY existing command:
    #   "<node>" "<tap>" | ( <original command> )
    # With no statusLine configured at all, the tap runs --solo and renders a
    # minimal usage line itself. Original settings are backed up AND kept in a
    # sidecar so 'off' restores them exactly.
    $onOff = $Arg
    if ($onOff -notin @('on', 'off')) { Write-Host 'usage: preheat statusline on | off'; return }
    $tap = Join-Path $Root 'statusline-tap.cjs'
    $sidecar = Join-Path $Root 'statusline-original.json'
    $claudeDir = Join-Path $env:USERPROFILE '.claude'
    $candFiles = @((Join-Path $claudeDir 'settings.local.json'), (Join-Path $claudeDir 'settings.json'))
    $readCmd = {
        param($path)
        if (-not (Test-Path $path)) { return $null }
        try {
            $j = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.PSObject.Properties['statusLine'] -and $j.statusLine -and $j.statusLine.PSObject.Properties['command']) {
                return [string]$j.statusLine.command
            }
        } catch { }
        $null
    }
    # the tap may live in EITHER settings file (whichever had the statusLine
    # when it was installed) - both on and off must look at both, or an off
    # after the other file gained a statusLine becomes a silent no-op while
    # the wrapped file stays wired (found by review 2026-08-15)
    $tapFile = $null
    foreach ($cand in $candFiles) {
        $c = & $readCmd $cand
        if ($c -and ($c -like '*statusline-tap.cjs*')) { $tapFile = $cand; break }
    }

    if ($onOff -eq 'off') {
        $sFile = $null
        if (Test-Path $sidecar) {
            # the sidecar remembers exactly which file was wrapped - trust it
            # as long as that file still carries the tap
            try {
                $sc = Get-Content $sidecar -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($sc.PSObject.Properties['file'] -and $sc.file) {
                    $c = & $readCmd ([string]$sc.file)
                    if ($c -and ($c -like '*statusline-tap.cjs*')) { $sFile = [string]$sc.file }
                }
            } catch { }
        }
        if (-not $sFile) { $sFile = $tapFile }
        if (-not $sFile) { Write-Host 'statusline tap is not installed - nothing to do'; return }
        $json = $null
        try { $json = Get-Content $sFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
            Write-Host ('cannot parse {0} - fix it first, nothing was changed' -f $sFile); return
        }
        $oldCmd = [string]$json.statusLine.command
        $restore = $null
        if (Test-Path $sidecar) {
            try { $restore = Get-Content $sidecar -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        }
        if (Test-Path $sFile) { Copy-Item $sFile ($sFile + '.bak-' + (Get-Date).ToString('yyyyMMdd-HHmmss')) -Force }
        if ($restore -and $restore.PSObject.Properties['command'] -and $restore.command) {
            $json.statusLine.command = [string]$restore.command
        } elseif ($oldCmd -match '^"[^"]+" "[^"]*statusline-tap\.cjs" \| \( (.*) \)$') {
            $json.statusLine.command = $Matches[1]   # sidecar lost: unwrap
        } else {
            $json.PSObject.Properties.Remove('statusLine')   # tap was solo: statusLine did not exist before
        }
        ConvertTo-Json -InputObject $json -Depth 20 | Set-Content -Path $sFile -Encoding UTF8
        Remove-Item $sidecar -ErrorAction SilentlyContinue
        Write-Host ('statusline tap removed from {0} (backup written)' -f $sFile)
        return
    }

    # --- on ---
    if ($tapFile) { Write-Host ('statusline tap is already installed (in {0})' -f $tapFile); return }
    # target: whichever file currently carries a statusLine, local preferred;
    # neither -> settings.local.json gets a solo tap
    $sFile = $null
    foreach ($cand in $candFiles) {
        if (& $readCmd $cand) { $sFile = $cand; break }
    }
    if (-not $sFile) { $sFile = $candFiles[0] }
    $json = $null
    if (Test-Path $sFile) {
        try { $json = Get-Content $sFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
            Write-Host ('cannot parse {0} - fix it first, nothing was changed' -f $sFile); return
        }
    }
    if (-not $json) { $json = [pscustomobject]@{} }
    $oldCmd = & $readCmd $sFile
    # reuse the node the user's own command already points at (the statusline
    # environment may not have node on PATH); fall back to PATH lookup
    $node = 'node'
    if ($oldCmd -and ($oldCmd -match '"([^"]*node(\.exe)?)"')) { $node = $Matches[1] }
    elseif (Get-Command node -ErrorAction SilentlyContinue) { $node = ConvertTo-BashPath (Get-Command node).Source }
    $tapBash = ConvertTo-BashPath $tap
    if ($oldCmd) {
        $newCmd = ('"{0}" "{1}" | ( {2} )' -f $node, $tapBash, $oldCmd)
    } else {
        $newCmd = ('"{0}" "{1}" --solo' -f $node, $tapBash)
    }
    if (Test-Path $sFile) {
        $probe = Get-Content $sFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($probe) { Copy-Item $sFile ($sFile + '.bak-' + (Get-Date).ToString('yyyyMMdd-HHmmss')) -Force }
    }
    @{ file = $sFile; command = $oldCmd } | ConvertTo-Json | Set-Content -Path $sidecar -Encoding UTF8
    if ($json.PSObject.Properties['statusLine'] -and $json.statusLine) {
        $json.statusLine | Add-Member -NotePropertyName command -NotePropertyValue $newCmd -Force
        if (-not ($json.statusLine.PSObject.Properties['type'])) {
            $json.statusLine | Add-Member -NotePropertyName type -NotePropertyValue 'command' -Force
        }
    } else {
        $json | Add-Member -NotePropertyName statusLine -NotePropertyValue ([pscustomobject]@{ type = 'command'; command = $newCmd }) -Force
    }
    ConvertTo-Json -InputObject $json -Depth 20 | Set-Content -Path $sFile -Encoding UTF8
    Write-Host ('statusline tap installed in {0} (backup + sidecar written)' -f $sFile)
    Write-Host 'takes effect on the next statusline render; rate limits land in state-ratelimits.json'
    Write-Host 'undo anytime: preheat statusline off'
}

switch -Regex ($Command) {
    '^apply$'  { Invoke-Apply; break }
    '^fire$'   { Invoke-Fire; break }
    '^status$' { if ($Json) { Invoke-StatusJson } else { Invoke-Status }; break }
    '^learn$'  { Invoke-Learn; break }
    '^off$'    { Invoke-Off; break }
    '^statusline$' { Invoke-StatusLineSetup; break }
    '^at$'     {
        if (-not $Arg) { throw 'usage: preheat at HH:mm' }
        Invoke-Once (Get-NextOccurrence $Arg) ('at ' + $Arg)
        break
    }
    '^reset$'  {
        if (-not $Arg) { throw 'usage: preheat reset HH:mm' }
        $t = (Get-NextOccurrence $Arg).AddHours(-$WindowHours)
        if ($t -le (Get-Date)) {
            Write-Host ('requested reset {0} unreachable today (fire time already past) - scheduling for tomorrow' -f $Arg)
            $t = $t.AddDays(1)
        }
        Invoke-Once $t ('reset ' + $Arg)
        break
    }
    '^\+\d+[hm]$' {
        $null = $Command -match '^\+(\d+)([hm])$'
        $n = [int]$Matches[1]
        $t = if ($Matches[2] -eq 'h') { (Get-Date).AddHours($n) } else { (Get-Date).AddMinutes($n) }
        Invoke-Once $t $Command
        break
    }
    default {
        Write-Host 'usage: preheat apply | status [-Json] | learn [auto] | at HH:mm | reset HH:mm | +Nh | +Nm | fire | statusline on|off | off'
    }
}
