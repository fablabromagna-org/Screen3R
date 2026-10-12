#!/usr/bin/env bash
#
# Builds both apps without an Xcode project.
# Requirements: a Mac with Xcode or the Command Line Tools (xcode-select --install).
#
#   ./build.sh                      # signs with "Screen3R Dev" / "Apple Development" if present
#   SIGN_ID="Developer ID Application: …" ./build.sh
#   SIGN_ID=- ./build.sh            # force ad-hoc signing
#
set -euo pipefail
cd "$(dirname "$0")"

BUILD=build

# Code signing identity. macOS remembers privacy permissions (Screen Recording!) by the
# app's signature. An ad-hoc signature ("-") changes with every build, so each rebuild
# looks like a different app and loses the permission. A certificate keeps it stable:
# a self-signed "Screen3R Dev" certificate (see README) or an Apple Development one.
if [ -z "${SIGN_ID:-}" ]; then
  for CANDIDATE in "Screen3R Dev" "RetroDisplay Dev" "Apple Development"; do   # (RetroDisplay = old name)
    LINE="$(security find-identity -p codesigning 2>/dev/null | grep -F "\"$CANDIDATE" | head -1 || true)"
    if [ -n "$LINE" ]; then
      SIGN_ID="$(echo "$LINE" | awk '{print $2}')"                    # certificate SHA-1
      echo "==> Signing with: $(echo "$LINE" | sed -E 's/.*"(.*)".*/\1/')"
      break
    fi
  done
fi
if [ -z "${SIGN_ID:-}" ]; then
  SIGN_ID="-"
  echo "==> Signing ad-hoc. Screen Recording permission will have to be granted again after"
  echo "    every build. Create a \"Screen3R Dev\" code signing certificate to avoid this (README)."
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Host/Info.plist)"

rm -rf "$BUILD"
mkdir -p "$BUILD/obj"

# Builds an .icns from a 1024×1024 PNG (Icons/), with sips + iconutil (both part of macOS).
make_icns() {
  local iconset="$BUILD/obj/$(basename "$2" .icns)-$RANDOM.iconset"
  mkdir -p "$iconset"
  for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$1" --out "$iconset/icon_${SIZE}x${SIZE}.png" >/dev/null
    sips -z $((SIZE * 2)) $((SIZE * 2)) "$1" --out "$iconset/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$2"
}

echo "==> Crypto self-test (Shared/rd_crypto.c with CommonCrypto + Security.framework)"
xcrun clang -O2 -I Shared Tests/crypto_test.c Shared/rd_crypto.c Shared/rd_ecdh.c \
  -framework Security -framework CoreFoundation -o "$BUILD/obj/crypto_test"
"$BUILD/obj/crypto_test" > "$BUILD/obj/crypto_test.log" || { cat "$BUILD/obj/crypto_test.log"; exit 1; }
tail -1 "$BUILD/obj/crypto_test.log"
rm -f "$BUILD/obj/crypto_test"

echo "==> Screen3R (host, macOS 13+, universal)"
HOST_APP="$BUILD/Screen3R.app"
mkdir -p "$HOST_APP/Contents/MacOS" "$HOST_APP/Contents/Resources"
cp Host/Info.plist "$HOST_APP/Contents/Info.plist"
make_icns Icons/host-1024.png "$HOST_APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$HOST_APP/Contents/Resources/LICENSE.txt"   # GNU GPL v3: the licence travels with the app
for ARCH in arm64 x86_64; do
  # Shared C code (crypto, same as the viewer's)
  for SRC in Shared/*.c; do
    xcrun clang -c -O2 -Wall -arch "$ARCH" -mmacosx-version-min=13.0 -I Shared \
      "$SRC" -o "$BUILD/obj/$(basename "$SRC" .c)-$ARCH.o"
  done
  xcrun swiftc -O -swift-version 5 -module-name Screen3R \
    -target "$ARCH-apple-macos13.0" \
    -Xcc -I -Xcc Shared \
    -import-objc-header Host/Sources/Bridging.h \
    -framework AppKit -framework CoreGraphics -framework ScreenCaptureKit \
    -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework Network \
    -framework Security \
    Host/Sources/*.swift "$BUILD"/obj/*-"$ARCH".o \
    -o "$BUILD/obj/Screen3R-$ARCH"
done
lipo -create "$BUILD/obj/Screen3R-arm64" "$BUILD/obj/Screen3R-x86_64" \
  -output "$HOST_APP/Contents/MacOS/Screen3R"
# Hardened runtime: blocks DYLD_INSERT_LIBRARIES & co., so no other program can inject code
# into the app and use its Screen Recording permission.
codesign --force --sign "$SIGN_ID" --options runtime --timestamp=none "$HOST_APP"

echo "==> Screen3R Viewer (old Mac, macOS 10.13+, x86_64)"
VIEWER_APP="$BUILD/Screen3R Viewer.app"
mkdir -p "$VIEWER_APP/Contents/MacOS" "$VIEWER_APP/Contents/Resources"
cp Viewer/Info.plist "$VIEWER_APP/Contents/Info.plist"
make_icns Icons/viewer-1024.png "$VIEWER_APP/Contents/Resources/AppIcon.icns"
cp Viewer/Resources/cry.wav "$VIEWER_APP/Contents/Resources/"
cp LICENSE "$VIEWER_APP/Contents/Resources/LICENSE.txt"   # GNU GPL v3: the licence travels with the app
xcrun clang -fobjc-arc -O2 -Wall -Wno-unused-parameter \
  -arch x86_64 -mmacosx-version-min=10.13 -Wl,-headerpad_max_install_names \
  -I Shared \
  -framework Cocoa -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -framework VideoToolbox -framework QuartzCore -framework IOKit -framework Security -framework Carbon \
  Viewer/Sources/*.m Shared/*.c \
  -o "$VIEWER_APP/Contents/MacOS/Screen3RViewer"

# Newer SDKs (seen with the macOS 27 SDK) record some frameworks (CoreMedia, VideoToolbox…)
# as @rpath/libswift<Name>.dylib when targeting old systems. Those libraries do not exist on
# High Sierra (no Swift runtime), so point each reference back to the real framework, which
# exports the same C symbols.
VIEWER_BIN="$VIEWER_APP/Contents/MacOS/Screen3RViewer"
for LIB in $(otool -L "$VIEWER_BIN" | awk '{print $1}' | grep -E '^@rpath/libswift[A-Za-z]+\.dylib$' || true); do
  NAME="$(echo "$LIB" | sed -E 's|@rpath/libswift(.*)\.dylib|\1|')"
  VER="$(readlink "/System/Library/Frameworks/$NAME.framework/Versions/Current" 2>/dev/null || echo A)"
  FRAMEWORK="/System/Library/Frameworks/$NAME.framework/Versions/$VER/$NAME"
  echo "    relinking $LIB -> $FRAMEWORK"
  install_name_tool -change "$LIB" "$FRAMEWORK" "$VIEWER_BIN"
done
if otool -L "$VIEWER_BIN" | grep -E -q 'libswift|@rpath'; then
  echo "ERROR: the viewer links libraries that do not exist on macOS 10.13:" >&2
  otool -L "$VIEWER_BIN" | grep -E 'libswift|@rpath' >&2
  exit 1
fi
codesign --force --sign "$SIGN_ID" --options runtime --timestamp=none "$VIEWER_APP"   # flag ignored before 10.14

echo "==> Packaging"
( cd "$BUILD" && ditto -c -k --keepParent "Screen3R.app" "Screen3R-$VERSION.zip" )
( cd "$BUILD" && ditto -c -k --keepParent "Screen3R Viewer.app" "Screen3R-Viewer-$VERSION.zip" )
rm -rf "$BUILD/obj"

echo
echo "Done:"
echo "  $HOST_APP          -> run on the new Mac"
echo "  $VIEWER_APP   -> copy to the old Mac"
