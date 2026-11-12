# Copyright (c) Microsoft Corporation. Licensed under the MIT License.
# Official release download helpers and read-only MSI metadata queries.

function Invoke-GitHubJson {
    param([Parameter(Mandatory)][string] $Path, [switch] $AllowMissing)
    $errorFile = [IO.Path]::GetTempFileName()
    try {
        $text = & gh api $Path 2> $errorFile
        if ($LASTEXITCODE -ne 0) {
            $message = Get-Content -LiteralPath $errorFile -Raw
            if ($AllowMissing -and $message -match 'HTTP 404') { return $null }
            throw "GitHub API failed for ${Path}: $message"
        }
        return (($text -join "`n") | ConvertFrom-Json)
    } finally { Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue }
}

function Get-GitHubTagCommit {
    param([Parameter(Mandatory)][string] $Repository, [Parameter(Mandatory)][string] $Tag, [switch] $AllowMissing)
    $reference = Invoke-GitHubJson "repos/$Repository/git/ref/tags/$Tag" -AllowMissing:$AllowMissing
    if (-not $reference) { return 'missing' }
    $object = $reference.object
    for ($depth = 0; $object.type -eq 'tag' -and $depth -lt 8; $depth++) {
        $object = (Invoke-GitHubJson "repos/$Repository/git/tags/$($object.sha)").object
    }
    if ($object.type -ne 'commit' -or $object.sha -notmatch '^[0-9a-f]{40}$') { throw "Tag $Repository/$Tag does not identify a commit." }
    return [string] $object.sha
}

function Get-ReleaseAssetDigest {
    param([Parameter(Mandatory)] $Asset)
    if ($Asset.PSObject.Properties.Name -contains 'digest' -and $Asset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
        return $Matches[1].ToLowerInvariant()
    }
    return ''
}

function Receive-OfficialReleaseFile {
    param([Parameter(Mandatory)][string] $Tag, [Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $Directory)
    $null = New-Item -ItemType Directory -Path $Directory -Force
    & gh release download $Tag --repo PowerShell/PowerShell --pattern $Name --dir $Directory --clobber
    if ($LASTEXITCODE -ne 0) { throw "Cannot download the official $Tag/$Name asset." }
    $path = Join-Path $Directory $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Official asset was not downloaded: $path" }
    return $path
}

function Get-OfficialAssetInfo {
    param([Parameter(Mandatory)][string] $Tag, [Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $CacheDirectory, $Release)
    if ($Tag -notmatch '^v\d+\.\d+\.\d+(-(preview|rc)\.\d+)?$') { throw "Unsupported official tag: $Tag" }
    if (-not $Release) { $Release = Invoke-GitHubJson "repos/PowerShell/PowerShell/releases/tags/$Tag" }
    if ($Release.tag_name -ne $Tag -or $Release.draft) { throw 'The requested official release is missing or is a draft.' }
    $assets = @($Release.assets | Where-Object name -CEQ $Name)
    $manifests = @($Release.assets | Where-Object name -CEQ 'hashes.sha256')
    if ($assets.Count -ne 1 -or $manifests.Count -ne 1) { throw "Expected exactly one official $Name and hashes.sha256 for $Tag." }
    $asset = $assets[0]
    $manifest = $manifests[0]
    $canonicalUrl = "https://github.com/PowerShell/PowerShell/releases/download/$Tag/$Name"
    if ($asset.browser_download_url -cne $canonicalUrl) { throw 'Unexpected official asset download origin.' }
    $manifestPath = Receive-OfficialReleaseFile -Tag $Tag -Name hashes.sha256 -Directory $CacheDirectory
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifestDigest = Get-ReleaseAssetDigest $manifest
    if ($manifestDigest -and $manifestDigest -ne $manifestHash) { throw 'The official checksum manifest does not match its GitHub asset digest.' }
    # Get-Content recognizes the UTF-16 BOM used by official hashes.sha256 files.
    $hashes = @()
    foreach ($line in (Get-Content -LiteralPath $manifestPath)) {
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$' -and $Matches[2] -ceq $Name) { $hashes += $Matches[1].ToLowerInvariant() }
    }
    if ($hashes.Count -ne 1) { throw "The official checksum manifest must contain exactly one entry for $Name." }
    $assetDigest = Get-ReleaseAssetDigest $asset
    if ($assetDigest -and $assetDigest -ne $hashes[0]) { throw 'Official asset digest and hashes.sha256 disagree.' }
    return [pscustomobject][ordered]@{
        Tag = $Tag
        Version = $Tag.Substring(1)
        Name = $Name
        URL = $canonicalUrl
        SHA256 = $hashes[0]
        Size = $asset.size
        GitHubAssetDigest = $assetDigest
        HashManifestURL = $manifest.browser_download_url
        HashManifestSHA256 = $manifestHash
        HashManifestDigestVerified = [bool] $manifestDigest
        OfficialCommit = Get-GitHubTagCommit -Repository PowerShell/PowerShell -Tag $Tag
    }
}

function Get-OfficialZipRequest {
    param([string] $ZipURL, [string] $VersionTag, [Parameter(Mandatory)][string] $CacheDirectory)
    $requestedName = ''
    $release = $null
    if (-not [string]::IsNullOrWhiteSpace($ZipURL)) {
        $uri = $null
        if (-not [uri]::TryCreate($ZipURL.Trim(), [UriKind]::Absolute, [ref] $uri) -or
            $uri.Scheme -ne 'https' -or $uri.DnsSafeHost -ne 'github.com' -or
            $uri.UserInfo -or $uri.Query -or $uri.Fragment -or -not $uri.IsDefaultPort) {
            throw 'ZIP URL must be an official HTTPS github.com/PowerShell/PowerShell release link.'
        }
        if ($uri.AbsolutePath -match '^/PowerShell/PowerShell/releases/download/(v\d+\.\d+\.\d+(-(preview|rc)\.\d+)?)/(PowerShell-.+-win-x64\.zip)$') {
            $tagFromURL = $Matches[1]
            $requestedName = $Matches[4]
        } elseif ($uri.AbsolutePath -match '^/PowerShell/PowerShell/releases/latest/download/(PowerShell-.+-win-x64\.zip)$') {
            $requestedName = $Matches[1]
            $release = Invoke-GitHubJson repos/PowerShell/PowerShell/releases/latest
            $tagFromURL = $release.tag_name
        } else { throw 'Only official Windows x64 PowerShell ZIP assets are accepted.' }
        if ($VersionTag -and $VersionTag -ne $tagFromURL) { throw 'Input ZIP version does not match the requested version.' }
        $VersionTag = $tagFromURL
    } elseif (-not $VersionTag) {
        $release = Invoke-GitHubJson repos/PowerShell/PowerShell/releases/latest
        if ($release.prerelease -or $release.draft) { throw 'Latest release is not a published stable release.' }
        $VersionTag = $release.tag_name
    }
    if ($VersionTag -notmatch '^v\d+\.\d+\.\d+(-(preview|rc)\.\d+)?$') { throw "Unsupported release tag: $VersionTag" }
    $name = "PowerShell-$($VersionTag.Substring(1))-win-x64.zip"
    if ($requestedName -and $requestedName -cne $name) { throw 'ZIP filename and release tag disagree.' }
    return Get-OfficialAssetInfo -Tag $VersionTag -Name $name -CacheDirectory $CacheDirectory -Release $release
}

function Receive-VerifiedOfficialAsset {
    param([Parameter(Mandatory)] $Asset, [Parameter(Mandatory)][string] $Directory)
    $path = Receive-OfficialReleaseFile -Tag $Asset.Tag -Name $Asset.Name -Directory $Directory
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $Asset.SHA256 -or (Get-Item -LiteralPath $path).Length -ne $Asset.Size) { throw "Official asset SHA256/size mismatch: $($Asset.Name)" }
    return $path
}

function Read-MsiMetadata {
    param([Parameter(Mandatory)][string] $Path)
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.OpenDatabase($Path, 0)
    try {
        $values = [ordered]@{ Template = [string] $database.SummaryInformation(0).Property(7) }
        foreach ($name in @('ProductCode', 'ProductVersion', 'UpgradeCode')) {
            $view = $database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$name'")
            try {
                [void] $view.Execute()
                $record = $view.Fetch()
                if (-not $record) { throw "Missing MSI property: $name" }
                $values[$name] = [string] $record.StringData(1)
            } finally { [void] $view.Close() }
        }
        return [pscustomobject] $values
    } finally {
        [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($database)
        [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)
    }
}
