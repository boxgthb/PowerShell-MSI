# Run after pushing new upstream workflow files and before enabling/tagging builds.
[CmdletBinding()]
param([string] $Repository)
$ErrorActionPreference = 'Stop'
if (-not $Repository) {
    $Repository = gh repo view --json nameWithOwner --jq .nameWithOwner
    if ($LASTEXITCODE -ne 0) { throw 'Cannot determine the private repository.' }
}
$customPath = '.github/workflows/build-msi.yml'
$workflows = gh api --paginate "repos/$Repository/actions/workflows" --jq '.workflows[] | [.id, .path] | @tsv'
if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate repository workflows.' }
foreach ($line in $workflows) {
    $id, $path = $line -split "`t", 2
    $operation = if ($path -eq $customPath) { 'enable' } else { 'disable' }
    gh api --method PUT "repos/$Repository/actions/workflows/$id/$operation"
    if ($LASTEXITCODE -ne 0) { throw "Cannot $operation workflow $path" }
    Write-Host "$operation $path"
}
