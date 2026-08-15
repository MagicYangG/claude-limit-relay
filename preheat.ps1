#Requires -Version 5.1
<#
claude-limit-relay -- Claude Max 5h usage-window preheater (P1) + phase observer (P3)

Commands:
  apply          Register weekly preheat tasks from schedule.json
  status         Show window phase, scheduled preheats, recent fires
                 -Json = print one compact JSON object instead (for panel.ps1)
  at HH:mm       One-shot: fire at the given wall-clock time (next occurrence)
  reset HH:mm    One-shot: fire so the window RESETS at the given time (fire = reset - 5h)
  +Nh / +Nm      One-shot: fire N hours/minutes from now
  fire           Fire the preheat ping immediately (used by scheduled tasks)
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
            New-BurntToastNotification -Text 'claude-limit-relay', $msg | Out-Null
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
    Write-Host '=== claude-limit-relay ==='
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
}

function Invoke-StatusJson {
    # single compact JSON object for panel.ps1 -- nothing else on stdout
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

function Invoke-Off {
    Get-ScheduledTask -TaskName 'ClaudePreheat*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
    Write-Log @{ ev = 'off' }
    Write-Host 'all preheat tasks removed'
}

switch -Regex ($Command) {
    '^apply$'  { Invoke-Apply; break }
    '^fire$'   { Invoke-Fire; break }
    '^status$' { if ($Json) { Invoke-StatusJson } else { Invoke-Status }; break }
    '^off$'    { Invoke-Off; break }
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
        Write-Host 'usage: preheat apply | status [-Json] | at HH:mm | reset HH:mm | +Nh | +Nm | fire | off'
    }
}
