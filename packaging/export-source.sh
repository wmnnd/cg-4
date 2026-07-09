#!/usr/bin/env bash
#
# Produce a scrubbed, open-sourceable snapshot of the repository as a .tar.gz.
#
# All private paths (deployment / CI / signing / internal notes) are removed
# with git-filter-repo, so the archive is byte-for-byte what a public source
# repository would contain — the same filter you'd use to seed one. Runs on a
# throwaway clone, so the working repository is never modified.
#
# Usage: export-source.sh [output.tar.gz]   (default: clipgrab-source.tar.gz)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths that must NEVER appear in the public source. Keep this in sync with
# anything private added later (deployment, CI, signing, internal notes).
# ---------------------------------------------------------------------------
PRIVATE_PATHS=(
    .github
    packaging
    cmake/PrepareDependencies.cmake
    CODE_REVIEW.md
    FEATURE_PLANS.md
    PYTHON_OPTIONS.md
    YT_DLP_SIGNATURE_VERIFICATION.md
)

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

OUTPUT="${1:-clipgrab-source.tar.gz}"
mkdir -p "$(dirname "$OUTPUT")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"

if ! command -v git-filter-repo >/dev/null 2>&1; then
    echo "error: git-filter-repo not found." >&2
    echo "  install with: pip install git-filter-repo   (or: apt-get install git-filter-repo)" >&2
    exit 1
fi

# [^)]+ (not [0-9.]+) so pre-release suffixes like 4.0.0-beta1 survive into
# the archive prefix — mirrors the same fix in the CI "Read version" step.
VERSION="$(sed -nE 's/.*set\(CLIPGRAB_VERSION ([^)]+)\).*/\1/p' "$REPO_ROOT/CMakeLists.txt" | head -1)"
PREFIX="clipgrab-${VERSION:-source}/"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Fresh, non-hardlinked clone: git-filter-repo rewrites history in place, so we
# never point it at the real repo. Requires full history (fetch-depth: 0 in CI)
# — filter-repo refuses to operate on a shallow clone.
git clone --quiet --no-local "$REPO_ROOT" "$WORK/repo"
cd "$WORK/repo"

filter_args=()
for p in "${PRIVATE_PATHS[@]}"; do filter_args+=(--path "$p"); done
git filter-repo --force --invert-paths "${filter_args[@]}"

# Fail closed: abort if any private path somehow survived the filter, so a
# mistake here can never leak private content into a published archive.
leaked=0
for p in "${PRIVATE_PATHS[@]}"; do
    if git ls-files --error-unmatch "$p" >/dev/null 2>&1; then
        echo "error: private path '$p' survived filtering — refusing to archive" >&2
        leaked=1
    fi
done
[ "$leaked" -eq 0 ] || exit 1

git archive --format=tar.gz --prefix="$PREFIX" -o "$OUTPUT" HEAD

echo "Wrote scrubbed source archive: $OUTPUT"
echo "Contents:"
tar -tzf "$OUTPUT" | sed 's/^/  /'
