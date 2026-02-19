# Helper script to create release tag and trigger release.yml
# Usage:
#   .\scripts\create_release.ps1 1.1.0
#   .\scripts\create_release.ps1 v1.1.0
#   .\scripts\create_release.ps1 1.1.0 -NoPush

param(
    [Parameter(Mandatory = $true)]
    [string]$VersionOrTag,
    [switch]$NoPush
)

$ErrorActionPreference = "Stop"

function Fail([string]$message) {
    Write-Host "ERROR: $message" -ForegroundColor Red
    exit 1
}

function Info([string]$message) {
    Write-Host $message -ForegroundColor Cyan
}

$tag = if ($VersionOrTag.StartsWith("v")) { $VersionOrTag } else { "v$VersionOrTag" }

if ($tag -notmatch '^v\d+\.\d+\.\d+([-.][0-9A-Za-z.]+)?$') {
    Fail "Invalid tag: '$tag'. Use format vX.Y.Z (or suffixes -rc.N/-beta.N/-dev.N)."
}

$version = $tag.Substring(1)

if (-not (Test-Path "pubspec.yaml")) {
    Fail "Run this script from repository root (pubspec.yaml not found)."
}

$pubspecVersionLine = Select-String -Path "pubspec.yaml" -Pattern '^version:\s*(.+)$' | Select-Object -First 1
if (-not $pubspecVersionLine) {
    Fail "'version:' field not found in pubspec.yaml."
}
$pubspecVersion = $pubspecVersionLine.Matches[0].Groups[1].Value.Trim()

if ($pubspecVersion -ne $version) {
    Fail "Version mismatch: pubspec.yaml=$pubspecVersion, tag=$tag."
}

if (-not (Test-Path "CHANGELOG.md")) {
    Fail "CHANGELOG.md not found."
}

$changelogEntryPattern = "^## \[$([regex]::Escape($version))\]"
$changelogHasVersion = Select-String -Path "CHANGELOG.md" -Pattern $changelogEntryPattern | Select-Object -First 1
if (-not $changelogHasVersion) {
    Fail "CHANGELOG.md missing section [$version]."
}

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    Fail "Git not found in PATH."
}

$existingTagRaw = git tag --list $tag
$existingTag = if ($null -ne $existingTagRaw) { "$existingTagRaw".Trim() } else { "" }
if ($existingTag -eq $tag) {
    Fail "Tag '$tag' already exists locally."
}

Info "Creating annotated tag: $tag"
git tag -a $tag -m "Release $tag"
if ($LASTEXITCODE -ne 0) {
    Fail "Failed to create tag."
}

if ($NoPush) {
    Write-Host ""
    Write-Host "Tag created locally (no push)." -ForegroundColor Yellow
    Write-Host "To trigger release:" -ForegroundColor Yellow
    Write-Host "  git push origin $tag" -ForegroundColor Gray
    exit 0
}

Info "Pushing tag to origin: $tag"
git push origin $tag
if ($LASTEXITCODE -ne 0) {
    Fail "Failed to push tag to origin."
}

Write-Host ""
Write-Host "Tag pushed successfully: $tag" -ForegroundColor Green
Write-Host "Workflow '.github/workflows/release.yml' should start automatically." -ForegroundColor Green
Write-Host "Track progress at: https://github.com/cesar-carlos/dart_odbc_fast/actions" -ForegroundColor Gray
