#!/usr/bin/env bash
#
# make-release.sh — package a notarized Blaze.app into a DMG and publish a
# tagged GitHub release with the DMG attached.
#
# Usage:
#   scripts/make-release.sh <version> [path/to/Blaze.app]
#
#   <version>        e.g. 1.1.2  (the git tag becomes v1.1.2)
#   path/to/Blaze.app  the notarized, exported app. If omitted, the script
#                      looks for ./dist/Blaze.app, then the most recent
#                      Xcode archive's exported app.
#
# The app must already be notarized (Xcode Organizer → Distribute →
# Direct Distribution, or `notarytool submit`). This script staples the
# ticket if it isn't stapled yet, but it does not submit for notarization.
#
# Requires: hdiutil, codesign, xcrun stapler, shasum, git, gh (authenticated).

set -euo pipefail

# ---- args -------------------------------------------------------------------

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <version> [path/to/Blaze.app]" >&2
    exit 2
fi

VERSION="$1"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version must look like 1.1.2 (got '$VERSION')" >&2
    exit 2
fi
TAG="v$VERSION"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ---- locate the app ---------------------------------------------------------

APP="${2:-}"
if [[ -z "$APP" ]]; then
    if [[ -d "dist/Blaze.app" ]]; then
        APP="dist/Blaze.app"
    else
        APP="$(ls -dt "$HOME"/Library/Developer/Xcode/Archives/*/*.xcarchive/Products/Applications/Blaze.app 2>/dev/null | head -1 || true)"
    fi
fi
if [[ -z "$APP" || ! -d "$APP" ]]; then
    echo "error: could not find Blaze.app — pass its path as the 2nd argument" >&2
    echo "       (export it from the Organizer first; the archive copy is not stapled)" >&2
    exit 1
fi
echo "==> app:     $APP"
echo "==> version: $VERSION  (tag $TAG)"

# ---- verify signature + notarization ---------------------------------------

echo "==> verifying code signature"
codesign --verify --deep --strict --verbose=1 "$APP"

# Staple if the ticket isn't embedded yet (no-op if already stapled). This
# only succeeds once Apple has finished notarizing *this exact binary*.
if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
    echo "==> stapling notarization ticket"
    if ! xcrun stapler staple "$APP"; then
        cat >&2 <<EOF

error: could not staple a notarization ticket to this app.

  "Record not found" means Apple has no accepted ticket for this exact
  binary — it has not been notarized yet. Common causes:

    * You pointed at the archive's app
      (…xcarchive/Products/Applications/Blaze.app). That copy is never
      notarized — export it first (Organizer → Distribute → Direct
      Distribution → Export) and pass the exported app instead.

    * Notarization never completed. Check with:
        xcrun notarytool history --keychain-profile blaze-notary
      and submit this app if needed:
        ditto -c -k --keepParent "$APP" /tmp/Blaze.zip
        xcrun notarytool submit /tmp/Blaze.zip --keychain-profile blaze-notary --wait
      then re-run this script once it reports "Accepted".
EOF
        exit 1
    fi
fi

echo "==> Gatekeeper assessment"
if ! spctl -a -vv "$APP" 2>&1 | tee /tmp/blaze-spctl.txt | grep -q "source=Notarized Developer ID"; then
    echo "error: app is not notarized/accepted by Gatekeeper — refusing to release" >&2
    cat /tmp/blaze-spctl.txt >&2
    exit 1
fi

# ---- build the DMG ----------------------------------------------------------

OUT_DIR="$REPO_ROOT/dist"
mkdir -p "$OUT_DIR"
DMG="$OUT_DIR/Blaze-$VERSION.dmg"
rm -f "$DMG"

echo "==> building $DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"          # drag-to-install affordance
hdiutil create -volname "Blaze $VERSION" \
    -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# Staple the DMG too, so Gatekeeper validates the container before it's opened.
xcrun stapler staple "$DMG" || echo "warning: could not staple the DMG (the .app inside is still stapled)"

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "==> sha256:  $SHA"

# ---- tag + release ----------------------------------------------------------

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "warning: working tree has uncommitted changes; the tag will point at HEAD ($(git rev-parse --short HEAD))"
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "==> tag $TAG already exists, reusing it"
else
    echo "==> tagging $TAG"
    git tag "$TAG"
    git push origin "$TAG"
fi

NOTES="$(cat <<EOF
Blaze $VERSION — native macOS SD/microSD image flasher.

Requires macOS 26. Notarized for Gatekeeper. On first launch: install the
privileged helper (one admin prompt) and grant Full Disk Access when asked.

**Download:** \`Blaze-$VERSION.dmg\`
**SHA-256:** \`$SHA\`

Verify after downloading:
\`\`\`
shasum -a 256 Blaze-$VERSION.dmg
\`\`\`
EOF
)"

echo "==> creating GitHub release $TAG"
gh release create "$TAG" "$DMG" \
    --title "Blaze $VERSION" \
    --notes "$NOTES"

echo "==> done: $(gh release view "$TAG" --json url --jq .url)"
