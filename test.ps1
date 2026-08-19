#Requires -Version 5.1
<#
claude-preheat self-test: preheat scheduling, the local panel, the statusline tap.

Run:  ./test.ps1            (add -Verbose for per-case detail)
Exit: 0 = all passed, 1 = at least one failure.

Costs nothing and touches nothing that matters:
  - no `claude` call, so zero quota and no usage window is anchored
  - schedule.json, the real journal and the registered scheduled tasks are
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
    # a plainly typed message stores content as a STRING, not as text items
    $c = '{"type":"user","message":{"role":"user","content":"' + $text + '"},"timestamp":"' + $tsUtc + '"'
    if ($cwd) { $c += ',"cwd":"' + $cwd + '"' }
    $c + '}'
}
function Rec-Assistant([string]$text, [string]$tsUtc) {
    '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"' + $text + '"}]},"timestamp":"' + $tsUtc + '"}'
}
function Rec-Bookkeeping([string]$subtype, [string]$tsUtc) {
    # Claude Code appends these to an OPEN-BUT-IDLE session: no API call happened
    if ($subtype -eq 'attachment') { return '{"type":"attachment","timestamp":"' + $tsUtc + '"}' }
    '{"type":"system","subtype":"' + $subtype + '","timestamp":"' + $tsUtc + '"}'
}

Write-Host ''
Write-Host '=== claude-preheat self-test ===' -ForegroundColor Cyan

# ---------------------------------------------------------------- preheat.ps1
# dot-source inside its own scope so its helpers stay out of the top scope;
# '__selftest__' falls through to the usage branch
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

    Write-Host '-- preheat: learn (windows, suggestions, utilization) --'
    Test-Case 'window reconstruction: prompts inside 5h ride one window, later ones anchor anew' {
        $base = (Get-Date).Date.AddDays(-3).AddHours(9)
        $wins = @(Get-WindowStats @($base, $base.AddHours(1), $base.AddHours(4), $base.AddHours(6)))
        ($wins.Count -eq 2) -and ($wins[0].anchor -eq $base) -and
            ($wins[0].last -eq $base.AddHours(4)) -and ($wins[1].anchor -eq $base.AddHours(6))
    }
    Test-Case 'learn report: median start -> reset suggestion, and 7-day utilization' {
        # two windows exactly 7 days apart (same weekday by construction):
        # medians 09:00/09:00 -> suggest 10:00; only the recent one counts for
        # utilization: engaged 1.5h + 0.5h grace of 5h = 40%
        $a1 = (Get-Date).Date.AddDays(-10).AddHours(9)
        $a2 = $a1.AddDays(7)
        $rep = Get-LearnReport @($a1, $a1.AddHours(1), $a2, $a2.AddHours(1.5)) (Get-Date)
        $day = @($rep.days | Where-Object { $_.samples -eq 2 })
        ($day.Count -eq 1) -and ($day[0].suggest -eq '10:00') -and
            ($rep.waste.windows -eq 1) -and ($rep.waste.usedPct -eq 40)
    }
    Test-Case 'a single observed window per weekday yields no suggestion (need >=2)' {
        $a1 = (Get-Date).Date.AddDays(-3).AddHours(9)
        $rep = Get-LearnReport @($a1, $a1.AddHours(1)) (Get-Date)
        ($rep.days.Count -eq 1) -and ($null -eq $rep.days[0].suggest)
    }
    Test-Case 'a start near midnight carries the suggested reset to the NEXT weekday' {
        # regression (review 2026-08-15): median 23:20 + 1h wraps to 00:30 but
        # kept the same weekday, so the rule fired a full day early and the
        # preheated window was ~23h dead before the user sat down
        $a1 = (Get-Date).Date.AddDays(-10).AddHours(23).AddMinutes(20)
        $a2 = $a1.AddDays(7)
        $rep = Get-LearnReport @($a1, $a1.AddMinutes(30), $a2, $a2.AddMinutes(30)) (Get-Date)
        $day = @($rep.days | Where-Object { $_.samples -eq 2 })
        $expectNext = @('Mon','Tue','Wed','Thu','Fri','Sat','Sun')
        $ix = [array]::IndexOf($expectNext, $a1.DayOfWeek.ToString().Substring(0,3))
        ($day.Count -eq 1) -and ($day[0].suggest -eq '00:30') -and
            ($day[0].suggestDay -eq $expectNext[(($ix + 1) % 7)])
    }
    Test-Case 'history parsing: epoch-ms lines in range count, old and junk lines do not' {
        $prev = $env:USERPROFILE
        try {
            $env:USERPROFILE = $Tmp
            $hd = Join-Path $Tmp '.claude'
            New-Item -ItemType Directory -Path $hd -Force | Out-Null
            $ms = { param($d) [DateTimeOffset]::new($d).ToUnixTimeMilliseconds() }
            @(
                ('{"display":"x","timestamp":' + (& $ms (Get-Date).AddDays(-2)) + ',"project":"p"}'),
                ('{"display":"y","timestamp":' + (& $ms (Get-Date).AddDays(-1)) + ',"project":"p"}'),
                ('{"display":"old","timestamp":' + (& $ms (Get-Date).AddDays(-35)) + ',"project":"p"}'),
                'not json at all'
            ) | Set-Content -Path (Join-Path $hd 'history.jsonl') -Encoding UTF8
            $st = Get-HistoryTimestamps 30
            $st.Count -eq 2
        } finally { $env:USERPROFILE = $prev }
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
        ($r.StatusCode -eq 200) -and ($r.Content -like '*claude-preheat*') -and
            (($r.Headers['Cache-Control'] -join ',') -like '*no-cache*')
    }
    Test-Case 'GET /api/status shapes {preheat:{tasks}}' {
        $s = (Invoke-WebRequest -Uri "$base/api/status" -UseBasicParsing -TimeoutSec 15).Content | ConvertFrom-Json
        ($null -ne $s.preheat) -and ($s.preheat.PSObject.Properties['tasks'])
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
        (Invoke-PanelPost '/api/preheat/once' '{}' @{ Origin = "http://localhost:$panelPort" } 'text/plain').Code -eq 400
    }
    Test-Case 'POST from a foreign origin -> 403' {
        (Invoke-PanelPost '/api/preheat/once' '{}' @{ Origin = 'http://evil.example' } 'application/json').Code -eq 403
    }
    Test-Case 'GET /api/ratelimits answers a JSON object' {
        $raw = (Invoke-WebRequest -Uri "$base/api/ratelimits" -UseBasicParsing -TimeoutSec 15).Content
        $raw.TrimStart().StartsWith('{')
    }
    Test-Case 'GET /api/learn answers the rhythm report (shell-out, cached)' {
        $s = (Invoke-WebRequest -Uri "$base/api/learn" -UseBasicParsing -TimeoutSec 60).Content | ConvertFrom-Json
        $null -ne $s.PSObject.Properties['days']
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
    # code point instead of the literal CJK char: keeps this file pure ASCII
    (Get-Content (Join-Path $Repo 'web\index.html') -Raw -Encoding UTF8) -notmatch ([string][char]0x5F26)
}
Test-Case 'panel page ships bilingual: string table, language toggle, persisted choice' {
    # every user-facing string must come from the I18N table so the header
    # toggle can swap the whole page; the choice persists in localStorage
    $h = Get-Content (Join-Path $Repo 'web\index.html') -Raw -Encoding UTF8
    ($h -match 'var I18N') -and ($h -match "id=`"btnLang`"") -and
        ($h -match 'clr_lang') -and ($h -match 'data-i18n=') -and
        ($h -match 'function t\(')
}
Test-Case 'the scheduled-task registrar keeps -WakeToRun (sleep must not eat a fire)' {
    (Get-Content (Join-Path $Repo 'preheat.ps1') -Raw -Encoding UTF8) -match '-WakeToRun'
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
Test-Case 'the panel scrubs the child-session marker before spawning' {
    # a claude that inherits CLAUDE_CODE_CHILD_SESSION silently stops saving
    # transcripts - quota burns, the record never lands (observed live 07-31);
    # the pings preheat.ps1 spawns under the panel must start from a clean env
    (Get-Content (Join-Path $Repo 'panel.ps1') -Raw) -match 'Remove-Item Env:CLAUDE_CODE_CHILD_SESSION'
}
Test-Case 'every shipped script carries a UTF-8 BOM (5.1 decodes BOM-less as ANSI)' {
    # without the BOM, Windows PowerShell 5.1 reads these files through the
    # legacy codepage: on cp936 the middle-dot chars in comments/corpus turn
    # to mojibake, and a bare [] class once became an invalid regex
    $ok = $true
    foreach ($f in @('preheat.ps1', 'panel.ps1', 'install.ps1', 'test.ps1')) {
        $b = [System.IO.File]::ReadAllBytes((Join-Path $Repo $f))
        if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) { $ok = $false }
    }
    $ok
}
Test-Case 'every ExitCode-reading Start-Process touches .Handle first (PS 5.1 null trap)' {
    # 5.1 returns a process object whose ExitCode stays null forever unless
    # .Handle was read before the process exits - every ping/backend spawn
    # whose ExitCode we judge must carry the touch
    $ok = $true
    foreach ($f in @('preheat.ps1', 'panel.ps1')) {
        $c = Get-Content (Join-Path $Repo $f) -Raw -Encoding UTF8
        if (([regex]::Matches($c, '\$null = \$p\.Handle')).Count -lt 1) { $ok = $false }
    }
    $ok
}
Test-Case 'statusline on/off consult BOTH settings files and the sidecar path' {
    # regression (review 2026-08-15): off re-derived "the file with a
    # statusLine, local first" and went no-op when the tap sat in the other
    # file; on could then double-wrap and clobber the sidecar
    $r = Get-Content (Join-Path $Repo 'preheat.ps1') -Raw -Encoding UTF8
    ($r -match '\$candFiles') -and ($r -match '\$tapFile') -and
        ($r -match 'sc\.file') -and ($r -match 'already installed \(in')
}
Test-Case 'every script parses' {
    $ok = $true
    foreach ($f in @('preheat.ps1', 'panel.ps1', 'install.ps1', 'test.ps1')) {
        try { $null = [scriptblock]::Create((Get-Content (Join-Path $Repo $f) -Raw)) } catch { $ok = $false }
    }
    $ok
}
Test-Case 'no PowerShell 7-only syntax (project claims 5.1 support)' {
    $ok = $true
    foreach ($f in @('preheat.ps1', 'panel.ps1', 'install.ps1')) {
        $c = Get-Content (Join-Path $Repo $f) -Raw
        if ($c -match '\?\?' -or $c -match '\)\s*\?\s*[^\s]+\s*:\s') { $ok = $false }
    }
    $ok
}
Test-Case 'learn ships end to end: preheat command, panel endpoint, bilingual line' {
    $pre = Get-Content (Join-Path $Repo 'preheat.ps1') -Raw -Encoding UTF8
    $pan = Get-Content (Join-Path $Repo 'panel.ps1') -Raw -Encoding UTF8
    $h = Get-Content (Join-Path $Repo 'web\index.html') -Raw -Encoding UTF8
    ($pre -match "'\^learn\$'") -and ($pan -match '/api/learn') -and
        (([regex]::Matches($h, 'learn_waste:')).Count -eq 2)
}
Test-Case 'the panel surfaces the ratelimit cache bilingually' {
    $p = Get-Content (Join-Path $Repo 'panel.ps1') -Raw -Encoding UTF8
    $h = Get-Content (Join-Path $Repo 'web\index.html') -Raw -Encoding UTF8
    ($p -match '/api/ratelimits') -and ($h -match 'api/ratelimits') -and
        (([regex]::Matches($h, 'rl_5h:')).Count -eq 2)
}
Test-Case 'personal state stays out of git' {
    $ignored = @('schedule.json', 'preheat-log.jsonl', '.claude',
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
