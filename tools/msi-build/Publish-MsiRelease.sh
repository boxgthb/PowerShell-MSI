#!/usr/bin/env bash
# Publish either manual build mode to the same versioned MSI assets.
set -euo pipefail
script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "${ARTIFACT_DIRECTORY:-artifacts}"
sha256sum -c SHA256SUMS
python3 "$script_directory/Prepare-Release.py"
mapfile -t assets < release-assets.txt
title=$(cat release-title.txt)

tag_commit() {
    local ref sha type
    if ! ref=$(gh api "repos/$GH_REPO/git/ref/tags/$VERSION_TAG" 2>tag-error.txt); then
        if grep -q 'HTTP 404' tag-error.txt; then printf missing; return; fi
        cat tag-error.txt >&2; return 1
    fi
    sha=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["object"]["sha"])' <<<"$ref")
    type=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["object"]["type"])' <<<"$ref")
    for depth in 1 2 3 4 5 6 7 8; do
        [ "$type" = tag ] || break
        ref=$(gh api "repos/$GH_REPO/git/tags/$sha")
        sha=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["object"]["sha"])' <<<"$ref")
        type=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["object"]["type"])' <<<"$ref")
    done
    test "$type" = commit
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]]
    printf '%s' "$sha"
}
current=$(tag_commit)
test "$current" = "$TAG_COMMIT_AT_START"
if [ "$current" = missing ]; then
    test "$PACKAGING_MODE" = OfficialZIP
    gh api --method POST "repos/$GH_REPO/git/refs" -f "ref=refs/tags/$VERSION_TAG" -f "sha=$AUTOMATION_COMMIT" >/dev/null
fi

prerelease=(--prerelease=false)
if [[ "$VERSION_TAG" == *-* ]]; then prerelease=(--prerelease); fi
if ! gh api "repos/$GH_REPO/releases/tags/$VERSION_TAG" > existing-release.json 2>release-error.txt; then
    if ! grep -q 'HTTP 404' release-error.txt; then cat release-error.txt >&2; exit 1; fi
    printf '{"assets":[]}\n' > existing-release.json
    gh release create "$VERSION_TAG" --verify-tag --draft --title "$title" --notes-file release-notes.md "${prerelease[@]}"
fi
# Replacement of the same filename is intentional for user-selected build modes.
gh release upload "$VERSION_TAG" --clobber "${assets[@]}"
# Remove only obsolete records managed by this workflow, not unrelated user assets.
python3 - <<'PY' > stale-assets.txt
import json
from pathlib import Path
existing = json.loads(Path('existing-release.json').read_text())
current = set(Path('release-assets.txt').read_text().splitlines())
managed = {'official-zip.json', 'official-files-sha256.json', 'official-signatures.json', 'source-build.json', 'installation-test.json', 'upgrade-test.json'}
for asset in existing['assets']:
    name = asset['name']
    if name in managed and name not in current:
        print(name)
PY
while IFS= read -r asset; do
    gh release delete-asset "$VERSION_TAG" "$asset" --yes
done < stale-assets.txt
gh release edit "$VERSION_TAG" --draft=false --title "$title" --notes-file release-notes.md "${prerelease[@]}"
