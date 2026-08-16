#Requires -Version 5.1
<#
claude-limit-relay self-test.

Run:  ./test.ps1            (add -Verbose for per-case detail)
Exit: 0 = all passed, 1 = at least one failure.

Costs nothing and touches nothing that matters:
  - no `claude` call, so zero quota and no usage window is anchored
  - schedule.json, the real journals and the registered scheduled tasks are
    never written; the panel is started on a spare port and killed again
  - all fixtures live under a temp directory that is removed at the end

What CANNOT be automated here (needs a real account and real waiting):
  1. that a headless ping anchors a NEW window when none is active   <- the
     load-bearing assumption of the whole tool; verify via /usage after a
     scheduled preheat that fires following 5h+ of true inactivity
  2. that a ping into an ALREADY-ACTIVE window is a harmless no-op
  3. that a rejected probe consumes no quota
  4. that -WakeToRun really wakes this machine from sleep
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Repo = $PSScriptRoot
$Tmp  = Join-Path ([System.IO.Path]::GetTempPath()) ('clr-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Tmp -Force | Out-Null

$script:Pass = 0
$script:Fail = 0
$script:Failures = @()

function Test-Case([string]$name, [scriptblock]$body) {
    try {
        $result = & $body
        if ($result -eq $true) {
            $script:Pass++
            Write-Verbose ("PASS  " + $name)
        } else {
            $script:Fail++
            $script:Failures += ('{0}   (returned: {1})' -f $name, $result)
            Write-Host ("FAIL  " + $name) -ForegroundColor Red
        }
    } catch {
        $script:Fail++
        $script:Failures += ('{0}   (threw: {1})' -f $name, $_.Exception.Message)
        Write-Host ("FAIL  " + $name + "  [threw] " + $_.Exception.Message) -ForegroundColor Red
    }
}

function New-Fixture([string]$name, [string[]]$lines) {
    $p = Join-Path $Tmp $name
    Set-Content -Path $p -Value ($lines -join "`n") -Encoding UTF8
    $p
}

# record builders that mirror the real transcript shapes
function Rec-User([string]$text, [string]$tsUtc, [string]$cwd) {
    # a plainly typed message stores content as a STRING, not as text items -
    # the shape that made the snippet regex blind for a whole day
    $c = '{"type":"user","message":{"role":"user","content":"' + $text + '"},"timestamp":"' + $tsUtc + '"'
    if ($cwd) { $c += ',"cwd":"' + $cwd + '"' }
    $c + '}'
}
function Rec-UserItems([string]$text, [string]$tsUtc) {
    '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"' + $text + '"}]},"timestamp":"' + $tsUtc + '"}'
}
function Rec-ToolResult([string]$text, [string]$tsUtc) {
    '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"' + $text + '"}]},"timestamp":"' + $tsUtc + '"}'
}
function Rec-Assistant([string]$text, [string]$tsUtc) {
    '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"' + $text + '"}]},"timestamp":"' + $tsUtc + '"}'
}
function Rec-AssistantToolUse([string]$tsUtc) {
    '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]},"timestamp":"' + $tsUtc + '"}'
}
function Rec-AssistantLimit([string]$tsUtc) {
    # the REAL shape of a limit kill (captured live 07-30): an assistant record
    # whose text reads like a normal completed reply - only the structured
    # error fields give it away
    '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"You''ve hit your session limit · resets 1:40pm (America/Los_Angeles)"}]},"error":"rate_limit","isApiErrorMessage":true,"timestamp":"' + $tsUtc + '"}'
}
function Rec-Bookkeeping([string]$subtype, [string]$tsUtc) {
    # Claude Code appends these to an OPEN-BUT-IDLE session: no API call happened
    if ($subtype -eq 'attachment') { return '{"type":"attachment","timestamp":"' + $tsUtc + '"}' }
    '{"type":"system","subtype":"' + $subtype + '","timestamp":"' + $tsUtc + '"}'
}
function Rec-Sidechain([string]$text, [string]$tsUtc) {
    # a subagent turn: same file, same "assistant" type, but isSidechain:true -
    # it is NOT part of the main conversation and must never decide the tail state
    '{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"' + $text + '"}]},"timestamp":"' + $tsUtc + '"}'
}

Write-Host ''
Write-Host '=== claude-limit-relay self-test ===' -ForegroundColor Cyan

# ---------------------------------------------------------------- preheat.ps1
# dot-source inside its own scope so relay's identically-named helpers cannot
# shadow these; '__selftest__' falls through to the usage branch
& {
    . (Join-Path $Repo 'preheat.ps1') '__selftest__' 6>$null | Out-Null
    Write-Host ''
    Write-Host '-- preheat: reset -> fire derivation --'

    Test-Case 'reset 08:40 -> fire 03:40, same day' {
        $s = @(Get-FireSpecs ([pscustomobject]@{ rules = @([pscustomobject]@{ days = @('Mon'); reset = '08:40' }) }))
        ($s[0].FireTime -eq [timespan]::Parse('03:40:00')) -and ($s[0].Days[0] -eq 'Monday')
    }
    Test-Case 'reset 06:30 -> fire 01:30, same day' {
        $s = @(Get-FireSpecs ([pscustomobject]@{ rules = @([pscustomobject]@{ days = @('Fri'); reset = '06:30' }) }))
        ($s[0].FireTime -eq [timespan]::Parse('01:30:00')) -and ($s[0].Days[0] -eq 'Friday')
    }
    Test-Case 'reset 02:00 -> fire 21:00 and day shifts back (Mon -> Sunday)' {
        $s = @(Get-FireSpecs ([pscustomobject]@{ rules = @([pscustomobject]@{ days = @('Mon'); reset = '02:00' }) }))
        ($s[0].FireTime -eq [timespan]::Parse('21:00:00')) -and ($s[0].Days[0] -eq 'Sunday')
    }
    Test-Case 'reset 05:00 -> fire 00:00 exactly, NO day shift' {
        $s = @(Get-FireSpecs ([pscustomobject]@{ rules = @([pscustomobject]@{ days = @('Wed'); reset = '05:00' }) }))
        ($s[0].FireTime -eq [timespan]::Zero) -and ($s[0].Days[0] -eq 'Wednesday')
    }
    Test-Case 'day shift wraps Sunday -> Saturday' {
        $s = @(Get-FireSpecs ([pscustomobject]@{ rules = @([pscustomobject]@{ days = @('Sun'); reset = '01:00' }) }))
        $s[0].Days[0] -eq 'Saturday'
    }
    Test-Case 'multi-day rule keeps every day' {
        $s = @(Get-FireSpecs ([pscustomobject]@{ rules = @([pscustomobject]@{ days = @('Mon', 'Tue', 'Wed', 'Thu'); reset = '08:40' }) }))
        $s[0].Days.Count -eq 4
    }
    Test-Case 'unknown day name throws' {
        try {
            Get-FireSpecs ([pscustomobject]@{ rules = @([pscustomobject]@{ days = @('Xyz'); reset = '08:40' }) }) | Out-Null
            $false
        } catch { $true }
    }

    Write-Host '-- preheat: next occurrence --'
    Test-Case 'a time later today resolves to today' {
        $future = (Get-Date).AddHours(2).ToString('HH:mm')
        $n = Get-NextOccurrence $future
        ($n -gt (Get-Date)) -and (($n - (Get-Date)).TotalHours -lt 24)
    }
    Test-Case 'a time already past resolves to tomorrow (never the past)' {
        $past = (Get-Date).AddHours(-2).ToString('HH:mm')
        (Get-NextOccurrence $past) -gt (Get-Date)
    }

    Write-Host '-- preheat: activity detection --'
    Test-Case 'idle-session bookkeeping records do NOT count as activity' {
        # the trap: attachment / away_summary / turn_duration are appended to an
        # open-but-idle session, so "the file grew" is not a turn
        $f = New-Fixture 'idle.jsonl' @(
            (Rec-User 'hello' '2026-07-26T01:00:00.000Z' $null),
            (Rec-Assistant 'hi' '2026-07-26T01:00:05.000Z'),
            (Rec-Bookkeeping 'attachment' '2026-07-26T09:00:00.000Z'),
            (Rec-Bookkeeping 'away_summary' '2026-07-26T09:30:00.000Z'),
            (Rec-Bookkeeping 'turn_duration' '2026-07-26T09:30:01.000Z')
        )
        $act = Get-TranscriptActivity $f
        $expected = ([datetimeoffset]::Parse('2026-07-26T01:00:05.000Z')).LocalDateTime
        $act -eq $expected
    }
    Test-Case 'a bumped file mtime does NOT count as activity' {
        # the trap: local indexers/backups touch the file without appending
        $f = New-Fixture 'touched.jsonl' @(
            (Rec-User 'hello' '2026-07-26T01:00:00.000Z' $null),
            (Rec-Assistant 'hi' '2026-07-26T01:00:05.000Z')
        )
        (Get-Item $f).LastWriteTime = (Get-Date).AddMinutes(1)
        $act = Get-TranscriptActivity $f
        $act -lt (Get-Date).AddHours(-1)
    }
    Test-Case 'newest of several real turns wins' {
        $f = New-Fixture 'many.jsonl' @(
            (Rec-User 'first' '2026-07-26T01:00:00.000Z' $null),
            (Rec-Assistant 'a' '2026-07-26T02:00:00.000Z'),
            (Rec-User 'second' '2026-07-26T03:00:00.000Z' $null),
            (Rec-Assistant 'b' '2026-07-26T04:00:00.000Z')
        )
        (Get-TranscriptActivity $f) -eq ([datetimeoffset]::Parse('2026-07-26T04:00:00.000Z')).LocalDateTime
    }
    Test-Case 'transcript with no real turn yields null' {
        $f = New-Fixture 'meta-only.jsonl' @((Rec-Bookkeeping 'away_summary' '2026-07-26T09:00:00.000Z'))
        $null -eq (Get-TranscriptActivity $f)
    }
    Test-Case 'unreadable path yields null instead of throwing' {
        $null -eq (Get-TranscriptActivity (Join-Path $Tmp 'does-not-exist.jsonl'))
    }

    Write-Host '-- preheat: journal rotation --'
    Test-Case 'a journal over 2MB is trimmed to the last 1000 lines + the new one' {
        $LogPath = Join-Path $Tmp 'rot.jsonl'   # shadows the real journal in this scope
        $filler = '{"ev":"x","pad":"' + ('y' * 200) + '"}'
        Set-Content -Path $LogPath -Value (@($filler) * 12000 -join "`n") -Encoding UTF8
        $before = (Get-Item $LogPath).Length
        Write-Log @{ ev = 'test' }
        $lines = @(Get-Content $LogPath)
        ($before -gt 2MB) -and ($lines.Count -eq 1001) -and ($lines[-1] -like '*"ev":"test"*')
    }
}

# ------------------------------------------------------------------ relay.ps1
& {
    . (Join-Path $Repo 'relay.ps1') '__selftest__' 6>$null | Out-Null
    Write-Host ''
    Write-Host '-- relay: session snippet (what the picker shows) --'

    Test-Case 'a plainly typed message (content as a STRING) is found' {
        # regression: the regex only looked for "text" items and was blind to
        # every hand-typed message for a whole day
        $f = New-Fixture 'snip-plain.jsonl' @((Rec-User 'kkk' '2026-07-26T01:00:00.000Z' $null))
        (Get-SessionSnippet $f) -eq 'kkk'
    }
    Test-Case 'a message stored as text items is also found' {
        $f = New-Fixture 'snip-items.jsonl' @((Rec-UserItems 'from items' '2026-07-26T01:00:00.000Z'))
        (Get-SessionSnippet $f) -eq 'from items'
    }
    Test-Case 'the NEWEST real message wins' {
        $f = New-Fixture 'snip-newest.jsonl' @(
            (Rec-User 'older' '2026-07-26T01:00:00.000Z' $null),
            (Rec-Assistant 'reply' '2026-07-26T01:00:05.000Z'),
            (Rec-User 'newer' '2026-07-26T02:00:00.000Z' $null)
        )
        (Get-SessionSnippet $f) -eq 'newer'
    }
    Test-Case 'tool results are never used as the snippet' {
        $f = New-Fixture 'snip-tool.jsonl' @(
            (Rec-User 'real question' '2026-07-26T01:00:00.000Z' $null),
            (Rec-ToolResult 'exit code 0 blah' '2026-07-26T02:00:00.000Z')
        )
        (Get-SessionSnippet $f) -eq 'real question'
    }
    Test-Case 'slash-command dumps and caveats lose to a real message' {
        $f = New-Fixture 'snip-meta.jsonl' @(
            (Rec-User 'my actual ask' '2026-07-26T01:00:00.000Z' $null),
            (Rec-User '# /loop - schedule a recurring prompt' '2026-07-26T02:00:00.000Z' $null),
            (Rec-User 'Caveat: the messages below were generated' '2026-07-26T02:00:01.000Z' $null)
        )
        (Get-SessionSnippet $f) -eq 'my actual ask'
    }
    Test-Case 'when only meta lines exist, a meta line is better than nothing' {
        $f = New-Fixture 'snip-onlymeta.jsonl' @((Rec-User '# /loop - schedule a recurring prompt' '2026-07-26T01:00:00.000Z' $null))
        (Get-SessionSnippet $f).Length -gt 0
    }

    Write-Host '-- relay: transcript cwd --'
    Test-Case 'cwd is extracted and un-escaped' {
        # JSON-escaped path, exactly as a transcript stores it
        $f = New-Fixture 'cwd.jsonl' @((Rec-User 'x' '2026-07-26T01:00:00.000Z' 'C:\\Users\\me\\proj'))
        (Get-SessionCwd $f) -eq 'C:\Users\me\proj'
    }

    Test-Case 'cwd candidates are verified against the transcript bucket' {
        # regression: a session that cd'd mid-way stored the LAST cwd, whose
        # bucket differs from where the transcript lives -> takeover and every
        # relay leg died with "No conversation found"
        $bucketDir = Join-Path $Tmp 'C--x-y'
        New-Item -ItemType Directory -Path $bucketDir -Force | Out-Null
        $p = Join-Path $bucketDir 'b.jsonl'
        Set-Content -Path $p -Value (@(
            (Rec-User 'start' '2026-07-26T01:00:00.000Z' 'C:\\x\\y'),
            (Rec-User 'later' '2026-07-26T02:00:00.000Z' 'C:\\x\\y\\sub')
        ) -join "`n") -Encoding UTF8
        (Get-SessionCwd $p) -eq 'C:\x\y'
    }

    Write-Host '-- relay: stall detection (drives resume vs stand-down) --'
    Test-Case 'ends with a completed assistant reply -> finished' {
        $f = New-Fixture 'tail-fin.jsonl' @(
            (Rec-User 'go' '2026-07-26T01:00:00.000Z' $null),
            (Rec-Assistant 'all done' '2026-07-26T01:00:05.000Z')
        )
        (Get-SessionTailState $f) -eq 'finished'
    }
    Test-Case 'ends mid tool call -> stalled' {
        $f = New-Fixture 'tail-tool.jsonl' @(
            (Rec-User 'go' '2026-07-26T01:00:00.000Z' $null),
            (Rec-AssistantToolUse '2026-07-26T01:00:05.000Z')
        )
        (Get-SessionTailState $f) -eq 'stalled'
    }
    Test-Case 'ends with an unanswered user message -> stalled' {
        $f = New-Fixture 'tail-user.jsonl' @(
            (Rec-Assistant 'previous answer' '2026-07-26T01:00:00.000Z'),
            (Rec-User 'and now this' '2026-07-26T02:00:00.000Z' $null)
        )
        (Get-SessionTailState $f) -eq 'stalled'
    }
    Test-Case 'unreadable transcript -> unknown (treated as stalled upstream)' {
        (Get-SessionTailState (Join-Path $Tmp 'nope.jsonl')) -eq 'unknown'
    }
    Test-Case 'a limit-kill record -> limit, NOT finished (the 07-30 standdown bug)' {
        # regression: this record was classified 'finished', so the sentry
        # stood down on a limit-killed task and the relay never fired
        $f = New-Fixture 'tail-limit.jsonl' @(
            (Rec-User 'go' '2026-07-26T01:00:00.000Z' $null),
            (Rec-AssistantLimit '2026-07-26T02:00:00.000Z')
        )
        (Get-SessionTailState $f) -eq 'limit'
    }
    Test-Case 'bookkeeping piled on after the kill does not hide it' {
        $f = New-Fixture 'tail-limit2.jsonl' @(
            (Rec-User 'go' '2026-07-26T01:00:00.000Z' $null),
            (Rec-AssistantLimit '2026-07-26T02:00:00.000Z'),
            (Rec-Bookkeeping 'attachment' '2026-07-26T02:00:01.000Z'),
            (Rec-Bookkeeping 'turn_duration' '2026-07-26T02:00:02.000Z')
        )
        (Get-SessionTailState $f) -eq 'limit'
    }
    Test-Case 'a real turn AFTER the kill clears the limit state' {
        # the human resumed by hand: the transcript no longer ends at the kill
        $f = New-Fixture 'tail-limit3.jsonl' @(
            (Rec-AssistantLimit '2026-07-26T02:00:00.000Z'),
            (Rec-User 'picked it up myself' '2026-07-26T03:00:00.000Z' $null),
            (Rec-Assistant 'done' '2026-07-26T03:00:05.000Z')
        )
        (Get-SessionTailState $f) -eq 'finished'
    }
    Test-Case 'a normal reply that merely TALKS about limits stays finished' {
        # transcripts around this tool are full of limit words; only the
        # structured error fields may flip the verdict
        $f = New-Fixture 'tail-prose.jsonl' @(
            (Rec-User 'explain' '2026-07-26T01:00:00.000Z' $null),
            (Rec-Assistant 'the usage limit resets at 3pm normally' '2026-07-26T01:00:05.000Z')
        )
        (Get-SessionTailState $f) -eq 'finished'
    }
    Test-Case 'a flood of subagent records after the kill cannot hide it' {
        # parallel subagents drain after a kill: dozens of isSidechain assistant
        # lines land on top of the kill record. Reading one of them as the tail
        # flipped a limit-killed task to 'finished' (the 07-30 bug, sidechain
        # variant) - the verdict must come from the MAIN chain only.
        $lines = @(
            (Rec-User 'go' '2026-07-26T01:00:00.000Z' $null),
            (Rec-AssistantLimit '2026-07-26T02:00:00.000Z')
        )
        foreach ($k in 1..60) { $lines += (Rec-Sidechain "subagent line $k" '2026-07-26T02:00:01.000Z') }
        $f = New-Fixture 'tail-sidechain.jsonl' $lines
        (Get-SessionTailState $f) -eq 'limit'
    }
    Test-Case 'a sidechain reply at the tail does not mask an unanswered user message' {
        $f = New-Fixture 'tail-sidechain2.jsonl' @(
            (Rec-Assistant 'earlier answer' '2026-07-26T01:00:00.000Z'),
            (Rec-User 'now do this' '2026-07-26T02:00:00.000Z' $null),
            (Rec-Sidechain 'subagent finishing up' '2026-07-26T02:00:01.000Z')
        )
        (Get-SessionTailState $f) -eq 'stalled'
    }

    Write-Host '-- relay: fire-time gate (re-judged at the moment of launch) --'
    function Test-FireGateCase([string]$sid, [string[]]$lines) {
        # Resolve-FireGate looks the session up under $env:USERPROFILE - point
        # it at the fixture tree for the duration of one call
        $prev = $env:USERPROFILE
        try {
            $env:USERPROFILE = $Tmp
            $bdir = Join-Path $Tmp '.claude\projects\clr-fg'
            New-Item -ItemType Directory -Path $bdir -Force | Out-Null
            if ($lines) { Set-Content -Path (Join-Path $bdir ($sid + '.jsonl')) -Value ($lines -join "`n") -Encoding UTF8 }
            Resolve-FireGate ([pscustomobject]@{ session = $sid })
        } finally { $env:USERPROFILE = $prev }
    }
    Test-Case 'gate: tail still the kill record -> fire' {
        (Test-FireGateCase 'aaaaaaaa-0000-0000-0000-000000000001' @(
            (Rec-User 'go' '2026-07-26T01:00:00.000Z' $null),
            (Rec-AssistantLimit '2026-07-26T02:00:00.000Z')
        )) -eq 'fire'
    }
    Test-Case 'gate: finished by someone else while we waited -> stand down, not fire' {
        # the hole this closes: human (or the CLI limit-picker auto-continue)
        # resumed and FINISHED the task hours ago - the old code fired anyway
        (Test-FireGateCase 'aaaaaaaa-0000-0000-0000-000000000002' @(
            (Rec-AssistantLimit '2026-07-26T02:00:00.000Z'),
            (Rec-User 'picked it up myself' '2026-07-26T03:00:00.000Z' $null),
            (Rec-Assistant 'all done' '2026-07-26T03:00:05.000Z')
        )) -eq 'finished'
    }
    Test-Case 'gate: cut off mid-flight and long idle -> fire (watch-stall path)' {
        (Test-FireGateCase 'aaaaaaaa-0000-0000-0000-000000000003' @(
            (Rec-Assistant 'earlier' '2026-07-26T01:00:00.000Z'),
            (Rec-User 'unanswered' '2026-07-26T02:00:00.000Z' $null)
        )) -eq 'fire'
    }
    Test-Case 'gate: a real turn minutes ago -> yield (someone is driving)' {
        $freshTs = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        (Test-FireGateCase 'aaaaaaaa-0000-0000-0000-000000000004' @(
            (Rec-User 'still here' $freshTs $null),
            (Rec-Assistant 'on it' $freshTs)
        )) -eq 'yield'
    }
    Test-Case 'gate: transcript gone -> missing (relay cancelled, never fired blind)' {
        (Test-FireGateCase 'aaaaaaaa-0000-0000-0000-000000000005' @()) -eq 'missing'
    }

    Write-Host '-- relay: ratelimit brake (cached resets_at may defer, never trigger) --'
    Test-Case 'resets_at accepts epoch seconds, epoch millis and ISO; garbage -> null' {
        $a = ConvertTo-LocalTime 1786849200
        $b = ConvertTo-LocalTime 1786849200000
        $c = ConvertTo-LocalTime '2026-08-15T23:30:00+08:00'
        $d = ConvertTo-LocalTime 'soon'
        ($a -and $a.Year -eq 2026) -and ($b -eq $a) -and ($c -and $c.Year -eq 2026) -and ($null -eq $d)
    }
    Test-Case 'brake: exhausted bucket + near reset -> defer to that reset' {
        $now = Get-Date
        $rl = [pscustomobject]@{ rate_limits = [pscustomobject]@{ five_hour = [pscustomobject]@{
            utilization = 99.5; resets_at = $now.AddMinutes(40).ToUniversalTime().ToString('o') } } }
        $b = Get-ResetBrakeUntil $rl $now
        $b -and ([Math]::Abs(($b - $now.AddMinutes(40)).TotalMinutes) -lt 1)
    }
    Test-Case 'brake: the live-observed payload shape works (used_percentage + epoch)' {
        # captured live 2026-08-15: {"used_percentage":64,"resets_at":1786849200}
        $now = Get-Date
        $epoch = [DateTimeOffset]::new($now.AddMinutes(30)).ToUnixTimeSeconds()
        $rl = [pscustomobject]@{ rate_limits = [pscustomobject]@{ five_hour = [pscustomobject]@{
            used_percentage = 100; resets_at = $epoch } } }
        $b = Get-ResetBrakeUntil $rl $now
        $b -and ([Math]::Abs(($b - $now.AddMinutes(30)).TotalMinutes) -lt 1)
    }
    Test-Case 'brake: capped at now+2h - garbage can cost one bounded wait, never a deadlock' {
        $now = Get-Date
        $rl = [pscustomobject]@{ rate_limits = [pscustomobject]@{ five_hour = [pscustomobject]@{
            utilization = 100; resets_at = $now.AddHours(7).ToUniversalTime().ToString('o') } } }
        $b = Get-ResetBrakeUntil $rl $now
        $b -and ([Math]::Abs(($b - $now.AddHours(2)).TotalMinutes) -lt 1)
    }
    Test-Case 'brake: a bucket that is not exhausted never brakes' {
        $now = Get-Date
        $rl = [pscustomobject]@{ rate_limits = [pscustomobject]@{ five_hour = [pscustomobject]@{
            used_percentage = 64; resets_at = $now.AddMinutes(40).ToUniversalTime().ToString('o') } } }
        $null -eq (Get-ResetBrakeUntil $rl $now)
    }
    Test-Case 'brake: a reset already in the past, or missing data, never brakes' {
        $now = Get-Date
        $past = [pscustomobject]@{ rate_limits = [pscustomobject]@{ five_hour = [pscustomobject]@{
            utilization = 100; resets_at = $now.AddMinutes(-5).ToUniversalTime().ToString('o') } } }
        ($null -eq (Get-ResetBrakeUntil $past $now)) -and
            ($null -eq (Get-ResetBrakeUntil $null $now)) -and
            ($null -eq (Get-ResetBrakeUntil ([pscustomobject]@{ rate_limits = $null }) $now))
    }

    Write-Host '-- relay: limit detection is CLI-phrase only --'
    Test-Case 'real CLI limit phrases match (corpus web-verified 2026-08-04)' {
        $ok = $true
        foreach ($s in @(
            'Claude usage limit reached. Your limit will reset at 3pm.',
            'Claude AI usage limit reached|1754298000',
            '5-hour limit reached - resets 3pm',
            '5-hour limit reached ∙ resets 5am',
            'Your limit will reset at 10am (America/Los_Angeles)',
            'You''ve hit your session limit · resets 1:40pm (America/Los_Angeles)',
            'You''ve hit your weekly limit · resets Mon 12:00am',
            'You''ve hit your weekly limit · resets May 28 at 7pm (Europe/Madrid)',
            'You''ve hit your Opus limit · resets 3:45pm',
            'You''ve hit your Fable limit · resets Monday',   # synthetic: proves the "limit · resets" net needs no model name and no digit
            'Weekly limit reached ∙ resets 6pm',
            'Opus weekly limit reached ∙ resets Oct 24',
            'You''re out of extra usage. Add more usage credits at: https://claude.ai/settings/usage',
            'Out of usage credits',
            'You are out of extra credits')) {
            if ($s -notmatch $LimitRx) { $ok = $false; Write-Host ('    MISSED: ' + $s) }
        }
        $ok
    }
    Test-Case 'ordinary prose and non-quota errors do NOT match' {
        # we are building limit tooling: the model's own text is full of the
        # word, so the verdict must never come from model prose. And two real
        # CLI messages contain limit-words while NOT being quota exhaustion.
        $ok = $true
        foreach ($s in @(
            'I set a limit of 5 retries in the loop',
            'the rate limiter is configured per session',
            'this limits how many legs can run',
            'API Error: Server is temporarily limiting requests (not your usage limit)',
            'API Error: Usage credits required for 1M context · run /usage-credits to turn them on, or /model to switch to standard context',
            'Approaching weekly limit',
            'Approaching 5-hour limit.',
            'This request would exceed your account''s rate limit. Please try again later.')) {
            if ($s -match $LimitRx) { $ok = $false; Write-Host ('    FALSE HIT: ' + $s) }
        }
        $ok
    }

    Test-Case 'effort inheritance: last assistant tier wins; quoted prose cannot fake it' {
        # arm-time sniff: the transcript records the RESOLVED tier per assistant
        # record (ultracode sessions record plain xhigh). Quoted records inside
        # user/tool lines are \"-escaped and must not fool the scan.
        $f = Join-Path ([System.IO.Path]::GetTempPath()) ('relay-test-effort-' + [guid]::NewGuid().ToString('n') + '.jsonl')
        @(
            '{"type":"assistant","effort":"medium","message":{"content":[]}}',
            '{"type":"user","message":{"content":"log says \"type\":\"assistant\" with \"effort\":\"max\" somewhere"}}',
            '{"type":"assistant","effort":"xhigh","message":{"content":[]}}'
        ) | Set-Content -Path $f -Encoding UTF8
        $r = Get-SessionEffort $f
        Remove-Item $f -ErrorAction SilentlyContinue
        $r -eq 'xhigh'
    }
    Test-Case 'ultracode toggle is restored as-is; a later plain-tier /effort wins instead' {
        # the /effort ultracode switch lands as a user record with a STRING
        # content - the sniffer must return 'ultracode' verbatim (the launch
        # flag accepts it, verified live on 2.1.221), and a later /effort back
        # to a plain tier must fall through to the assistant-record tier
        $f = Join-Path ([System.IO.Path]::GetTempPath()) ('relay-test-ultra-' + [guid]::NewGuid().ToString('n') + '.jsonl')
        @(
            '{"type":"user","message":{"content":"<local-command-stdout>Set effort level to ultracode (this session only): xhigh + dynamic workflow orchestration</local-command-stdout>"}}',
            '{"type":"assistant","effort":"xhigh","message":{"content":[]}}'
        ) | Set-Content -Path $f -Encoding UTF8
        $a = Get-SessionEffort $f
        Add-Content -Path $f -Value '{"type":"user","message":{"content":"<local-command-stdout>Set effort level to xhigh (saved as your default for new sessions)</local-command-stdout>"}}' -Encoding UTF8
        $b = Get-SessionEffort $f
        Remove-Item $f -ErrorAction SilentlyContinue
        ($a -eq 'ultracode') -and ($b -eq 'xhigh')
    }
    Test-Case 'no spawn site hardcodes an effort tier anymore' {
        $r = Get-Content (Join-Path $Repo 'relay.ps1') -Raw -Encoding UTF8
        ($r -match 'function Get-SessionEffort') -and
            ($r -notmatch "--effort high'") -and ($r -notmatch '--effort high"')
    }
    Test-Case 'effort armor: env override scrubbed, print-mode workflow ceiling raised' {
        # CLAUDE_CODE_EFFORT_LEVEL beats --effort and silently disables
        # ultracode orchestration; print mode clips background workflows at
        # ~10 min unless the ceiling is raised (docs: model-config, headless)
        $r = Get-Content (Join-Path $Repo 'relay.ps1') -Raw -Encoding UTF8
        $p = Get-Content (Join-Path $Repo 'panel.ps1') -Raw -Encoding UTF8
        # NO_COLOR: third variable leaked down the same path - a takeover TUI
        # inheriting it renders one flat monochrome wall (observed 08-09)
        ($r -match 'Env:CLAUDE_CODE_EFFORT_LEVEL') -and
            ($p -match 'Env:CLAUDE_CODE_EFFORT_LEVEL') -and
            ($r -match 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS') -and
            ($r -match 'Env:NO_COLOR') -and ($p -match 'Env:NO_COLOR')
    }

    Write-Host '-- relay: armed-state layer --'
    Test-Case 'a .lock.json is never parsed as an armed entry' {
        # regression: *.json matched the lock file too, surfacing a phantom task
        $ArmedDir = Join-Path $Tmp 'armed'
        New-Item -ItemType Directory -Path $ArmedDir -Force | Out-Null
        $sid = '11111111-2222-3333-4444-555555555555'
        @{ session = $sid; mode = 'watch'; legs = 0; maxLegs = 3; cwd = 'C:\x' } | ConvertTo-Json | Set-Content (Join-Path $ArmedDir "$sid.json") -Encoding UTF8
        @{ pid = 4242 } | ConvertTo-Json | Set-Content (Join-Path $ArmedDir "$sid.lock.json") -Encoding UTF8
        $all = @(Get-ArmedAll)
        ($all.Count -eq 1) -and ($all[0].session -eq $sid)
    }
    Test-Case 'relay legs rewrites maxLegs in place without touching the rest' {
        $ArmedDir = Join-Path $Tmp 'armed-legs'
        $LogPath  = Join-Path $Tmp 'legs-log.jsonl'   # shadows the real journal
        New-Item -ItemType Directory -Path $ArmedDir -Force | Out-Null
        $sid = '22222222-3333-4444-5555-666666666666'
        @{ session = $sid; mode = 'wait'; legs = 1; maxLegs = 2; cwd = 'C:\x' } |
            ConvertTo-Json | Set-Content (Join-Path $ArmedDir "$sid.json") -Encoding UTF8
        $Arg = '22222222'; $Arg2 = '4'
        Invoke-SetLegs 6>$null
        $e = Get-Content (Join-Path $ArmedDir "$sid.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        ($e.maxLegs -eq 4) -and ($e.legs -eq 1) -and ($e.mode -eq 'wait')
    }
    Test-Case 'Complete-Entry records the leg summary for the panel' {
        # "what did that leg do all night" must be answerable from the panel
        $ArmedDir = Join-Path $Tmp 'armed-done'
        $DoneDir  = Join-Path $Tmp 'done-done'
        New-Item -ItemType Directory -Path $ArmedDir, $DoneDir -Force | Out-Null
        $sid = '55555555-6666-7777-8888-999999999999'
        $e = [pscustomobject]@{ session = $sid; cwd = 'C:\x' }
        Complete-Entry $e $true 'out.log' 'wrapped everything up'
        $d = Get-Content (Join-Path $DoneDir "$sid.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        ($d.summary -eq 'wrapped everything up') -and ($d.ok -eq $true)
    }
    Test-Case 'an alive leg lock blocks the tick (no double-launch, no false yield)' {
        # regression: the yield guard misread an in-flight leg's own writes as
        # a human taking over and flipped the entry back to watch mid-leg
        $ArmedDir = Join-Path $Tmp 'armed-lock'
        New-Item -ItemType Directory -Path $ArmedDir -Force | Out-Null
        $sid = '33333333-4444-5555-6666-777777777777'
        @{ pid = $PID } | ConvertTo-Json | Set-Content (Join-Path $ArmedDir "$sid.lock.json") -Encoding UTF8
        Test-LegInFlight $sid
    }
    Test-Case 'a stale lock (dead pid) is cleared and does not block' {
        $ArmedDir = Join-Path $Tmp 'armed-lock'
        $sid = '44444444-5555-6666-7777-888888888888'
        # 999999 is not a multiple of 4, so it can never be a real Windows pid
        @{ pid = 999999 } | ConvertTo-Json | Set-Content (Join-Path $ArmedDir "$sid.lock.json") -Encoding UTF8
        (-not (Test-LegInFlight $sid)) -and (-not (Test-Path (Join-Path $ArmedDir "$sid.lock.json")))
    }
    Test-Case 'the wt takeover line carries no raw semicolon' {
        # wt treats ; as its own subcommand separator EVEN INSIDE QUOTES - an
        # inline env-var statement got split into three broken tabs (08-02)
        $relay = Get-Content (Join-Path $Repo 'relay.ps1') -Raw
        $wtLine = (($relay -split "`n") | Where-Object { $_ -match '-w 0 nt -d' }) -join ''
        ($wtLine.Length -gt 0) -and ($wtLine -notmatch ';')
    }
    Test-Case 'legs and takeover force an effort level (headless default is low)' {
        $relay = Get-Content (Join-Path $Repo 'relay.ps1') -Raw
        ([regex]::Matches($relay, '--effort')).Count -ge 3
    }
    Test-Case 'relay legs rejects a count outside 1-9' {
        $ArmedDir = Join-Path $Tmp 'armed-legs'
        $LogPath  = Join-Path $Tmp 'legs-log.jsonl'
        $sid = '22222222-3333-4444-5555-666666666666'
        $Arg = '22222222'; $Arg2 = '99'
        Invoke-SetLegs 6>$null
        $e = Get-Content (Join-Path $ArmedDir "$sid.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $e.maxLegs -eq 4   # unchanged from the previous case
    }
}

# ------------------------------------------------------------------ panel.ps1
Write-Host ''
Write-Host '-- panel: HTTP surface (spare port 7879) --'
$panelPort = 7879
$panelProc = $null
try {
    $shell = 'pwsh'
    if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) { $shell = 'powershell' }
    $panelProc = Start-Process $shell -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Repo 'panel.ps1'),
        '-Port', $panelPort, '-NoBrowser')
    $base = "http://localhost:$panelPort"
    $up = $false
    for ($i = 0; $i -lt 25 -and -not $up; $i++) {
        Start-Sleep -Milliseconds 700
        try { $null = Invoke-WebRequest -Uri "$base/api/status" -UseBasicParsing -TimeoutSec 5; $up = $true } catch { }
    }

    Test-Case 'panel comes up and answers /api/status' { $up }

    Test-Case 'GET / serves the page and forbids caching' {
        # stale cached pages masqueraded as bugs twice, hence the header
        $r = Invoke-WebRequest -Uri "$base/" -UseBasicParsing -TimeoutSec 15
        ($r.StatusCode -eq 200) -and ($r.Content -like '*claude-limit-relay*') -and
            (($r.Headers['Cache-Control'] -join ',') -like '*no-cache*')
    }
    Test-Case 'GET /api/status shapes {preheat:{tasks}, relay:{armed,done}}' {
        $s = (Invoke-WebRequest -Uri "$base/api/status" -UseBasicParsing -TimeoutSec 15).Content | ConvertFrom-Json
        ($null -ne $s.preheat) -and ($null -ne $s.relay) -and
            ($s.preheat.PSObject.Properties['tasks']) -and ($s.relay.PSObject.Properties['armed'])
    }
    Test-Case 'GET /api/sessions returns a JSON array' {
        $raw = (Invoke-WebRequest -Uri "$base/api/sessions" -UseBasicParsing -TimeoutSec 40).Content
        $raw.TrimStart().StartsWith('[')
    }
    Test-Case 'GET /api/schedule returns the parsed config' {
        $s = (Invoke-WebRequest -Uri "$base/api/schedule" -UseBasicParsing -TimeoutSec 15).Content | ConvertFrom-Json
        $null -ne $s.PSObject.Properties['rules']
    }
    Test-Case 'unknown path -> 404' {
        try { $null = Invoke-WebRequest -Uri "$base/nope" -UseBasicParsing -TimeoutSec 15; $false }
        catch { $_.Exception.Response.StatusCode.value__ -eq 404 }
    }

    function Invoke-PanelPost([string]$path, [string]$body, [hashtable]$headers, [string]$contentType) {
        $args = @{ Uri = "$base$path"; Method = 'POST'; Body = $body; UseBasicParsing = $true; TimeoutSec = 30 }
        if ($contentType) { $args.ContentType = $contentType }
        if ($headers) { $args.Headers = $headers }
        try {
            $r = Invoke-WebRequest @args
            return @{ Code = $r.StatusCode; Body = $r.Content }
        } catch {
            $code = 0
            if ($_.Exception.Response) { $code = $_.Exception.Response.StatusCode.value__ }
            return @{ Code = $code; Body = '' }
        }
    }

    Test-Case 'POST without a JSON content type -> 400' {
        (Invoke-PanelPost '/api/relay/arm' '{}' @{ Origin = "http://localhost:$panelPort" } 'text/plain').Code -eq 400
    }
    Test-Case 'POST from a foreign origin -> 403' {
        (Invoke-PanelPost '/api/relay/arm' '{}' @{ Origin = 'http://evil.example' } 'application/json').Code -eq 403
    }
    Test-Case 'POST with a malformed session id -> 400' {
        (Invoke-PanelPost '/api/relay/arm' '{"session":"not-a-uuid"}' @{ Origin = "http://localhost:$panelPort" } 'application/json').Code -eq 400
    }
    Test-Case 'POST /api/relay/dismiss for an unknown session is a harmless 200' {
        $r = Invoke-PanelPost '/api/relay/dismiss' '{"session":"99999999-8888-7777-6666-555555555555"}' @{ Origin = "http://localhost:$panelPort" } 'application/json'
        ($r.Code -eq 200) -and ($r.Body -like '*"ok":true*')
    }
    Test-Case 'POST /api/relay/takeover without a target is refused (never hangs on a picker)' {
        (Invoke-PanelPost '/api/relay/takeover' '{}' @{ Origin = "http://localhost:$panelPort" } 'application/json').Code -eq 400
    }
    Test-Case 'POST /api/relay/legs with a count outside 1-9 -> 400' {
        (Invoke-PanelPost '/api/relay/legs' '{"session":"11111111-2222-3333-4444-555555555555","maxLegs":99}' @{ Origin = "http://localhost:$panelPort" } 'application/json').Code -eq 400
    }
    Test-Case 'GET /api/ratelimits answers a JSON object' {
        $raw = (Invoke-WebRequest -Uri "$base/api/ratelimits" -UseBasicParsing -TimeoutSec 15).Content
        $raw.TrimStart().StartsWith('{')
    }
    Test-Case 'POST /api/preheat/once rejects a hostile value server-side -> 400' {
        # the once endpoint used to trust the body value all the way into the
        # backend command line; a value like  1h\" -Command off  spliced argv
        # tokens through the old Quote-Arg. Rejection must not depend on the
        # browser-side check.
        $bad = '{"kind":"plus","value":"1h\\\" -Command off"}'
        $r1 = Invoke-PanelPost '/api/preheat/once' $bad @{ Origin = "http://localhost:$panelPort" } 'application/json'
        $r2 = Invoke-PanelPost '/api/preheat/once' '{"kind":"at","value":"9am; rm x"}' @{ Origin = "http://localhost:$panelPort" } 'application/json'
        ($r1.Code -eq 400) -and ($r2.Code -eq 400)
    }
} finally {
    if ($panelProc) { try { Stop-Process -Id $panelProc.Id -Force -ErrorAction SilentlyContinue } catch { } }
}

# -------------------------------------------------- statusline tap (node)
Write-Host ''
Write-Host '-- statusline tap --'
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
Test-Case 'tap forwards stdin byte-identical and caches rate_limits beside itself' {
    if (-not $nodeCmd) { Write-Host '    (node not on PATH - skipped)'; return $true }
    $td = Join-Path $Tmp 'tap'
    New-Item -ItemType Directory -Path $td -Force | Out-Null
    Copy-Item (Join-Path $Repo 'statusline-tap.cjs') $td
    $sample = '{"model":{"display_name":"X"},"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1786849200}}}'
    [System.IO.File]::WriteAllText((Join-Path $td 'in.json'), $sample)
    & cmd /c ('"{0}" "{1}" < "{2}" > "{3}"' -f $nodeCmd.Source, (Join-Path $td 'statusline-tap.cjs'), (Join-Path $td 'in.json'), (Join-Path $td 'out.bin'))
    $in  = [System.IO.File]::ReadAllBytes((Join-Path $td 'in.json'))
    $out = [System.IO.File]::ReadAllBytes((Join-Path $td 'out.bin'))
    $state = Join-Path $td 'state-ratelimits.json'
    ($in.Length -eq $out.Length) -and (-not (Compare-Object $in $out)) -and (Test-Path $state) -and
        ((Get-Content $state -Raw -Encoding UTF8 | ConvertFrom-Json).rate_limits.five_hour.used_percentage -eq 12)
}
Test-Case 'tap --solo renders a usage line for users with no statusline of their own' {
    if (-not $nodeCmd) { Write-Host '    (node not on PATH - skipped)'; return $true }
    $td = Join-Path $Tmp 'tap'
    $line = & cmd /c ('"{0}" "{1}" --solo < "{2}"' -f $nodeCmd.Source, (Join-Path $td 'statusline-tap.cjs'), (Join-Path $td 'in.json'))
    ($line -join '') -match '5h 12%'
}
Test-Case 'tap survives non-JSON stdin by forwarding it untouched' {
    if (-not $nodeCmd) { Write-Host '    (node not on PATH - skipped)'; return $true }
    $td = Join-Path $Tmp 'tap'
    [System.IO.File]::WriteAllText((Join-Path $td 'junk.txt'), 'not json at all')
    & cmd /c ('"{0}" "{1}" < "{2}" > "{3}"' -f $nodeCmd.Source, (Join-Path $td 'statusline-tap.cjs'), (Join-Path $td 'junk.txt'), (Join-Path $td 'junk.out'))
    (Get-Content (Join-Path $td 'junk.out') -Raw) -eq 'not json at all'
}

# -------------------------------------------------- doctor & rehearsal (child pwsh)
Write-Host ''
Write-Host '-- doctor & rehearsal --'
$childShell = 'pwsh'
if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) { $childShell = 'powershell' }

Test-Case 'relay doctor runs its checks and prints a summary' {
    # environment-dependent results (warnings are fine) - what must hold is
    # that the check-up itself completes and reports
    $out = & $childShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'relay.ps1') doctor 2>&1 | Out-String
    ($out -match 'claude-limit-relay doctor') -and ($out -match 'doctor: \d+ failure') -and
        ($out -match '\[ OK \]')
}
Test-Case 'relay test rehearses the full chain in a sandbox and passes' {
    # the big one: detect -> gate -> mock leg -> moved-transcript proof ->
    # done record, all against a throwaway sandbox, zero quota
    $out = & $childShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'relay.ps1') test 2>&1 | Out-String
    ($LASTEXITCODE -eq 0) -and ($out -match 'REHEARSAL PASS')
}
Test-Case 'the rehearsal never touches the real scheduler or armed dir' {
    $r = Get-Content (Join-Path $Repo 'relay.ps1') -Raw -Encoding UTF8
    # the sandbox redirect and the scheduler stubs must both be present
    ($r -match 'function Invoke-Rehearsal') -and
        ($r -match 'Set-Item function:script:Register-ProbeTask') -and
        ($r -match 'Set-Item function:script:Unregister-ProbeTask') -and
        ($r -match '\$script:ArmedDir\s*=')
}

# ----------------------------------------------------------------- statics
Write-Host ''
Write-Host '-- static hygiene --'
Test-Case 'no shipped file still carries the old name' {
    # this file is excluded: it necessarily spells the old name to test for it.
    # The glob must cover EVERY text file that ships - the rename once survived
    # for weeks inside schedule.example.json because only ps1/md/html were scanned
    $old = [char]0x69 + 'gnite'
    $paths = @((Join-Path $Repo '*.ps1'), (Join-Path $Repo '*.md'), (Join-Path $Repo '*.json'),
        (Join-Path $Repo '*.vbs'), (Join-Path $Repo 'LICENSE'), (Join-Path $Repo 'web\*.html'))
    # test.ps1 must spell the old name to test for it; schedule.json is the
    # user's untracked personal copy (only schedule.example.json ships)
    $skip = @('test.ps1', 'schedule.json')
    $hits = @(Select-String -Path $paths -Pattern $old -ErrorAction SilentlyContinue |
        Where-Object { (Split-Path $_.Path -Leaf) -notin $skip })
    $hits.Count -eq 0
}
Test-Case 'the page uses plain wording (no musical-string metaphor)' {
    (Get-Content (Join-Path $Repo 'web\index.html') -Raw -Encoding UTF8) -notmatch '弦'
}
Test-Case 'panel page ships bilingual: string table, language toggle, persisted choice' {
    # every user-facing string must come from the I18N table so the header
    # toggle can swap the whole page; the choice persists in localStorage
    $h = Get-Content (Join-Path $Repo 'web\index.html') -Raw -Encoding UTF8
    ($h -match 'var I18N') -and ($h -match "id=`"btnLang`"") -and
        ($h -match 'clr_lang') -and ($h -match 'data-i18n=') -and
        ($h -match 'function t\(')
}
Test-Case 'both scheduled-task registrars keep -WakeToRun (sleep must not eat a fire)' {
    $r = Get-Content (Join-Path $Repo 'relay.ps1') -Raw -Encoding UTF8
    $p = Get-Content (Join-Path $Repo 'preheat.ps1') -Raw -Encoding UTF8
    ($r -match '-WakeToRun') -and ($p -match '-WakeToRun')
}
Test-Case 'the probe launch loop goes through the fire-time gate' {
    # every leg launch must re-judge the transcript at the moment of fire;
    # bypassing Resolve-FireGate reopens the fire-into-finished-work hole
    $r = Get-Content (Join-Path $Repo 'relay.ps1') -Raw -Encoding UTF8
    ($r -match 'function Resolve-FireGate') -and
        ($r -match '\$gate = Resolve-FireGate') -and
        ($r -match "'finished-by-others'") -and
        ($r -match '"isSidechain"')
}
Test-Case 'a leg that exits ok must also prove the transcript moved' {
    # tools in the wild have shipped RESUMED banners while nothing resumed;
    # exit 0 + a result string is not proof - the verdict phase must compare
    # transcript activity against a pre-launch snapshot
    $r = Get-Content (Join-Path $Repo 'relay.ps1') -Raw -Encoding UTF8
    ($r -match 'preAct') -and ($r -match 'transcript did not move')
}
Test-Case 'the panel surfaces the leg summary bilingually' {
    $p = Get-Content (Join-Path $Repo 'panel.ps1') -Raw -Encoding UTF8
    $h = Get-Content (Join-Path $Repo 'web\index.html') -Raw -Encoding UTF8
    ($p -match 'summary') -and ($h -match 'd\.summary') -and
        (([regex]::Matches($h, 'last_reply:')).Count -eq 2)
}
Test-Case 'model-cap park path exists: no-fallback entries freeze instead of burning legs' {
    # quality-critical tasks may refuse the fallback hop - the entry must then
    # park (no pings, no legs) rather than relaunch the dead model
    $r = Get-Content (Join-Path $Repo 'relay.ps1') -Raw -Encoding UTF8
    ($r -match "'model-cap-parked'") -and
        ($r -match "-ne 'watch' -and \`$m -ne 'parked'") -and
        ($r -match "-eq 'parked'")
}
Test-Case 'panel exposes the fallback choice and passes -Fallback through validated' {
    $p = Get-Content (Join-Path $Repo 'panel.ps1') -Raw -Encoding UTF8
    $h = Get-Content (Join-Path $Repo 'web\index.html') -Raw -Encoding UTF8
    ($p -match "'-Fallback'") -and ($p -match 'invalid fallback') -and
        ($h -match 'fbMode') -and ($h -match "'parked'")
}
Test-Case 'Quote-Arg doubles backslash runs before quotes (argv-splice guard)' {
    # Windows argv parsing treats  \"  as an escaped quote: quoting that only
    # escapes the quote itself lets a trailing-backslash value break out of its
    # argument. The panel's quoter must double backslash runs before any quote
    # and before the closing quote.
    $p = Get-Content (Join-Path $Repo 'panel.ps1') -Raw -Encoding UTF8
    $p.Contains('(\\*)"') -and $p.Contains('(\\+)$')
}
Test-Case 'week-grid chips edit in place via the clock picker, committed on blur/Enter' {
    # changing e.g. 10:00 to 10:30 must not require add-new + delete-old.
    # And the editor must NOT commit on `change` - Chromium fires it per
    # keystroke on time inputs, which ejects the user after one digit
    $html = Get-Content (Join-Path $Repo 'web\index.html') -Raw -Encoding UTF8
    ($html -match 'data-edit=') -and ($html -match 'showPicker') -and
        ($html -notmatch 'tedit') -and
        ($html -notmatch "inp\.addEventListener\('change'")
}
Test-Case 'claude spawns are armored against the child-session marker' {
    # a claude that inherits CLAUDE_CODE_CHILD_SESSION silently stops saving
    # transcripts - quota burns, the record never lands (a 34-min takeover
    # session left zero trace, observed live 07-31). Both scripts must scrub
    # the marker, and both interactive/headless resume sites must force
    # persistence.
    $relay = Get-Content (Join-Path $Repo 'relay.ps1') -Raw
    $panel = Get-Content (Join-Path $Repo 'panel.ps1') -Raw
    ($relay -match 'Remove-Item Env:CLAUDE_CODE_CHILD_SESSION') -and
        ($panel -match 'Remove-Item Env:CLAUDE_CODE_CHILD_SESSION') -and
        (([regex]::Matches($relay, 'CLAUDE_CODE_FORCE_SESSION_PERSISTENCE')).Count -ge 3)
}
Test-Case 'every script parses' {
    $ok = $true
    foreach ($f in @('preheat.ps1', 'relay.ps1', 'panel.ps1', 'install.ps1', 'test.ps1')) {
        try { $null = [scriptblock]::Create((Get-Content (Join-Path $Repo $f) -Raw)) } catch { $ok = $false }
    }
    $ok
}
Test-Case 'no PowerShell 7-only syntax (project claims 5.1 support)' {
    $ok = $true
    foreach ($f in @('preheat.ps1', 'relay.ps1', 'panel.ps1', 'install.ps1')) {
        $c = Get-Content (Join-Path $Repo $f) -Raw
        if ($c -match '\?\?' -or $c -match '\)\s*\?\s*[^\s]+\s*:\s') { $ok = $false }
    }
    $ok
}
Test-Case 'the ratelimit brake is wired in and the panel surfaces the cache bilingually' {
    $r = Get-Content (Join-Path $Repo 'relay.ps1') -Raw -Encoding UTF8
    $p = Get-Content (Join-Path $Repo 'panel.ps1') -Raw -Encoding UTF8
    $h = Get-Content (Join-Path $Repo 'web\index.html') -Raw -Encoding UTF8
    ($r -match "= 'brake'") -and ($r -match 'Get-ResetBrakeUntil') -and
        ($p -match '/api/ratelimits') -and ($h -match 'api/ratelimits') -and
        (([regex]::Matches($h, 'rl_5h:')).Count -eq 2)
}
Test-Case 'personal state stays out of git' {
    $ignored = @('schedule.json', 'preheat-log.jsonl', 'relay-log.jsonl', '.claude',
        'state-ratelimits.json', 'statusline-original.json')
    $ok = $true
    foreach ($p in $ignored) {
        git -C $Repo check-ignore $p 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { $ok = $false }
    }
    $ok
}

# ----------------------------------------------------------------- summary
Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -eq 0) {
    Write-Host ('ALL PASS  {0}/{0}' -f $script:Pass) -ForegroundColor Green
    exit 0
}
Write-Host ('{0} passed, {1} FAILED' -f $script:Pass, $script:Fail) -ForegroundColor Red
foreach ($f in $script:Failures) { Write-Host ('  - ' + $f) -ForegroundColor Red }
exit 1
