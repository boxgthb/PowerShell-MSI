# Optional source-level disabling is performed BEFORE pushing rebased branches.
# The API additionally disables workflows that GitHub has already registered.
[CmdletBinding()]
param([string] $Repository, [switch] $DisableSourceFiles)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/../..").Path
$customPaths = @('.github/workflows/build-msi.yml', '.github/workflows/build-source-msi.yml')
if ($DisableSourceFiles) {
    foreach ($file in Get-ChildItem "$root/.github/workflows" -File) {
        if ($file.Extension -notin @('.yml', '.yaml')) { continue }
        $path = ".github/workflows/$($file.Name)"
        if ($path -in $customPaths) { continue }
        git -C $root mv -- $path "$path.disabled"
        if ($LASTEXITCODE -ne 0) { throw "Cannot disable source workflow $path; review a possible rename conflict." }
        Write-Host "Source disabled: $path.disabled"
    }
    $dependabot = Join-Path $root '.github/dependabot.yml'
    if (Test-Path $dependabot) {
        "version: 2`n# No automated dependency-update PRs in this private MSI mirror.`nupdates: []" |
            Set-Content $dependabot -Encoding UTF8
    }
}
if (-not $Repository) {
    $Repository = gh repo view --json nameWithOwner --jq .nameWithOwner
    if ($LASTEXITCODE -ne 0) { throw 'Cannot determine the private repository.' }
}
$workflows = gh api --paginate "repos/$Repository/actions/workflows" --jq '.workflows[] | [.id, .path, .state] | @tsv'
if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate repository workflows.' }
foreach ($line in $workflows) {
    $id, $path, $state = $line -split "`t", 3
    # Built-in dynamic/dependabot workflows cannot be disabled with this API.
    # Their update schedule is disabled in the source configuration above.
    if ($path -notlike '.github/workflows/*') { continue }
    if ($path -in $customPaths -and $state -eq 'active') { continue }
    if ($path -notin $customPaths -and $state -ne 'active') {
        Write-Host "Already inactive: $path ($state)"
        continue
    }
    $operation = if ($path -in $customPaths) { 'enable' } else { 'disable' }
    gh api --method PUT "repos/$Repository/actions/workflows/$id/$operation"
    if ($LASTEXITCODE -ne 0) { throw "Cannot $operation workflow $path" }
    Write-Host "$operation $path"
}
