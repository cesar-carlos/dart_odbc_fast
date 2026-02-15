param(
  [string]$RepoRoot = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Push-Location $RepoRoot
try {
  $blockers = @()

  Write-Host "== Check: references to doc/issues outside doc/issues =="
  $refs = @()
  try {
      $refsRaw = rg -n "doc/issues" -S `
      --glob "!doc/issues/**" `
      --glob "!scripts/check_issues_deletion_readiness.ps1" `
      --glob "!doc/notes/ISSUES_FOLDER_DELETION_CHECKLIST.md"
      if ($LASTEXITCODE -eq 0 -and $refsRaw) {
      $refs = @($refsRaw -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
      }
  } catch {
    $blockers += "Failed to execute ripgrep (rg) for references check."
  }

  if ($refs.Count -gt 0) {
    $blockers += "Found references to doc/issues outside doc/issues."
    $refs | ForEach-Object { Write-Host "  $_" }
  } else {
    Write-Host "  OK: no external references found."
  }

  if (Test-Path "doc/issues") {
    Write-Host "`n== Check: pending statuses in doc/issues =="
    $pending = @()
    try {
      $pendingRaw = rg -n "Partial|Complete with limitation|In progress|Out of scope|Pending" `
        doc/issues/IMPLEMENTATION_STATUS.md `
        doc/issues/ROADMAP.md `
        doc/issues/api
      if ($LASTEXITCODE -eq 0 -and $pendingRaw) {
        $pending = @($pendingRaw -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
      }
    } catch {
      $blockers += "Failed to parse pending statuses in doc/issues."
    }

    if ($pending.Count -gt 0) {
      $blockers += "Found pending/non-final statuses in doc/issues."
      $pending | ForEach-Object { Write-Host "  $_" }
    } else {
      Write-Host "  OK: no pending statuses found in doc/issues."
    }
  } else {
    Write-Host "`n== Check: doc/issues directory =="
    Write-Host "  INFO: doc/issues does not exist."
  }

  Write-Host "`n== Result =="
  if ($blockers.Count -eq 0) {
    Write-Host "READY: safe to delete doc/issues."
    exit 0
  }

  Write-Host "NOT READY:"
  $blockers | ForEach-Object { Write-Host " - $_" }
  exit 1
}
finally {
  Pop-Location
}
