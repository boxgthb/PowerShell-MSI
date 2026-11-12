# Community MSI adapter. PowerShell application source remains unchanged.
# Licensed under the MIT License (see the repository LICENSE.txt).
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^v\d+\.\d+\.\d+(-(preview|rc)\.\d+)?$')]
    [string] $VersionTag,
    [string] $OutputDirectory = './artifacts'
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'The original WiX MSI pipeline requires Windows.' }
$repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
$version = $VersionTag.Substring(1)
$legacyCommit = '767990ba06f8579d69f99eec46057541374aa892' # Official v7.6.0
$upstreamUrl = 'https://github.com/PowerShell/PowerShell.git'
$output = [IO.Path]::GetFullPath($OutputDirectory)
$null = New-Item -ItemType Directory -Path $output -Force
$legacyDirectory = Join-Path $env:RUNNER_TEMP 'official-msi-reference'
$payloadDirectory = Join-Path $env:RUNNER_TEMP 'community-msi-payload'
$transcriptStarted = $false
$referenceAdded = $false
Push-Location $repoRoot
try {
    Start-Transcript -Path (Join-Path $output 'build.log')
    $transcriptStarted = $true
    $sourceCommit = (git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify the source commit.' }
    $sdkVersion = (Get-Content ./global.json -Raw | ConvertFrom-Json).sdk.version

    # No authenticated Microsoft feeds or signing secrets are required.
    Import-Module ./build.psm1 -Force
    Start-PSBuild -Configuration Release -Runtime win7-x64 -ReleaseTag $VersionTag -PSModuleRestore -UseNuGetOrg
    $options = Get-PSOptions
    $publishDirectory = Split-Path $options.Output -Parent
    if (-not (Test-Path "$publishDirectory/pwsh.exe")) { throw 'Start-PSBuild did not produce pwsh.exe.' }
    & "$publishDirectory/pwsh.exe" -NoLogo -NoProfile -Command '$PSVersionTable | Out-String | Write-Host'
    if ($LASTEXITCODE -ne 0) { throw 'The built PowerShell executable cannot start.' }

    # Restore only MSI packaging assets, at build time, from a pinned official commit.
    # Never fetch upstream tags over the private, re-tagged version names.
    git fetch --no-tags $upstreamUrl $legacyCommit
    if ($LASTEXITCODE -ne 0) { throw 'Cannot fetch the pinned original MSI implementation.' }
    git worktree add --detach $legacyDirectory $legacyCommit
    if ($LASTEXITCODE -ne 0) { throw 'Cannot create the official MSI reference worktree.' }
    $referenceAdded = $true
    Copy-Item "$legacyDirectory/assets/wix" ./assets -Recurse -Force
    foreach ($file in @('packaging.psm1', 'packaging.strings.psd1')) {
        Copy-Item "$legacyDirectory/tools/packaging/$file" "./tools/packaging/$file" -Force
    }
    $packagingPath = Join-Path $repoRoot 'tools/packaging/packaging.psm1'
    $moduleText = Get-Content $packagingPath -Raw
    $oldFrameworkLine = '$script:netCoreRuntime = ''net10.0'''
    if (-not $moduleText.Contains($oldFrameworkLine)) { throw 'Unexpected pinned packaging framework declaration.' }
    $moduleText = $moduleText.Replace($oldFrameworkLine, ('$script:netCoreRuntime = ''' + $options.Framework + ''''))
    # The original deletion check uses the loop variable, not the complete BOM.
    # Keep the gate, but fix it to reject any removed entry as well as additions.
    $oldRemovalLine = '$needsRemoval = $bom | Where-Object {'
    if (-not $moduleText.Contains($oldRemovalLine)) { throw 'Unexpected pinned BOM deletion check.' }
    $moduleText = $moduleText.Replace($oldRemovalLine, '$needsRemoval = $bomRecords | Where-Object {')
    Set-Content $packagingPath -Value $moduleText -Encoding utf8NoBOM

    # Use the exact Microsoft.Signed.Wix package already declared by this source.
    dotnet restore ./tools/wix/Microsoft.PowerShell.Packaging.csproj
    if ($LASTEXITCODE -ne 0) { throw 'Cannot restore the official WiX toolset.' }
    [xml] $wixProject = Get-Content ./tools/wix/Microsoft.PowerShell.Packaging.csproj
    $wixVersion = ($wixProject.Project.ItemGroup.PackageReference | Where-Object Include -eq 'Microsoft.Signed.Wix').Version
    $packageRoot = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $HOME '.nuget/packages' }
    $wixPackage = Join-Path $packageRoot "microsoft.signed.wix/$wixVersion"
    $heat = @(Get-ChildItem $wixPackage -Filter heat.exe -File -Recurse)
    if ($heat.Count -ne 1) { throw "Expected one official heat.exe in $wixPackage; found $($heat.Count)." }
    $wixBin = Join-Path ${env:ProgramFiles(x86)} 'WiX Toolset Community MSI/bin'
    $null = New-Item -ItemType Directory -Path $wixBin -Force
    Copy-Item (Join-Path $heat[0].Directory.FullName '*') $wixBin -Recurse -Force
    foreach ($executable in @('heat.exe', 'candle.exe', 'light.exe')) {
        if (-not (Test-Path (Join-Path $wixBin $executable))) { throw "Missing WiX executable: $executable" }
    }

    # Prepare an unsigned release payload without claiming to provide Microsoft SBOM/signing.
    Copy-Item $publishDirectory $payloadDirectory -Recurse -Force
    Get-ChildItem $payloadDirectory -Filter '*.pdb' -File -Recurse | Remove-Item -Force
    Copy-Item ./ThirdPartyNotices.txt $payloadDirectory -Force
    $null = New-Item -ItemType Directory -Path "$payloadDirectory/en-US" -Force
    Copy-Item ./assets/default.help.txt "$payloadDirectory/en-US" -Force
    Copy-Item "$legacyDirectory/assets/MicrosoftUpdate/RegisterMicrosoftUpdate.ps1" $payloadDirectory -Force
    # powershell-win-core.csproj ships the current instrumentation script and .man.
    if (-not (Test-Path "$payloadDirectory/RegisterManifest.ps1")) {
        throw 'The built Windows payload is missing RegisterManifest.ps1.'
    }
    $null = New-Item -ItemType Directory -Path "$payloadDirectory/assets" -Force
    Copy-Item ./assets/*.ico "$payloadDirectory/assets" -Force

    $packaging = Import-Module $packagingPath -Force -PassThru
    # The old 7.6 BOM cannot validate a new .NET/PowerShell payload. Generate an exact
    # version-specific inventory, then retain the original Test-Bom gate in New-MSIPackage.
    $bom = & $packaging {
        param($Root)
        @(Get-ChildItem $Root -File -Recurse | ForEach-Object {
            $relative = [IO.Path]::GetRelativePath($Root, $_.FullName)
            [ordered]@{
                Pattern = [WildcardPattern]::Escape($relative).Replace('\', '/')
                FileType = if (Test-IsProductFile $_.FullName) { 'Product' } else { 'NonProduct' }
                Architecture = @('x64')
            }
        })
    } $payloadDirectory
    $bomPath = Join-Path $repoRoot 'tools/packaging/Boms/windows.json'
    $null = New-Item -ItemType Directory -Path (Split-Path $bomPath -Parent) -Force
    @($bom | Sort-Object Pattern) | ConvertTo-Json -Depth 5 | Set-Content $bomPath -Encoding utf8NoBOM
    Copy-Item $bomPath (Join-Path $output 'windows-bom.json') -Force

    $package = & $packaging {
        param($Source, $Version, $Destination)
        New-MSIPackage -ProductSourcePath $Source -ProductVersion $Version -ProductTargetArchitecture x64 -ProductNameSuffix win-x64 -CurrentLocation $Destination -Force -Verbose
    } $payloadDirectory $version $output
    $msi = Join-Path $output "PowerShell-$version-win-x64.msi"
    if (-not (Test-Path $msi)) { throw "Expected MSI was not created: $msi" }
    $stage = Join-Path $repoRoot 'tools/packaging/staging'
    $hashes = @(Get-ChildItem $stage -File -Recurse | Sort-Object FullName | ForEach-Object {
        [ordered]@{
            Path = [IO.Path]::GetRelativePath($stage, $_.FullName).Replace('\', '/')
            SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    $hashes | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $output 'payload-sha256.json') -Encoding utf8NoBOM
    $names = & $packaging { param($Version) Get-WindowsNames -ProductVersion $Version } $version
    [ordered]@{
        Version = $version
        Tag = $VersionTag
        SourceCommit = $sourceCommit
        SourceRepository = $env:GITHUB_REPOSITORY
        OriginalMsiSourceCommit = $legacyCommit
        OriginalMsiSourceTag = 'v7.6.0'
        DotNetSdk = $sdkVersion
        TargetFramework = $options.Framework
        Runtime = 'win7-x64'
        WixPackage = 'Microsoft.Signed.Wix'
        WixVersion = $wixVersion
        MsiProductVersion = $names.ProductVersion
        MsiFile = (Split-Path $msi -Leaf)
        MsiSHA256 = (Get-FileHash $msi -Algorithm SHA256).Hash.ToLowerInvariant()
        PayloadFiles = $hashes.Count
        MicrosoftSignedInstaller = $false
        BomPolicy = 'Exact inventory of this build, checked by the original Test-Bom; not the obsolete v7.6 BOM or a Microsoft-certified SBOM.'
        BuildUrl = "https://github.com/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
    } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $output 'provenance.json') -Encoding utf8NoBOM
    (Get-FileHash $msi -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + (Split-Path $msi -Leaf) |
        Set-Content (Join-Path $output 'SHA256SUMS') -Encoding utf8NoBOM
    Write-Host "Created $msi"
} finally {
    if ($referenceAdded) { git worktree remove --force $legacyDirectory }
    if ($transcriptStarted) { Stop-Transcript }
    Pop-Location
}
