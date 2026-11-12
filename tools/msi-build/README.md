# Reusable community MSI build

This patch adds only the community workflow and adapters. It does not change
PowerShell application source. Apply the same patch to an official release branch
and `master`; then tag the patched release commit **in this private repository**.
Never move an official tag in `PowerShell/PowerShell`.

`build-msi.yml` triggers only on `v*` tag pushes or a manual request naming an
existing tag. Branch pushes do not start this MSI workflow. All inherited official
workflows are disabled using the GitHub API; their source files remain intact so
rebasing does not conflict with unrelated CI changes.

## What is retained / adapted

- `Start-PSBuild -Configuration Release -Runtime win7-x64 -ReleaseTag ...
  -PSModuleRestore -UseNuGetOrg`, using `global.json` from the selected source.
- Original `New-MSIPackage`, WiX UI/Product assets and heat -> candle -> light
  pipeline from official v7.6.0, pinned to
  `767990ba06f8579d69f99eec46057541374aa892`.
- The Microsoft.Signed.Wix version declared in the selected source, and the
  original x64 stable/preview UpgradeCodes and installation options.
- A framework-name adapter (net10.0 -> the framework actually built), restoration
  of the Microsoft Update registration script referenced by the old installer,
  and a fresh exact file inventory for each new version. The original Test-Bom
  verifies this inventory before WiX harvests the payload. The adapter fixes
  the old deletion check to use the complete BOM rather than its loop variable.
  It is not a
  Microsoft-reviewed BOM or a certified SBOM.
- Real installation/uninstallation on a disposable Windows runner, MSI metadata,
  payload hash comparison, bundled module imports and WPF/WinForms loading.
- Release publication is gated on successful validation. Repeat runs overwrite
  release assets only after passing the same gates.

The MSI is **community-built and is not Microsoft-signed**. Existing official
PowerShell 7 MSI installations may be replaced because the official UpgradeCode
is preserved. Do not assume Microsoft Update will maintain this MSI; use the next
private release instead. To avoid unnecessary MU configuration, install with
`USE_MU=0 ENABLE_MU=0`.

The assets contain `PowerShell-<version>-win-x64.msi`, SHA256SUMS,
provenance.json, payload-sha256.json, windows-bom.json and installation-test.json.
No Microsoft signing credentials or private package feeds are required.

## Rebase for the next upstream release

Keep `upstream` pointing to the official repository and `origin` to the private
repository. Record the original base of your current MSI branch (for the first
version: `5c95ed61735c05eb99543aabf196529b5f267602`). Fetch new official tags
**into a separate namespace** so they cannot overwrite your private build tags:

```powershell
git fetch upstream '+refs/heads/master:refs/remotes/upstream/master' '+refs/tags/*:refs/upstream-tags/*'
git switch master
git rebase upstream/master

# Replay the adapter commit(s), not the old PowerShell source history.
git switch -c msi/v7.7.1 msi/v7.7.0
git rebase --onto refs/upstream-tags/v7.7.1 5c95ed61735c05eb99543aabf196529b5f267602

# Suspend all Actions while new inherited workflow files become visible.
gh api --method PUT repos/OWNER/PowerShell-MSI/actions/permissions -F enabled=false
git push --force-with-lease origin master
git push -u origin msi/v7.7.1
./tools/msi-build/Disable-UpstreamActions.ps1 -Repository OWNER/PowerShell-MSI
gh api --method PUT repos/OWNER/PowerShell-MSI/actions/permissions -F enabled=true

git tag -a v7.7.1 -m 'Community MSI build of official v7.7.1'
git push origin refs/tags/v7.7.1
```

For a corrected build of the same version, replace its private tag only after
reviewing the new commit; `git push --force origin refs/tags/v7.7.1` intentionally
moves that private tag. A manual workflow re-run may also rebuild the existing
private tag without moving it. Record each new version's original base before
the next rebase. The source commit and workflow run URL are saved in provenance.

The workflow is pinned to current action commit IDs and a fixed original MSI
implementation. A future upstream change to build APIs, package layout or
installer behavior may require an adapter update; it is not a promise that every
future release can build forever without maintenance.
