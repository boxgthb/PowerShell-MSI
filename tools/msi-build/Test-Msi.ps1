# Runs in Windows PowerShell 5.1 so upgrading PowerShell 7 cannot lock this shell.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^v\d+\.\d+\.\d+(-(preview|rc)\.\d+)?$')]
    [string] $VersionTag,
    [string] $ArtifactDirectory = './artifacts'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$artifacts = [IO.Path]::GetFullPath($ArtifactDirectory)
$version = $VersionTag.Substring(1)
$msi = Join-Path $artifacts "PowerShell-$version-win-x64.msi"
$provenance = Get-Content (Join-Path $artifacts 'provenance.json') -Raw | ConvertFrom-Json
if ((Get-FileHash $msi -Algorithm SHA256).Hash.ToLowerInvariant() -ne $provenance.MsiSHA256) { throw 'MSI SHA-256 mismatch.' }
$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $installer.OpenDatabase($msi, 0)
function Read-MsiProperty([string] $Name) {
    $view = $database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$Name'")
    $view.Execute()
    $record = $view.Fetch()
    if (-not $record) { throw "Missing MSI property: $Name" }
    $value = $record.StringData(1)
    $view.Close()
    return $value
}
$template = $database.SummaryInformation(0).Property(7)
if ($template -notmatch '^x64;') { throw "Not an x64 MSI: $template" }
$productCode = Read-MsiProperty 'ProductCode'
$productVersion = Read-MsiProperty 'ProductVersion'
if ($productVersion -ne $provenance.MsiProductVersion) { throw "Unexpected MSI ProductVersion: $productVersion" }
[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($database)
[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)

$installRoot = Join-Path $env:RUNNER_TEMP 'community-msi-install'
$major = ($version -split '\.')[0]
$folderName = if ($version -match '-') { "$major-preview" } else { $major }
$pwsh = Join-Path $installRoot "$folderName/pwsh.exe"
$installLog = Join-Path $artifacts 'msi-install.log'
$uninstallLog = Join-Path $artifacts 'msi-uninstall.log'
$installationStarted = $false
$verified = $false
$uninstallCode = $null
$processInfo = $null
$manifest = @(Get-Content (Join-Path $artifacts 'payload-sha256.json') -Raw | ConvertFrom-Json)
try {
    $arguments = "/i `"$msi`" /qn /norestart /L*v `"$installLog`" INSTALLFOLDER=`"$installRoot`" ADD_PATH=0 REGISTER_MANIFEST=0 ENABLE_PSREMOTING=0 USE_MU=0 ENABLE_MU=0 DISABLE_TELEMETRY=1 ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=0 ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=0"
    $install = Start-Process msiexec.exe -ArgumentList $arguments -Wait -PassThru
    if ($install.ExitCode -notin @(0, 3010)) { throw "MSI installation failed: $($install.ExitCode)" }
    $installationStarted = $true
    if (-not (Test-Path $pwsh)) { throw "Installed executable missing: $pwsh" }
    $payloadRoot = Split-Path $pwsh -Parent
    foreach ($file in $manifest) {
        $installedFile = Join-Path $payloadRoot $file.Path
        if (-not (Test-Path $installedFile -PathType Leaf)) { throw "Installed payload missing: $($file.Path)" }
        if ((Get-FileHash -LiteralPath $installedFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $file.SHA256) {
            throw "Installed payload hash mismatch: $($file.Path)"
        }
    }
    $probe = @'
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Management,Microsoft.PowerShell.Utility,Microsoft.PowerShell.Security,Microsoft.WSMan.Management -ErrorAction Stop
Import-Module PowerShellGet,PackageManagement,Microsoft.PowerShell.PSResourceGet,Microsoft.PowerShell.Archive,PSReadLine,Microsoft.PowerShell.ThreadJob -ErrorAction Stop
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName PresentationFramework
[ordered]@{
    Version = $PSVersionTable.PSVersion.ToString()
    Edition = $PSVersionTable.PSEdition
    ProcessArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    ModuleImports = 'passed'
    WindowsDesktopAssemblies = 'passed'
} | ConvertTo-Json -Compress
'@
    $encodedProbe = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
    $probeOutput = & $pwsh -NoLogo -NoProfile -NonInteractive -EncodedCommand $encodedProbe
    if ($LASTEXITCODE -ne 0) { throw 'Installed PowerShell startup/module smoke test failed.' }
    $processInfo = ($probeOutput -join "`n") | ConvertFrom-Json
    if ($processInfo.Version -ne $version -or $processInfo.Edition -ne 'Core' -or $processInfo.ProcessArchitecture -ne 'X64') {
        throw "Incorrect installed PowerShell identity: $($probeOutput -join ' ')"
    }
    $verified = $true
} finally {
    if ($installationStarted) {
        $uninstall = Start-Process msiexec.exe -ArgumentList "/x $productCode /qn /norestart /L*v `"$uninstallLog`"" -Wait -PassThru
        $uninstallCode = $uninstall.ExitCode
        if ($uninstallCode -notin @(0, 3010)) { throw "MSI uninstallation failed: $uninstallCode" }
        if (Test-Path $pwsh) { throw 'pwsh.exe remains after uninstallation.' }
    }
}
if (-not $verified) { throw 'Installation validation did not complete.' }
[ordered]@{
    Version = $version
    SourceCommit = $provenance.SourceCommit
    MsiSHA256 = $provenance.MsiSHA256
    MsiTemplate = $template
    MsiProductCode = $productCode
    MsiProductVersion = $productVersion
    ComparedPayloadFiles = $manifest.Count
    Installation = 'passed'
    PowerShell = $processInfo
    Uninstallation = 'passed'
    UninstallExitCode = $uninstallCode
} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $artifacts 'installation-test.json') -Encoding UTF8
Write-Host 'MSI metadata, payload hashes, installation, startup, module imports and uninstallation passed.'
