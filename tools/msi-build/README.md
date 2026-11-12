# PowerShell MSI

为 Windows x64 构建 PowerShell MSI。

## Official ZIP to MSI

入口：`Actions` → `Official ZIP to MSI` → `Run workflow`。

输入：

- `zip_url`：可选。留空使用官方最新稳定版 Windows x64 ZIP；也可以填写官方 PowerShell Release ZIP 链接。

Release 产物：

- `PowerShell-<version>-win-x64.msi`
- `SHA256SUMS`
- `provenance.json`
- `package-checks.json`
- `payload-sha256.json`
- `windows-bom.json`
- `official-zip.json`
- `official-files-sha256.json`
- `official-signatures.json`

## Source build to MSI

入口：`Actions` → `Source build to MSI` → `Run workflow`。

输入：

- `tag`：可选源码标签。留空使用本仓库最新的支持版本标签。

Release 产物：

- `PowerShell-<version>-win-x64.msi`
- `SHA256SUMS`
- `provenance.json`
- `package-checks.json`
- `payload-sha256.json`
- `windows-bom.json`
- `source-build.json`
