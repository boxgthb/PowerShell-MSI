# Compile the pinned source and package it with the restored local WiX pipeline.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SourceBuildPath,
    [string] $SourceDirectory = './source',
    [string] $OutputDirectory = './artifacts'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
if (-not $IsWindows) { throw 'The original WiX MSI pipeline requires Windows.' }
. "$PSScriptRoot/OfficialRelease.ps1"
. "$PSScriptRoot/Disable-MsiOnlineUpdate.ps1"
. "$PSScriptRoot/Package-MsiPayload.ps1"
$automationRoot = (Resolve-Path "$PSScriptRoot/../..").Path
$repoRoot = (Resolve-Path -LiteralPath $SourceDirectory).Path
$metadata = Get-Content -LiteralPath $SourceBuildPath -Raw | ConvertFrom-Json
$versionTag = $metadata.VersionTag
$version = $metadata.Version
if ($versionTag -notmatch '^v\d+\.\d+\.\d+(-(preview|rc)\.\d+)?$' -or $versionTag.Substring(1) -ne $version) { throw 'Invalid resolved source metadata.' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
$null = New-Item -ItemType Directory -Path $output -Force
$payloadDirectory = Join-Path $env:RUNNER_TEMP 'source-built-msi-payload'
$transcriptStarted = $false
Push-Location $repoRoot
try {
    $null = Start-Transcript -Path (Join-Path $output 'build.log')
    $transcriptStarted = $true
    $sourceCommit = (git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $sourceCommit -ne $metadata.SourceCommit) { throw 'The source checkout does not match the pinned source tag.' }
    $automationCommit = (git -C $automationRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $automationCommit -ne $metadata.AutomationCommit) { throw 'The automation checkout does not match the resolver.' }
    $sdkVersion = (Get-Content -LiteralPath ./global.json -Raw | ConvertFrom-Json).sdk.version
    Import-Module ./build.psm1 -Force
    Start-PSBuild -Configuration Release -Runtime win7-x64 -ReleaseTag $versionTag -PSModuleRestore -UseNuGetOrg
    $options = Get-PSOptions
    $publishDirectory = Split-Path $options.Output -Parent
    $pwsh = Join-Path $publishDirectory 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwsh -PathType Leaf)) { throw 'Start-PSBuild did not produce pwsh.exe.' }
    $probe = & $pwsh -NoLogo -NoProfile -Command '[pscustomobject]@{Version=$PSVersionTable.PSVersion.ToString();Edition=$PSVersionTable.PSEdition;Architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()} | ConvertTo-Json -Compress'
    if ($LASTEXITCODE -ne 0) { throw 'The built PowerShell executable cannot start.' }
    $builtVersion = ($probe -join "`n") | ConvertFrom-Json
    if ($builtVersion.Version -ne $version -or $builtVersion.Edition -ne 'Core' -or $builtVersion.Architecture -ne 'X64') { throw 'The built PowerShell version or architecture is incorrect.' }

    Copy-Item -LiteralPath $publishDirectory -Destination $payloadDirectory -Recurse -Force
    Get-ChildItem -LiteralPath $payloadDirectory -Filter '*.pdb' -File -Recurse | Remove-Item -Force
    Copy-Item -LiteralPath ./ThirdPartyNotices.txt -Destination $payloadDirectory -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $payloadDirectory 'en-US') -Force
    Copy-Item -LiteralPath ./assets/default.help.txt -Destination (Join-Path $payloadDirectory 'en-US') -Force
    # This is a source-built payload, so only the current local instrumentation is used.
    if (-not (Test-Path -LiteralPath (Join-Path $payloadDirectory 'RegisterManifest.ps1'))) { throw 'The built Windows payload is missing RegisterManifest.ps1.' }
    $oldMUFile = Join-Path $payloadDirectory 'RegisterMicrosoftUpdate.ps1'
    if (Test-Path -LiteralPath $oldMUFile) { Remove-Item -LiteralPath $oldMUFile -Force }
    $package = New-CommunityMsiPackage -RepositoryRoot $repoRoot -PayloadDirectory $payloadDirectory -Version $version -Framework $options.Framework -OutputDirectory $output
    Copy-Item -LiteralPath $SourceBuildPath -Destination (Join-Path $output 'source-build.json') -Force
    [ordered]@{
        Version = $version
        Tag = $versionTag
        PackagingMode = 'SourceBuild'
        AutomationCommit = $automationCommit
        SourceCommit = $sourceCommit
        SourceRepository = $metadata.SourceRepository
        OriginalMsiRemovalPR = 'https://github.com/PowerShell/PowerShell/pull/27213'
        OriginalMsiSourceCommit = $package.OriginalMsiSourceCommit
        OnlineUpdateIntegration = $false
        DotNetSdk = $sdkVersion
        TargetFramework = $options.Framework
        Runtime = 'win7-x64'
        WixPackage = 'Microsoft.Signed.Wix'
        WixVersion = $package.WixVersion
        WixArchiveSHA256 = $package.WixArchiveSHA256
        MsiProductVersion = $package.MsiProductVersion
        MsiFile = $package.MsiFile
        MsiSHA256 = $package.MsiSHA256
        PayloadFiles = $package.PayloadFiles
        MicrosoftSignedInstaller = $false
        BomPolicy = 'Exact inventory checked by the restored Test-Bom; not a Microsoft-certified SBOM.'
        BuildUrl = "https://github.com/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $output 'provenance.json') -Encoding utf8NoBOM
    Save-MsiArtifactChecksums -Directory $output
    Write-Host "Created $($package.MsiFile) from source commit $sourceCommit."
} finally {
    if ($transcriptStarted) { $null = Stop-Transcript }
    Pop-Location
}
