# Pin the private source tag and the manually selected automation commit.
[CmdletBinding()]
param(
    [string] $VersionTag = '',
    [string] $OutputPath = './resolved/source-build.json',
    [string] $Repository = $env:GITHUB_REPOSITORY
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
. "$PSScriptRoot/OfficialRelease.ps1"
if (-not $Repository) { throw 'The repository must be specified.' }

function Get-LatestRepositoryTag {
    param([Parameter(Mandatory)][string] $Repository)
    $errorFile = Join-Path ([IO.Path]::GetTempPath()) ('source-tags-' + [guid]::NewGuid().ToString('N') + '.log')
    try {
        $names = @(& gh api --paginate "repos/$Repository/tags?per_page=100" --jq '.[].name' 2> $errorFile)
        if ($LASTEXITCODE -ne 0) {
            throw "Cannot list repository tags: $(Get-Content -LiteralPath $errorFile -Raw)"
        }
    } finally {
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }
    $candidates = foreach ($name in $names) {
        $tag = ([string] $name).Trim()
        if ($tag -match '^v(\d+)\.(\d+)\.(\d+)(?:-(preview|rc)\.(\d+))?$') {
            $preKind = if ($Matches.ContainsKey(4)) { [string] $Matches[4] } else { '' }
            $preNumber = if ($Matches.ContainsKey(5)) { [int] $Matches[5] } else { 0 }
            [pscustomobject]@{
                Tag = $tag
                Major = [int] $Matches[1]
                Minor = [int] $Matches[2]
                Patch = [int] $Matches[3]
                PreReleaseRank = if (-not $preKind) { 2 } elseif ($preKind -eq 'rc') { 1 } else { 0 }
                PreReleaseNumber = $preNumber
            }
        }
    }
    $latest = $candidates | Sort-Object Major, Minor, Patch, PreReleaseRank, PreReleaseNumber -Descending | Select-Object -First 1
    if (-not $latest) { throw "No supported version tag exists in $Repository." }
    return $latest.Tag
}

$VersionTag = $VersionTag.Trim()
if (-not $VersionTag) { $VersionTag = Get-LatestRepositoryTag -Repository $Repository }
if ($VersionTag -notmatch '^v\d+\.\d+\.\d+(-(preview|rc)\.\d+)?$') { throw "Unsupported source tag: $VersionTag" }
$automationCommit = (git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $automationCommit -notmatch '^[0-9a-f]{40}$') { throw 'Cannot identify the automation commit.' }
$sourceCommit = Get-GitHubTagCommit -Repository $Repository -Tag $VersionTag
$path = [IO.Path]::GetFullPath($OutputPath)
$null = New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force
[ordered]@{
    Version = $VersionTag.Substring(1)
    VersionTag = $VersionTag
    AutomationCommit = $automationCommit
    SourceCommit = $sourceCommit
    SourceRepository = $Repository
    PrivateTagCommitAtStart = $sourceCommit
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
if ($env:GITHUB_OUTPUT) {
    @("version_tag=$VersionTag", "commit=$automationCommit", "source_commit=$sourceCommit", "private_tag_commit=$sourceCommit") |
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8NoBOM
}
Write-Host "Source tag: $VersionTag; source commit: $sourceCommit; automation commit: $automationCommit"
