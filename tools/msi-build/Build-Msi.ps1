# Package official PowerShell ZIP files without recompiling the payload.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $OfficialReleasePath,
    [string] $OutputDirectory = './artifacts'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
if (-not $IsWindows) { throw 'The original WiX MSI pipeline requires Windows.' }
. "$PSScriptRoot/OfficialRelease.ps1"
. "$PSScriptRoot/Disable-MsiOnlineUpdate.ps1"
. "$PSScriptRoot/Package-MsiPayload.ps1"
$repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
$metadata = Get-Content -LiteralPath $OfficialReleasePath -Raw | ConvertFrom-Json
$version = $metadata.Version
$versionTag = $metadata.VersionTag
if ($versionTag -notmatch '^v\d+\.\d+\.\d+(-(preview|rc)\.\d+)?$' -or $versionTag.Substring(1) -ne $version) { throw 'Invalid resolved release metadata.' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
$null = New-Item -ItemType Directory -Path $output -Force
$payloadDirectory = Join-Path $env:RUNNER_TEMP 'official-zip-payload'
$downloadDirectory = Join-Path $env:RUNNER_TEMP 'official-zip-download'
$transcriptStarted = $false
Push-Location $repoRoot
try {
    $null = Start-Transcript -Path (Join-Path $output 'build.log')
    $transcriptStarted = $true
    $sourceCommit = (git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $sourceCommit -ne $metadata.AutomationCommit) { throw 'The automation checkout does not match the resolver.' }
    $archive = Receive-VerifiedOfficialAsset -Asset $metadata.ZIP -Directory $downloadDirectory
    Expand-Archive -LiteralPath $archive -DestinationPath $payloadDirectory -Force
    foreach ($required in @('pwsh.exe', 'pwsh.runtimeconfig.json', 'RegisterManifest.ps1', 'LICENSE.txt', 'ThirdPartyNotices.txt')) {
        if (-not (Test-Path -LiteralPath (Join-Path $payloadDirectory $required))) { throw "Official ZIP is missing $required." }
    }
    $framework = (Get-Content -LiteralPath (Join-Path $payloadDirectory 'pwsh.runtimeconfig.json') -Raw | ConvertFrom-Json).runtimeOptions.tfm
    $originalFiles = @(Get-MsiPayloadInventory -Root $payloadDirectory)
    $originalFiles | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $output 'official-files-sha256.json') -Encoding utf8NoBOM
    $signatures = @(foreach ($file in @('pwsh.exe', 'System.Management.Automation.dll')) {
        $signature = Get-AuthenticodeSignature -FilePath (Join-Path $payloadDirectory $file)
        $subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' }
        $thumbprint = if ($signature.SignerCertificate) { $signature.SignerCertificate.Thumbprint } else { '' }
        if ($file -eq 'pwsh.exe' -and ($signature.Status -ne 'Valid' -or $subject -notmatch 'Microsoft')) { throw 'The official pwsh.exe must have a valid Microsoft Authenticode signature.' }
        if ($signature.SignerCertificate -and $signature.Status -ne 'Valid') { throw "Invalid official signature on ${file}: $($signature.Status)" }
        [ordered]@{ Path = $file; Status = [string] $signature.Status; SignerSubject = $subject; SignerThumbprint = $thumbprint }
    })
    $signatures | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $output 'official-signatures.json') -Encoding utf8NoBOM
    $package = New-CommunityMsiPackage -RepositoryRoot $repoRoot -PayloadDirectory $payloadDirectory -Version $version -Framework $framework -OutputDirectory $output
    # The shared packager has checked the complete staged payload; independently
    # match each original ZIP file against that payload inventory.
    $staged = Get-Content -LiteralPath (Join-Path $output 'payload-sha256.json') -Raw | ConvertFrom-Json
    $stagedByPath = @{}
    foreach ($file in $staged) { $stagedByPath[$file.Path] = $file.SHA256 }
    foreach ($file in $originalFiles) {
        if ($stagedByPath[$file.Path] -ne $file.SHA256) { throw "Official ZIP file was modified or lost: $($file.Path)" }
    }
    Copy-Item -LiteralPath $OfficialReleasePath -Destination (Join-Path $output 'official-zip.json') -Force
    [ordered]@{
        Version = $version
        Tag = $versionTag
        PackagingMode = 'OfficialZIP'
        AutomationCommit = $sourceCommit
        SourceCommit = $sourceCommit
        SourceRepository = $env:GITHUB_REPOSITORY
        OfficialZipURL = $metadata.ZIP.URL
        OfficialZipSHA256 = $metadata.ZIP.SHA256
        OfficialReleaseCommit = $metadata.ZIP.OfficialCommit
        OfficialPayloadFiles = $originalFiles.Count
        OriginalFilesPreserved = $true
        OriginalMsiRemovalPR = 'https://github.com/PowerShell/PowerShell/pull/27213'
        OriginalMsiSourceCommit = $package.OriginalMsiSourceCommit
        OnlineUpdateIntegration = $false
        TargetFramework = $framework
        Runtime = 'win-x64'
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
    Write-Host "Created $($package.MsiFile); all $($originalFiles.Count) official ZIP files are unchanged."
} finally {
    if ($transcriptStarted) { $null = Stop-Transcript }
    Pop-Location
}
