#!/usr/bin/env bash
#
# Build, sign, notarise and publish a Termsie release.
#
#   ./scripts/release.sh                 # build + sign + notarise, leave the .dmg in dist/
#   ./scripts/release.sh --publish       # ... and cut the GitHub release + update the Homebrew tap
#   ./scripts/release.sh --skip-notarize # local dry run of the whole pipeline, ad-hoc signed
#
#   ./scripts/release.sh --version 0.7.0 --publish
#       set the version in Info.plist and AppInfo.version first; with --publish the
#       bump is committed as "chore: release 0.7.0" so the tag points at it
#
# --publish refuses to run when the version's tag or GitHub release already exists,
# because it would move the tag, replace the dmg and rewrite the cask under the same
# version. Add --force to overwrite that release on purpose.
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

PLIST="$ROOT/Resources/Info.plist"
APPINFO="$ROOT/Sources/Termsie/Terminal/TerminalPane.swift"

PUBLISH=0
SKIP_NOTARIZE=0
FORCE=0
NEW_VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --publish) PUBLISH=1 ;;
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --force) FORCE=1 ;;
    --version)
      [ $# -ge 2 ] || { echo "--version needs a value, e.g. --version 0.7.0" >&2; exit 2; }
      NEW_VERSION="$2"
      shift
      ;;
    --version=*) NEW_VERSION="${1#--version=}" ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -n "$NEW_VERSION" ] && ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "--version must look like 1.2.3, got: $NEW_VERSION" >&2
  exit 2
fi
if [ "$FORCE" = 1 ] && [ "$PUBLISH" = 0 ]; then
  echo "--force only applies together with --publish" >&2
  exit 2
fi

say() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

VERSION="${NEW_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")}"
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

# ---------------------------------------------------------------- existing release guard
# Checked before the version bump and the build, so a refusal leaves the tree
# untouched and costs seconds rather than a notarisation round trip. Lookups that
# fail for any reason other than "not there" abort instead of counting as absent.
if [ "$PUBLISH" = 1 ]; then
  EXISTING=""
  if git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    EXISTING="local tag"
  fi
  REMOTE_TAG="$(git -C "$ROOT" ls-remote --tags origin "refs/tags/$TAG")"
  if [ -n "$REMOTE_TAG" ]; then
    EXISTING="${EXISTING:+$EXISTING, }tag on origin"
  fi
  if GH_ERR="$(gh release view "$TAG" --repo "$REPO" 2>&1 >/dev/null)"; then
    EXISTING="${EXISTING:+$EXISTING, }GitHub release"
  elif [[ "$GH_ERR" != *"release not found"* ]]; then
    echo "Could not check whether $TAG is already released on $REPO:" >&2
    echo "  $GH_ERR" >&2
    exit 1
  fi

  if [ -n "$EXISTING" ]; then
    if [ "$FORCE" = 0 ]; then
      cat >&2 <<MSG
$TAG already exists ($EXISTING).

Publishing again would move the tag to HEAD, replace the dmg and rewrite the
Homebrew cask, all under the same version number.

Cut a new release instead:
  ./scripts/release.sh --version <next version> --publish
Overwrite $TAG on purpose:
  ./scripts/release.sh ${NEW_VERSION:+--version $NEW_VERSION }--publish --force
MSG
      exit 1
    fi
    say "$TAG already exists ($EXISTING); --force given, it will be overwritten"
  fi
fi

# ---------------------------------------------------------------- version bump
if [ -n "$NEW_VERSION" ]; then
  say "Setting version to $VERSION"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
  sed -i '' -E "s/(static let version = \")[^\"]*(\")/\\1$VERSION\\2/" "$APPINFO"
  if ! grep -qF "static let version = \"$VERSION\"" "$APPINFO"; then
    echo "Could not set AppInfo.version in $APPINFO" >&2
    exit 1
  fi

  # The tag is placed on HEAD, so the bump has to be in a commit for the tag to
  # match what was built. Only the two version files go in; nothing else staged.
  if [ "$PUBLISH" = 1 ] && ! git -C "$ROOT" diff --quiet HEAD -- "$PLIST" "$APPINFO"; then
    git -C "$ROOT" commit -q -m "chore: release $VERSION" -- "$PLIST" "$APPINFO"
    echo "  committed \"chore: release $VERSION\" ($(git -C "$ROOT" rev-parse --short HEAD))"
  fi
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
  if [ "$FORCE" = 1 ]; then
    git -C "$ROOT" tag -f "$TAG"
    git -C "$ROOT" push -f origin "$TAG"
  else
    git -C "$ROOT" tag "$TAG"
    git -C "$ROOT" push origin "$TAG"
  fi
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
