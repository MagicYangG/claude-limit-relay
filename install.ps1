# install.ps1 - idempotent setup for claude-preheat
# Safe to re-run: skips steps that are already done.

$ErrorActionPreference = 'Stop'
$repoDir = $PSScriptRoot

Write-Host "claude-preheat install" -ForegroundColor Cyan
Write-Host "repo dir: $repoDir"

# 1) schedule.json from example, if missing
$scheduleFile = Join-Path $repoDir 'schedule.json'
$exampleFile = Join-Path $repoDir 'schedule.example.json'
if (Test-Path $scheduleFile) {
    Write-Host "[skip] schedule.json already exists"
} else {
    if (Test-Path $exampleFile) {
        Copy-Item $exampleFile $scheduleFile
        Write-Host "[ok] created schedule.json from schedule.example.json"
    } else {
        Write-Warning "schedule.example.json not found, cannot create schedule.json"
    }
}

# 2) append functions to the CurrentUserAllHosts profile, guarded by marker comment
# (writing here instead of $PROFILE so the functions load for every host, not just
# whichever shell happens to run this installer)
$profilePath = $PROFILE.CurrentUserAllHosts
$markerBegin = '# >>> claude-preheat functions >>>'
$markerEnd = '# <<< claude-preheat functions <<<'
# v0.2 block markers: that block also defined a relay function whose script no
# longer ships, so migration must remove the whole old block
$oldMarkerBegin = '# >>> claude-limit-relay functions >>>'
$oldMarkerEnd = '# <<< claude-limit-relay functions <<<'

if (-not (Test-Path $profilePath)) {
    $profileDir = Split-Path $profilePath -Parent
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }
    New-Item -ItemType File -Path $profilePath -Force | Out-Null
}

$profileContent = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
if ($null -eq $profileContent) { $profileContent = '' }

$preheatPath = Join-Path $repoDir 'preheat.ps1'
$panelPath = Join-Path $repoDir 'panel.ps1'

$block = @()
$block += $markerBegin
$block += "function preheat { & '$preheatPath' @args }"
$block += "function claude-panel { & '$panelPath' @args }"
$block += $markerEnd
$blockText = $block -join "`r`n"

$hasOld = $profileContent.Contains($oldMarkerBegin)
$markerPattern = [regex]::Escape($markerBegin) + '(?s).*?' + [regex]::Escape($markerEnd)
$existingMatch = [regex]::Match($profileContent, $markerPattern)

# skip only when the existing block is byte-identical to what we would write:
# comparing just the script path here once made content-only upgrades no-ops
if ($existingMatch.Success -and $existingMatch.Value -eq $blockText -and -not $hasOld) {
    Write-Host "[skip] $profilePath already has current claude-preheat functions"
} else {
    $backupPath = "$profilePath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $profilePath $backupPath -ErrorAction SilentlyContinue
    if (Test-Path $backupPath) {
        Write-Host "[ok] backed up $profilePath to $backupPath"
    }

    if ($hasOld) {
        # v0.2 -> v0.3: strip the old block so upgraders never end up with both
        $oldPattern = [regex]::Escape($oldMarkerBegin) + '(?s).*?' + [regex]::Escape($oldMarkerEnd)
        $profileContent = [regex]::Replace($profileContent, $oldPattern, '')
        $existingMatch = [regex]::Match($profileContent, $markerPattern)
    }

    if ($existingMatch.Success) {
        $before = $profileContent.Substring(0, $existingMatch.Index)
        $after = $profileContent.Substring($existingMatch.Index + $existingMatch.Length)
        Set-Content -Path $profilePath -Value ($before + $blockText + $after) -NoNewline
        Write-Host "[ok] updated claude-preheat functions in $profilePath"
    } elseif ($hasOld) {
        Set-Content -Path $profilePath -Value $profileContent -NoNewline
        Add-Content -Path $profilePath -Value "`r`n$blockText`r`n"
        Write-Host "[ok] replaced v0.2 claude-limit-relay block with claude-preheat functions in $profilePath"
    } else {
        Add-Content -Path $profilePath -Value "`r`n$blockText`r`n"
        Write-Host "[ok] appended preheat / claude-panel functions to $profilePath"
    }
}

# 3) v0.2 -> v0.3 cleanup: relay is gone (claude CLI >= 2.1.234 auto-continues
# at limit reset natively). Only the relay probe task is ours to remove here -
# ClaudePreheat-* tasks are live and stay untouched.
$probeTask = Get-ScheduledTask -TaskName 'ClaudeRelay-Probe' -ErrorAction SilentlyContinue
if ($probeTask) {
    Unregister-ScheduledTask -TaskName 'ClaudeRelay-Probe' -Confirm:$false
    Write-Host "[ok] removed v0.2 scheduled task ClaudeRelay-Probe"
}
$legacyJson = @(Get-ChildItem -Path (Join-Path $repoDir 'armed'), (Join-Path $repoDir 'done') -Filter *.json -ErrorAction SilentlyContinue)
if ($legacyJson.Count -gt 0) {
    Write-Host "[note] armed\ and done\ hold v0.2 relay leftovers - inert now, safe to delete"
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Edit schedule.json to your own weekly rules"
Write-Host "  2. Reload profile: . '$profilePath'   (or open a new terminal)"
Write-Host "  3. Run: preheat apply"
Write-Host "  4. Run: claude-panel   (opens the local status page)"
Write-Host "  Optional: preheat statusline on   (feeds the panel's live quota strip)"
