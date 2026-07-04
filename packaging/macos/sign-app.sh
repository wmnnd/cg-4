#!/usr/bin/env bash
#
# Code-sign ClipGrab.app inside-out with a Developer ID Application identity
# under the hardened runtime. Signs nested Mach-O binaries first (helpers,
# then frameworks / dylibs), then the app bundle last, as Apple requires.
#
# Usage: sign-app.sh <path-to-ClipGrab.app> <signing-identity>
#
# Expects these files next to this script:
#   entitlements-app.plist   (main bundle — minimal, hardened runtime)
#   entitlements-jit.plist   (deno — needs JIT + unsigned-exec-memory)
#
set -euo pipefail

APP="${1:?path to .app required}"
IDENTITY="${2:?signing identity required}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENT_APP="$HERE/entitlements-app.plist"
ENT_JIT="$HERE/entitlements-jit.plist"

# Common flags: hardened runtime + a secure timestamp (required for
# notarization) + force (re-sign anything macdeployqt ad-hoc signed).
COMMON=(--force --options runtime --timestamp --sign "$IDENTITY")

sign() {  # sign <file> [extra codesign args...]
    local file="$1"; shift
    echo "  signing: ${file#"$APP"/}"
    codesign "${COMMON[@]}" "$@" "$file"
}

echo "==> Signing bundled helper binaries"
DENO="$APP/Contents/MacOS/deno"
FFMPEG="$APP/Contents/MacOS/ffmpeg"
[[ -f "$DENO"   ]] && sign "$DENO"   --entitlements "$ENT_JIT"
[[ -f "$FFMPEG" ]] && sign "$FFMPEG" --entitlements "$ENT_APP"

echo "==> Signing nested frameworks and dylibs (deepest first)"
# Sort by path depth descending so nested code is signed before its container.
while IFS= read -r macho; do
    sign "$macho"
done < <(
    find "$APP/Contents" \( -name '*.dylib' -o -name '*.so' \) -type f \
        -print0 2>/dev/null | xargs -0 -I{} echo {} | awk '{print gsub(/\//,"/"), $0}' \
        | sort -rn | cut -d' ' -f2-
)

# Frameworks are signed as bundles (the .framework dir), not the inner binary.
while IFS= read -r fw; do
    sign "$fw"
done < <(find "$APP/Contents" -name '*.framework' -type d 2>/dev/null \
         | awk '{print gsub(/\//,"/"), $0}' | sort -rn | cut -d' ' -f2-)

echo "==> Signing the app bundle"
sign "$APP" --entitlements "$ENT_APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Signed OK: $APP"
