#!/bin/bash
# Build a copy of Ember Bar to give to someone else: one app that runs on Apple silicon and Intel Macs (macOS 14+),
# zipped with READ ME FIRST.txt. Output: dist/Ember-Bar-<version>.zip
# Optional: package.sh --release   also uploads the zip as a GitHub release on the private repo.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="$(cat VERSION)"
REPO="ChesterDesmond/ember-bar"
TAG="v$VERSION"

# A release is tagged at HEAD, so its zip must be built from exactly what is committed (untracked files included:
# SwiftPM compiles any .swift file it finds). Checked first, before the slow builds.
if [ "${1:-}" = "--release" ] && [ -n "$(git status --porcelain)" ]; then
  echo "Uncommitted or untracked files: commit them before --release." >&2; exit 1
fi

if ! ./test.sh > dist-test.log 2>&1; then
  tail -40 dist-test.log; echo "Tests failed; not packaging." >&2; exit 1
fi
rm -f dist-test.log

# One build per architecture, then glued with lipo: `swift build --arch arm64 --arch x86_64` needs Xcode's build
# system, and this Mac has Command Line Tools only.
swift build -c release --triple arm64-apple-macosx14.0 --scratch-path .build-arm64
swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build-x86
mkdir -p dist/stage
lipo -create .build-arm64/release/EmberBar .build-x86/release/EmberBar -output dist/EmberBar-universal
STAGE="dist/stage/Ember Bar $VERSION"
rm -rf "$STAGE"; mkdir -p "$STAGE"
scripts/bundle.sh dist/EmberBar-universal "$STAGE"
cp "READ ME FIRST.txt" LICENSE "$STAGE/"
ZIP="dist/Ember-Bar-$VERSION.zip"
rm -f "$ZIP"
# No resource forks or extended attributes: some unzip tools leave them as ._ files inside the app, which breaks
# its signature.
ditto -c -k --norsrc --noextattr --keepParent "$STAGE" "$ZIP"
rm -f dist/EmberBar-universal
echo "Built $(pwd)/$ZIP"

if [ "${1:-}" = "--release" ]; then
  # The repo is on Chester's personal account; use its token without switching gh's active (work) account.
  # Assigned before export so a failed lookup stops the script instead of falling back to the work account.
  TOKEN="$(gh auth token --user ChesterDesmond)"
  export GH_TOKEN="$TOKEN"
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "$ZIP" --repo "$REPO" --clobber
  else
    gh release create "$TAG" "$ZIP" --repo "$REPO" --target "$(git rev-parse HEAD)" --title "Ember Bar $VERSION" \
      --notes "Download the zip, double-click it, and follow READ ME FIRST.txt inside."
  fi
  echo "Uploaded to https://github.com/$REPO/releases/tag/$TAG"
fi
