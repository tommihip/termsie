#!/usr/bin/env bash
#
# Build, sign, notarise and publish a Termsie release.
#
#   ./scripts/release.sh                 # build + sign + notarise, leave the .dmg in dist/
#   ./scripts/release.sh --publish       # ... and cut the GitHub release + update the Homebrew tap
#   ./scripts/release.sh --skip-notarize # local dry run of the whole pipeline, ad-hoc signed
#
# Requires, for a real (notarised) release:
#   * a "Developer ID Application" certificate in the login keychain
#     (Xcode ▸ Settings ▸ Accounts ▸ your team ▸ Manage Certificates ▸ + )
#   * a stored notarytool profile:
#     xcrun notarytool store-credentials termsie \
#       --apple-id <your-apple-id> --team-id 44Y68253MG --password <app-specific-password>
#
set -euo pipefail

APP_NAME="Termsie"
BUNDLE_ID="com.termsie.app"
TEAM_ID="${TEAM_ID:-44Y68253MG}"
NOTARY_PROFILE="${NOTARY_PROFILE:-termsie}"
TAP_REPO="${TAP_REPO:-tommihip/homebrew-tap}"
REPO="${REPO:-tommihip/termsie}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

PUBLISH=0
SKIP_NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
TAG="v$VERSION"
DMG="$DIST/$APP_NAME-$VERSION.dmg"

# ---------------------------------------------------------------- signing identity
if [ "$SKIP_NOTARIZE" = 1 ]; then
  IDENTITY="-"
  say "Dry run: ad-hoc signing, no notarisation"
else
  IDENTITY="$(security find-identity -v -p codesigning \
    | grep 'Developer ID Application' | head -1 \
    | sed -E 's/.*"(.*)"/\1/')"
  if [ -z "$IDENTITY" ]; then
    cat >&2 <<'MSG'
No "Developer ID Application" certificate found in the keychain.

Create one (about twenty seconds, needs no download from the portal):
  Xcode ▸ Settings ▸ Accounts ▸ select your team ▸ Manage Certificates…
  ▸ the + button, bottom left ▸ "Developer ID Application"

Then re-run. To rehearse the whole pipeline without one:
  ./scripts/release.sh --skip-notarize
MSG
    exit 1
  fi
  say "Signing as: $IDENTITY"
fi

# ---------------------------------------------------------------- build (universal)
# `swift build --arch arm64 --arch x86_64` routes through XCBuild, which cannot
# resolve SwiftTerm's build-info plugin. Build each slice with the native
# SwiftPM driver instead and lipo them together.
say "Building universal binary ($VERSION)"
rm -rf "$DIST"
mkdir -p "$DIST"

for triple in arm64-apple-macosx14.0 x86_64-apple-macosx14.0; do
  echo "  ${triple%%-*}"
  swift build -c release --triple "$triple"
done

ARM_BIN="$(swift build -c release --triple arm64-apple-macosx14.0 --show-bin-path)"
X86_BIN="$(swift build -c release --triple x86_64-apple-macosx14.0 --show-bin-path)"

say "Assembling $APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/$APP_NAME" \
  "$ARM_BIN/$APP_NAME" "$X86_BIN/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

# Resource bundles hold compiled Metal shaders and are arch-neutral; take one set.
for b in "$ARM_BIN"/*.bundle; do
  [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Stamp the build number so every release is distinguishable to Gatekeeper.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist"

lipo -info "$APP/Contents/MacOS/$APP_NAME"

# ---------------------------------------------------------------- sign
# Nested code first, then the wrapper. --deep is deprecated and signs things
# in the wrong order for notarisation.
say "Signing"
SIGN_ARGS=(--force --timestamp --options runtime --sign "$IDENTITY")
[ "$IDENTITY" = "-" ] && SIGN_ARGS=(--force --options runtime --sign -)

# SwiftPM resource bundles are often a flat directory with no Info.plist —
# codesign rejects those as bundles, and they are sealed as plain resources of
# the app anyway. Only sign the ones that are real bundles.
while IFS= read -r -d '' nested; do
  if [ -f "$nested/Contents/Info.plist" ] || [ -f "$nested/Info.plist" ]; then
    codesign "${SIGN_ARGS[@]}" "$nested"
  fi
done < <(find "$APP/Contents/Resources" -maxdepth 1 -name '*.bundle' -print0)

codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# ---------------------------------------------------------------- dmg
say "Building disk image"
STAGE="$DIST/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

if [ "$IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi

# ---------------------------------------------------------------- notarise
if [ "$SKIP_NOTARIZE" = 0 ]; then
  say "Notarising (this takes a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  say "Stapling"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  # Gatekeeper's own verdict, which is what a downloading user actually gets.
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
fi

SIZE="$(du -h "$DMG" | cut -f1)"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
say "Built $DMG ($SIZE)"
echo "sha256: $SHA"

# ---------------------------------------------------------------- publish
if [ "$PUBLISH" = 1 ]; then
  say "Publishing $TAG to $REPO"
  git -C "$ROOT" tag -f "$TAG"
  git -C "$ROOT" push -f origin "$TAG"
  NOTES="$ROOT/docs/release-notes.md"
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "$DMG" --repo "$REPO" --clobber
  else
    gh release create "$TAG" "$DMG" \
      --repo "$REPO" \
      --title "$APP_NAME $VERSION" \
      --notes-file "$NOTES"
  fi

  say "Updating the Homebrew cask in $TAP_REPO"
  TAP_DIR="$(mktemp -d)"
  gh repo clone "$TAP_REPO" "$TAP_DIR" -- --depth 1
  mkdir -p "$TAP_DIR/Casks"
  cat > "$TAP_DIR/Casks/termsie.rb" <<CASK
cask "termsie" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/Termsie-#{version}.dmg"
  name "Termsie"
  desc "Native macOS terminal with floating, colour-coded panes in one window"
  homepage "https://termsie.com"

  depends_on macos: ">= :sonoma"

  app "Termsie.app"

  zap trash: [
    "~/.config/termsie",
    "~/Library/Preferences/$BUNDLE_ID.plist",
    "~/Library/Saved Application State/$BUNDLE_ID.savedState",
  ]
end
CASK
  git -C "$TAP_DIR" add Casks/termsie.rb
  git -C "$TAP_DIR" -c user.name="$(git config user.name)" -c user.email="$(git config user.email)" \
    commit -m "termsie $VERSION"
  git -C "$TAP_DIR" push
  rm -rf "$TAP_DIR"

  say "Done. https://github.com/$REPO/releases/tag/$TAG"
fi
