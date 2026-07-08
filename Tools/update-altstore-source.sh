#!/usr/bin/env bash
#
# update-altstore-source.sh <version> <ipa> [desc] — refresh altstore-source.json with a new iOS release.
# The downloadURL points at the canonical GitHub release asset (github.com/NoopApp/noop/releases);
# noop.fans stays a mirror. Everything else reads CFBundleVersion + size from the IPA,
# prepends/replaces apps[0].versions[0], and mirrors legacy top-level fields.
#
# Run LOCALLY right after the anonymized .ipa is built, then commit altstore-source.json +
# push it (the file is served from the repo so AltStore/SideStore can read it).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/../deploy.env" ] && source "$HERE/../deploy.env"
DOMAIN="${FORGE_DOMAIN:-${NOOP_DOMAIN:-noop.fans}}"
ORG="${FORGE_ORG:-NoopApp}"; REPO="${FORGE_REPO:-noop}"

VERSION="${1:?usage: $0 <version> <ipa> [desc]}"
IPA="${2:?usage: $0 <version> <ipa> [desc]}"
DESC="${3:-"NOOP $VERSION. See the release notes for what changed."}"

# altstore-source.json lives at the repo root; default to the Strand checkout
SRC="${ALTSTORE_SRC:-$HOME/Documents/Strand/altstore-source.json}"
MIN_OS="17.0"

[ -f "$SRC" ] || { echo "✗ $SRC not found (set ALTSTORE_SRC)" >&2; exit 1; }
[ -f "$IPA" ] || { echo "✗ IPA not found: $IPA" >&2; exit 1; }
command -v jq >/dev/null || { echo "✗ jq is required" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unzip -qq "$IPA" -d "$TMP"
PLIST="$(find "$TMP/Payload" -maxdepth 2 -name Info.plist | head -1)"
[ -n "$PLIST" ] || { echo "✗ no Payload/*.app/Info.plist in IPA" >&2; exit 1; }
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
[ "$SHORT" = "$VERSION" ] || echo "⚠ IPA short version=$SHORT but you passed $VERSION (using $VERSION)" >&2

SIZE="$(stat -f%z "$IPA")"
DATE="$(date -u +%Y-%m-%d)"
# GitHub is the canonical download home; the AltStore source must point at the GitHub release asset.
# (noop.fans stays a mirror — the FORGE_* vars above are still used by the deploy/push mechanic.)
URL="https://github.com/${ORG}/${REPO}/releases/download/v${VERSION}/NOOP-v${VERSION}-ios.ipa"

echo "→ $VERSION (build $BUILD), ${SIZE} bytes, $DATE"
jq --arg v "$VERSION" --arg b "$BUILD" --arg d "$DATE" --arg desc "$DESC" \
   --arg url "$URL" --argjson size "$SIZE" --arg min "$MIN_OS" '
  ( {version:$v, buildVersion:$b, date:$d, localizedDescription:$desc,
     downloadURL:$url, size:$size, minOSVersion:$min} ) as $entry
  | .apps[0].versions = ([ $entry ] + ( .apps[0].versions | map(select(.version != $v)) ))
  | .apps[0].version            = $v
  | .apps[0].buildVersion       = $b
  | .apps[0].versionDate        = $d
  | .apps[0].versionDescription = $desc
  | .apps[0].downloadURL        = $url
  | .apps[0].size               = $size
  | .apps[0].minOSVersion       = $min
' "$SRC" > "$SRC.tmp" && mv "$SRC.tmp" "$SRC"
jq empty "$SRC" && echo "✓ altstore-source.json updated for $VERSION"
