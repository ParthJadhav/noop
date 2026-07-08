#!/usr/bin/env bash
#
# anonymize-macos-app.sh — scrub the building machine's home path out of a release
# .app, then re-sign it ad-hoc.
#
# Why: Swift/clang bake source-file path literals (e.g. GRDB's `#file` defaults used in
# its precondition/error messages) into the compiled binary. On a release build these
# include the *builder's* home directory — i.e. your username. This strips that out so a
# distributed binary carries no identity. Run it on the Release app before zipping it up:
#
#     xcodebuild -scheme Strand -configuration Release -derivedDataPath build/dd \
#         -destination 'generic/platform=macOS' ARCHS="x86_64 arm64" ONLY_ACTIVE_ARCH=NO \
#         CODE_SIGNING_ALLOWED=NO build
#     Tools/anonymize-macos-app.sh build/dd/Build/Products/Release/NOOP.app
#
# IMPORTANT: build with the *generic* macOS destination and an explicit universal ARCHS, NOT
# `-destination 'platform=macOS'`. On an Apple-Silicon host the latter resolves to the host's
# active arch and silently thins the binary to arm64 — which is exactly how a release once
# shipped that Intel Macs couldn't launch (#177/#165). Always confirm both slices before zipping:
#     lipo -info build/dd/Build/Products/Release/NOOP.app/Contents/MacOS/NOOP   # -> x86_64 arm64
#
# The replacement is the SAME byte length as the original path, so all Mach-O offsets stay
# valid; only the read-only string section changes. The script reads $HOME at runtime and
# contains no identifying information itself.
set -euo pipefail

APP="${1:?usage: $0 path/to/App.app}"
[ -d "$APP" ] || { echo "no such app bundle: $APP" >&2; exit 1; }

HOME_PATH="$HOME"                       # e.g. /Users/alice
REPL="/Users/builder"                   # generic, anonymous
# Pad or trim REPL to EXACTLY the length of $HOME so byte offsets are preserved.
while [ ${#REPL} -lt ${#HOME_PATH} ]; do REPL="${REPL}_"; done
REPL="${REPL:0:${#HOME_PATH}}"

python3 - "$APP" "$HOME_PATH" "$REPL" <<'PY'
import sys, os, glob
app, home, repl = sys.argv[1], sys.argv[2].encode(), sys.argv[3].encode()
assert len(home) == len(repl), "replacement length must match"
total = 0
scrubbed_files = 0
# Walk the ENTIRE bundle, not just Contents/MacOS. Swift/clang bake the builder home path into
# EVERY Mach-O it compiles, which includes embedded app-extensions (Contents/PlugIns/*.appex,
# e.g. the macOS widget) and frameworks, not only the main executable. Length-preserving
# replacement keeps all Mach-O offsets valid in whatever file it lands in.
for root, _dirs, files in os.walk(app):
    for name in files:
        binp = os.path.join(root, name)
        if os.path.islink(binp) or not os.path.isfile(binp):
            continue
        data = open(binp, "rb").read()
        hits = data.count(home)
        if hits:
            open(binp, "wb").write(data.replace(home, repl))
            total += hits
            scrubbed_files += 1
print(f"scrubbed {total} occurrence(s) of the build home path across {scrubbed_files} file(s)")
PY

# --options runtime applies the Hardened Runtime (CS_RUNTIME), which blocks
# DYLD_INSERT_LIBRARIES dylib injection into the process. Safe: the app uses no JIT.
#
# Re-sign INSIDE-OUT: the scrub above rewrote bytes inside every embedded app-extension and
# framework, invalidating their signatures. A nested binary must be signed BEFORE the outer
# .app or the app's signature will not validate. Sign all nested code first, then the app.
while IFS= read -r nested; do
  [ -e "$nested" ] || continue
  codesign --force --options runtime --sign - "$nested"
done < <(find "$APP/Contents/PlugIns" "$APP/Contents/Frameworks" -mindepth 1 -maxdepth 1 \
           \( -name '*.appex' -o -name '*.framework' -o -name '*.dylib' \) 2>/dev/null)
codesign --force --options runtime --sign - "$APP"
codesign --verify --deep --verbose=1 "$APP"

# Residual check across the WHOLE bundle (main exe + every app-extension binary + frameworks),
# not just Contents/MacOS, so an embedded widget/extension can never ship the builder path.
residual=$(find "$APP" -type f -exec strings -a {} + 2>/dev/null | grep -c "$HOME" || true)
echo "residual home-path hits (whole bundle): ${residual:-0}"
[ "${residual:-0}" -eq 0 ] && echo "✓ clean" || { echo "✗ residual paths remain" >&2; exit 1; }
