# Shared local WiX packaging for official ZIP and source-built payloads.

function Get-MsiPayloadInventory {
    param([Parameter(Mandatory)][string] $Root)
    Get-ChildItem -LiteralPath $Root -File -Recurse | Sort-Object FullName | ForEach-Object {
        [pscustomobject][ordered]@{
            Path = [IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/')
            SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
}

function Save-MsiArtifactChecksums {
    param([Parameter(Mandatory)][string] $Directory)
    $lines = @(Get-ChildItem -LiteralPath $Directory -File | Where-Object { $_.Extension -in @('.msi', '.json') } | Sort-Object Name | ForEach-Object {
        (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $_.Name
    })
    [IO.File]::WriteAllLines((Join-Path $Directory 'SHA256SUMS'), $lines, [Text.UTF8Encoding]::new($false))
}

function New-CommunityMsiPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][string] $PayloadDirectory,
        [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+(-(preview|rc)\.\d+)?$')][string] $Version,
        [Parameter(Mandatory)][ValidatePattern('^net\d+\.\d+$')][string] $Framework,
        [Parameter(Mandatory)][string] $OutputDirectory
    )
    # Immediate parent of the squash merge that removed MSI support in PR #27213.
    $legacyCommit = '30d14eafaa02d2815970b99d14e00de297909b6d'
    $wixVersion = '3.14.1-8722.20240403.1'
    $wixSHA256 = 'bb7221efe5cba420a2c2df260669aaf3f6a33a38681391ce5eeb23285509a2a0'
    $wixURL = "https://pkgs.dev.azure.com/dnceng/9ee6d478-d288-47f7-aacc-f6e6d082ae6d/_packaging/1a5f89f6-d8da-4080-b15f-242650c914a8/nuget/v3/flat2/microsoft.signed.wix/$wixVersion/microsoft.signed.wix.$wixVersion.nupkg"
    $legacyDirectory = Join-Path $env:RUNNER_TEMP ('official-msi-reference-' + [guid]::NewGuid().ToString('N'))
    $referenceAdded = $false
    try {
        git -C $RepositoryRoot fetch --no-tags https://github.com/PowerShell/PowerShell.git $legacyCommit | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Cannot fetch the pinned pre-#27213 MSI implementation.' }
        git -C $RepositoryRoot worktree add --detach $legacyDirectory $legacyCommit | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Cannot create the pinned MSI reference worktree.' }
        $referenceAdded = $true
        $null = Disable-MsiOnlineUpdate -ProductWxsPath (Join-Path $legacyDirectory 'assets/wix/Product.wxs')
        $packagingPath = Join-Path $legacyDirectory 'tools/packaging/packaging.psm1'
        $moduleText = Get-Content -LiteralPath $packagingPath -Raw
        $frameworkPattern = '(?m)^\$script:netCoreRuntime = ''net\d+\.\d+'''
        if ([regex]::Matches($moduleText, $frameworkPattern).Count -ne 1) { throw 'Unexpected pinned packaging framework declaration.' }
        $moduleText = [regex]::Replace($moduleText, $frameworkPattern, ('$script:netCoreRuntime = ''' + $Framework + ''''))
        $oldRemovalLine = '$needsRemoval = $bom | Where-Object {'
        if (-not $moduleText.Contains($oldRemovalLine)) { throw 'Unexpected original BOM deletion check.' }
        $moduleText = $moduleText.Replace($oldRemovalLine, '$needsRemoval = $bomRecords | Where-Object {')
        Set-Content -LiteralPath $packagingPath -Value $moduleText -Encoding utf8NoBOM

        $wixArchive = Join-Path $env:RUNNER_TEMP 'microsoft.signed.wix.zip'
        Invoke-WebRequest -Uri $wixURL -OutFile $wixArchive
        if ((Get-FileHash -LiteralPath $wixArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $wixSHA256) { throw 'WiX archive SHA256 mismatch.' }
        $wixExtract = Join-Path $env:RUNNER_TEMP 'wix-extracted'
        Expand-Archive -LiteralPath $wixArchive -DestinationPath $wixExtract -Force
        $heat = @(Get-ChildItem -LiteralPath $wixExtract -Filter heat.exe -File -Recurse)
        if ($heat.Count -ne 1) { throw 'Expected one pinned heat.exe.' }
        $wixBin = Join-Path ${env:ProgramFiles(x86)} 'WiX Toolset Community MSI/bin'
        $null = New-Item -ItemType Directory -Path $wixBin -Force
        Copy-Item (Join-Path $heat[0].Directory.FullName '*') $wixBin -Recurse -Force
        foreach ($executable in @('heat.exe', 'candle.exe', 'light.exe')) {
            if (-not (Test-Path -LiteralPath (Join-Path $wixBin $executable))) { throw "Missing WiX executable: $executable" }
        }

        # Preserve existing payload resources when the original staging code copies icons.
        $payloadAssets = Join-Path $PayloadDirectory 'assets'
        $null = New-Item -ItemType Directory -Path $payloadAssets -Force
        foreach ($icon in Get-ChildItem -LiteralPath (Join-Path $legacyDirectory 'assets') -Filter '*.ico' -File) {
            $destination = Join-Path $payloadAssets $icon.Name
            if (-not (Test-Path -LiteralPath $destination)) { Copy-Item -LiteralPath $icon.FullName -Destination $destination }
            else { Copy-Item -LiteralPath $destination -Destination $icon.FullName -Force }
        }
        $expectedPayload = @(Get-MsiPayloadInventory -Root $PayloadDirectory)
        if (-not $expectedPayload.Count) { throw 'Cannot package an empty payload.' }
        Import-Module (Join-Path $legacyDirectory 'build.psm1') -Force
        $packaging = Import-Module $packagingPath -Force -PassThru
        $bom = & $packaging {
            param($Root)
            @(Get-ChildItem -LiteralPath $Root -File -Recurse | ForEach-Object {
                $relative = [IO.Path]::GetRelativePath($Root, $_.FullName)
                [ordered]@{
                    Pattern = [WildcardPattern]::Escape($relative).Replace('\', '/')
                    FileType = if (Test-IsProductFile $_.FullName) { 'Product' } else { 'NonProduct' }
                    Architecture = @('x64')
                }
            })
        } $PayloadDirectory
        $bomPath = Join-Path $legacyDirectory 'tools/packaging/Boms/windows.json'
        $null = New-Item -ItemType Directory -Path (Split-Path $bomPath -Parent) -Force
        @($bom | Sort-Object Pattern) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $bomPath -Encoding utf8NoBOM
        Copy-Item -LiteralPath $bomPath -Destination (Join-Path $OutputDirectory 'windows-bom.json') -Force
        Push-Location $legacyDirectory
        try {
            $null = & $packaging {
                param($Source, $ProductVersion, $Destination)
                New-MSIPackage -ProductSourcePath $Source -ProductVersion $ProductVersion -ProductTargetArchitecture x64 -ProductNameSuffix win-x64 -CurrentLocation $Destination -Force -Verbose
            } $PayloadDirectory $Version $OutputDirectory
        } finally { Pop-Location }
        $msi = Join-Path $OutputDirectory "PowerShell-$Version-win-x64.msi"
        if (-not (Test-Path -LiteralPath $msi -PathType Leaf) -or (Get-Item -LiteralPath $msi).Length -eq 0) { throw 'The original WiX pipeline did not create a nonempty MSI.' }
        $stage = Join-Path $legacyDirectory 'tools/packaging/staging'
        $stagedPayload = @(Get-MsiPayloadInventory -Root $stage)
        if ($stagedPayload.Count -ne $expectedPayload.Count) { throw 'MSI staging changed the payload file count.' }
        foreach ($file in $expectedPayload) {
            $path = Join-Path $stage $file.Path
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $file.SHA256) { throw "MSI staging modified or lost: $($file.Path)" }
        }
        $stagedPayload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'payload-sha256.json') -Encoding utf8NoBOM
        $names = & $packaging { param($ProductVersion) Get-WindowsNames -ProductVersion $ProductVersion } $Version
        $metadata = Read-MsiMetadata -Path $msi
        $expectedUpgradeCode = if ($Version -match '-') { '{39243D76-ADAF-42B1-94FB-16ECF83237C8}' } else { '{31AB5147-9A97-4452-8443-D9709F0516E1}' }
        if ($metadata.Template -notmatch '^x64(;|$)' -or $metadata.ProductVersion -ne $names.ProductVersion -or $metadata.UpgradeCode -ne $expectedUpgradeCode) { throw 'Generated MSI architecture, version or UpgradeCode is incorrect.' }
        $hash = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash.ToLowerInvariant()
        [ordered]@{
            MsiFile = (Split-Path $msi -Leaf)
            MsiSHA256 = $hash
            MsiTemplate = $metadata.Template
            MsiProductCode = $metadata.ProductCode
            MsiProductVersion = $metadata.ProductVersion
            MsiUpgradeCode = $metadata.UpgradeCode
            PayloadFiles = $stagedPayload.Count
            MsiMetadata = 'passed'
            StagedPayload = 'passed'
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'package-checks.json') -Encoding utf8NoBOM
        return [pscustomobject][ordered]@{
            OriginalMsiSourceCommit = $legacyCommit
            WixVersion = $wixVersion
            WixArchiveSHA256 = $wixSHA256
            MsiFile = (Split-Path $msi -Leaf)
            MsiSHA256 = $hash
            MsiProductVersion = $metadata.ProductVersion
            PayloadFiles = $stagedPayload.Count
        }
    } finally {
        if ($referenceAdded) {
            git -C $RepositoryRoot worktree remove --force $legacyDirectory | Out-Host
            if ($LASTEXITCODE -ne 0) { Write-Warning 'Could not remove the temporary MSI reference worktree.' }
        }
    }
}
