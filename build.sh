#!/bin/bash
# Usage: ./build.sh [build|run|release|install|test [scratchdir] [cr2dir]]
#   install = release build copied to /Applications and launched
# Builds with SwiftPM (no Xcode needed) and wraps the binary in an .app bundle.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")"
MODE="${1:-build}"
if [ "$MODE" = test ]; then
    mkdir -p build
    S=Sources/Darkslide
    swiftc -swift-version 5 -target arm64-apple-macos14.0 \
        $S/Models/PhotoItem.swift $S/Models/PhotoMeta.swift $S/Models/AppSettings.swift \
        $S/Services/Variables.swift $S/Services/RenameEngine.swift $S/Services/IngestEngine.swift \
        $S/Services/ExifTool.swift $S/Services/MetadataStore.swift $S/Services/Shortcuts.swift \
        $S/Services/ImageLoader.swift $S/Services/TIFFPreview.swift $S/Services/GPSTrack.swift \
        $S/Services/ExportEngine.swift $S/Services/ExportExtras.swift $S/Services/Keywords.swift $S/Services/Uploader.swift $S/Services/Catalog.swift $S/Services/FolderScanner.swift $S/Services/CaptionAI.swift \
        Tests/main.swift -o build/engine_tests
    build/engine_tests "${2:-/tmp/darkslide-engine-test}" "${3:?usage: ./build.sh test <scratch dir> <folder of RAW files to copy from>}"
    exit $?
fi
CONFIG=debug
[ "$MODE" = release ] || [ "$MODE" = install ] && CONFIG=release
swift build -c "$CONFIG" --arch arm64 2>&1 | grep -v "^\[" || true
BIN=".build/$CONFIG/Darkslide"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }
APP="build/Darkslide.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Darkslide"
cp Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Bundle exiftool so the app does not depend on Homebrew. The wrapper script looks for
# ./lib next to itself, so the Perl modules go in Resources/exiftool/lib.
ET_BIN="$(readlink -f /opt/homebrew/bin/exiftool 2>/dev/null || true)"
if [ -n "$ET_BIN" ] && [ -f "$ET_BIN" ]; then
    ET_LIB="$(dirname "$ET_BIN")/../libexec/lib/perl5"
    mkdir -p "$APP/Contents/Resources/exiftool"
    cp "$ET_BIN" "$APP/Contents/Resources/exiftool/exiftool"
    [ -d "$ET_LIB" ] && rsync -a --delete "$ET_LIB/" "$APP/Contents/Resources/exiftool/lib/"
fi
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"
if [ "$MODE" = run ]; then
    pkill -x Darkslide 2>/dev/null || true
    open "$APP"
fi
if [ "$MODE" = install ]; then
    pkill -x Darkslide 2>/dev/null || true
    rm -rf "/Applications/Darkslide.app"
    ditto "$APP" "/Applications/Darkslide.app"
    echo "installed /Applications/Darkslide.app"
    open "/Applications/Darkslide.app"
fi
