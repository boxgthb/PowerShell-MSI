# Resolve an official ZIP URL; blank input selects the latest stable release.
[CmdletBinding()]
param(
    [string] $ZipURL,
    [string] $OutputPath = './resolved/official-zip.json',
    [string] $Repository = $env:GITHUB_REPOSITORY
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
. "$PSScriptRoot/OfficialRelease.ps1"
$path = [IO.Path]::GetFullPath($OutputPath)
$null = New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force
$asset = Get-OfficialZipRequest -ZipURL $ZipURL -CacheDirectory (Join-Path (Split-Path $path -Parent) 'checksum-cache')
$commit = (git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') { throw 'Cannot identify the automation commit.' }
if (-not $Repository) { throw 'The private repository must be specified.' }
$privateTagCommit = Get-GitHubTagCommit -Repository $Repository -Tag $asset.Tag -AllowMissing
[ordered]@{
    Version = $asset.Version
    VersionTag = $asset.Tag
    AutomationCommit = $commit
    PrivateTagCommitAtStart = $privateTagCommit
    ZIP = $asset
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
if ($env:GITHUB_OUTPUT) {
    @("version_tag=$($asset.Tag)", "commit=$commit", "private_tag_commit=$privateTagCommit") |
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8NoBOM
}
Write-Host "Selected $($asset.URL)"
Write-Host "Official SHA256: $($asset.SHA256)"
Write-Host "Official release commit: $($asset.OfficialCommit)"
Write-Host "Automation commit: $commit"
