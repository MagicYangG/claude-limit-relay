# install.ps1 - idempotent setup for claude-limit-relay
# Safe to re-run: skips steps that are already done.

$ErrorActionPreference = 'Stop'
$repoDir = $PSScriptRoot

Write-Host "claude-limit-relay install" -ForegroundColor Cyan
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
$markerBegin = '# >>> claude-limit-relay functions >>>'
$markerEnd = '# <<< claude-limit-relay functions <<<'

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
$relayPath = Join-Path $repoDir 'relay.ps1'
$panelPath = Join-Path $repoDir 'panel.ps1'

$block = @()
$block += $markerBegin
$block += "function preheat { & '$preheatPath' @args }"
$block += "function relay { & '$relayPath' @args }"
$block += "function claude-panel { & '$panelPath' @args }"
$block += $markerEnd
$blockText = $block -join "`r`n"

$hasMarker = $profileContent.Contains($markerBegin)
$existingMatch = $null
$sameRepo = $false
if ($hasMarker) {
    $markerPattern = [regex]::Escape($markerBegin) + '(?s).*?' + [regex]::Escape($markerEnd)
    $existingMatch = [regex]::Match($profileContent, $markerPattern)
    if ($existingMatch.Success -and $existingMatch.Value.Contains($preheatPath)) {
        $sameRepo = $true
    }
}

if ($hasMarker -and $sameRepo) {
    Write-Host "[skip] $profilePath already has claude-limit-relay functions"
} else {
    $backupPath = "$profilePath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $profilePath $backupPath -ErrorAction SilentlyContinue
    if (Test-Path $backupPath) {
        Write-Host "[ok] backed up $profilePath to $backupPath"
    }

    if ($hasMarker -and $existingMatch.Success) {
        $before = $profileContent.Substring(0, $existingMatch.Index)
        $after = $profileContent.Substring($existingMatch.Index + $existingMatch.Length)
        Set-Content -Path $profilePath -Value ($before + $blockText + $after) -NoNewline
        Write-Host "[ok] updated claude-limit-relay functions in $profilePath (repo path had changed)"
    } else {
        Add-Content -Path $profilePath -Value "`r`n$blockText`r`n"
        Write-Host "[ok] appended preheat / relay / claude-panel functions to $profilePath"
    }
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Edit schedule.json to your own weekly rules"
Write-Host "  2. Reload profile: . '$profilePath'   (or open a new terminal)"
Write-Host "  3. Run: preheat apply"
Write-Host "  4. Run: claude-panel   (opens the local status page)"
