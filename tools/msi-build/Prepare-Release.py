#!/usr/bin/env python3
"""Check package records and generate notes/assets for the current build mode."""
import hashlib
import json
import os
import re
from pathlib import Path


def prepare(directory: Path, environment):
    def load(name):
        return json.loads((directory / name).read_text(encoding="utf-8-sig"))

    def require(condition, message):
        if not condition:
            raise ValueError(message)

    tag = environment["VERSION_TAG"]
    mode = environment["PACKAGING_MODE"]
    require(re.fullmatch(r"v\d+\.\d+\.\d+(?:-(?:preview|rc)\.\d+)?", tag), "Unsupported version tag")
    version = tag[1:]
    expected_name = f"PowerShell-{version}-win-x64.msi"
    p = load("provenance.json")
    checks = load("package-checks.json")
    payload = load("payload-sha256.json")
    bom = load("windows-bom.json")
    require(p["Tag"] == tag and p["Version"] == version, "Package version mismatch")
    require(p["PackagingMode"] == mode, "Package mode mismatch")
    require(p["SourceCommit"] == environment["BUILT_COMMIT"], "Source commit mismatch")
    require(p["AutomationCommit"] == environment["AUTOMATION_COMMIT"], "Automation commit mismatch")
    require(p["SourceRepository"] == environment["GH_REPO"], "Source repository mismatch")
    require(p["OnlineUpdateIntegration"] is False, "Unexpected online update integration")
    require(p["MicrosoftSignedInstaller"] is False, "Unexpected installer signing claim")
    require(p["MsiFile"] == checks["MsiFile"] == expected_name, "MSI filename mismatch")
    with (directory / expected_name).open("rb") as stream:
        actual_hash = hashlib.file_digest(stream, "sha256").hexdigest()
    require(actual_hash == p["MsiSHA256"] == checks["MsiSHA256"], "MSI hash mismatch")
    require(checks["MsiTemplate"].split(";")[0] == "x64", "MSI is not x64")
    require(checks["MsiProductVersion"] == p["MsiProductVersion"], "MSI version mismatch")
    require(re.fullmatch(r"\{[0-9A-Fa-f-]{36}\}", checks["MsiProductCode"]), "Invalid MSI product code")
    upgrade_code = "{39243D76-ADAF-42B1-94FB-16ECF83237C8}" if "-" in version else "{31AB5147-9A97-4452-8443-D9709F0516E1}"
    require(checks["MsiUpgradeCode"].upper() == upgrade_code, "MSI UpgradeCode mismatch")
    require(checks["MsiMetadata"] == checks["StagedPayload"] == "passed", "Package checks failed")
    require(isinstance(payload, list) and len(payload) > 0, "Empty payload inventory")
    require(len(payload) == p["PayloadFiles"] == checks["PayloadFiles"] == len(bom), "Payload inventory count mismatch")
    by_path = {}
    for item in payload:
        path = item["Path"]
        require(isinstance(path, str) and path and "\\" not in path and not path.startswith("/") and ":" not in path and ".." not in path.split("/"), "Invalid payload path")
        require(path not in by_path and re.fullmatch(r"[0-9a-f]{64}", item["SHA256"]), "Invalid or duplicate payload entry")
        by_path[path] = item["SHA256"]
    require(len({item["Pattern"] for item in bom}) == len(bom), "Duplicate BOM patterns")
    require(all(item["Architecture"] == ["x64"] and item["FileType"] in ("Product", "NonProduct") for item in bom), "Invalid BOM entry")

    assets = [expected_name, "SHA256SUMS", "provenance.json", "package-checks.json", "payload-sha256.json", "windows-bom.json"]
    lines = [f"# PowerShell {version} · Windows x64 MSI", ""]
    if mode == "OfficialZIP":
        m = load("official-zip.json")
        originals = load("official-files-sha256.json")
        signatures = load("official-signatures.json")
        require(m["VersionTag"] == tag and m["Version"] == version, "Official ZIP version mismatch")
        require(m["AutomationCommit"] == p["AutomationCommit"] == p["SourceCommit"], "Official ZIP automation mismatch")
        require(m["PrivateTagCommitAtStart"] == environment["TAG_COMMIT_AT_START"], "Official ZIP tag snapshot mismatch")
        require(p["OriginalFilesPreserved"] is True, "Original ZIP files were not preserved")
        require(p["OfficialZipSHA256"] == m["ZIP"]["SHA256"] and p["OfficialReleaseCommit"] == m["ZIP"]["OfficialCommit"], "Official ZIP origin mismatch")
        official_url = f"https://github.com/PowerShell/PowerShell/releases/download/{tag}/PowerShell-{version}-win-x64.zip"
        require(p["OfficialZipURL"] == m["ZIP"]["URL"] == official_url, "Official ZIP URL mismatch")
        require(isinstance(originals, list) and len(originals) == p["OfficialPayloadFiles"] > 0, "Original ZIP inventory count mismatch")
        require(len({item["Path"] for item in originals}) == len(originals), "Duplicate original ZIP files")
        require(all(by_path.get(item["Path"]) == item["SHA256"] for item in originals), "Original ZIP file hash mismatch")
        signed_pwsh = [item for item in signatures if item["Path"] == "pwsh.exe"]
        require(len(signed_pwsh) == 1 and signed_pwsh[0]["Status"] == "Valid" and "Microsoft" in signed_pwsh[0]["SignerSubject"], "Official PowerShell signature mismatch")
        assets += ["official-zip.json", "official-files-sha256.json", "official-signatures.json"]
        title = f"PowerShell {version} x64 MSI (official ZIP payload)"
        lines += ["- 构建方式：官方 ZIP 载荷打包", f"- 载荷来源：[PowerShell {version} Windows x64 ZIP]({official_url})", f"- 官方发行提交：`{p['OfficialReleaseCommit']}`", f"- ZIP SHA-256：`{p['OfficialZipSHA256']}`", "", "官方 ZIP 中的 PowerShell 文件及其现有签名保持不变。"]
    elif mode == "SourceBuild":
        m = load("source-build.json")
        require(m["VersionTag"] == tag and m["Version"] == version, "Source selection version mismatch")
        require(m["SourceCommit"] == p["SourceCommit"] == m["PrivateTagCommitAtStart"] == environment["TAG_COMMIT_AT_START"], "Source selection commit mismatch")
        require(m["AutomationCommit"] == p["AutomationCommit"] and m["SourceRepository"] == p["SourceRepository"], "Source selection automation mismatch")
        assets += ["source-build.json"]
        title = f"PowerShell {version} x64 MSI (source build)"
        source_url = f"https://github.com/{p['SourceRepository']}/tree/{p['SourceCommit']}"
        lines += ["- 构建方式：源码编译后打包", f"- 源码标签：`{tag}`", f"- 源码提交：[{p['SourceCommit']}]({source_url})", f"- .NET SDK：`{p['DotNetSdk']}`", f"- 目标框架：`{p['TargetFramework']}`"]
    else:
        raise ValueError("Unsupported packaging mode")

    sums = {}
    for line in (directory / "SHA256SUMS").read_text(encoding="utf-8-sig").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([^/\\]+)", line)
        require(match and match[2] not in sums, "Invalid checksum manifest entry")
        sums[match[2]] = match[1]
    require(set(sums) == set(assets) - {"SHA256SUMS"}, "Checksum manifest does not cover exactly this build's assets")
    for name, expected in sums.items():
        with (directory / name).open("rb") as stream:
            require(hashlib.file_digest(stream, "sha256").hexdigest() == expected, f"Artifact hash mismatch: {name}")

    lines += ["", f"- MSI 文件：`{expected_name}`", f"- MSI SHA-256：`{actual_hash}`", f"- WiX：`{p['WixVersion']}`", f"- 打包提交：`{p['AutomationCommit']}`", f"- 构建记录：[GitHub Actions]({p['BuildUrl']})", "", "本 MSI 由本仓库自行生成。文件校验与构建信息见 `SHA256SUMS`、`provenance.json` 及随包记录。", ""]
    return title, "\n".join(lines), assets


if __name__ == "__main__":
    directory = Path.cwd()
    title, notes, assets = prepare(directory, os.environ)
    (directory / "release-title.txt").write_text(title + "\n", encoding="utf-8")
    (directory / "release-notes.md").write_text(notes, encoding="utf-8")
    (directory / "release-assets.txt").write_text("\n".join(assets) + "\n", encoding="utf-8")
