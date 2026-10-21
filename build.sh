#!/bin/bash
# Usage: ./build.sh [build|run|release|install|test [scratchdir] [cr2dir]|watch <scratchdir> <cr2dir>|smoke <folder>]
#   install = release build copied to /Applications and launched
# Builds with SwiftPM (no Xcode needed) and wraps the binary in an .app bundle.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")"
MODE="${1:-build}"
if [ "$MODE" = smoke ]; then exec Tools/smoke.sh "${2:-}"; fi
if [ "$MODE" = watch ]; then
    # Folder-watcher test: builds the whole model headless and mutates a scratch folder
    # from outside while it is open. No UI, no keystrokes.
    mkdir -p build
    swiftc -swift-version 5 -target arm64-apple-macos14.0 Sources/Darkslide/Models/*.swift Sources/Darkslide/Services/*.swift Sources/Darkslide/Views/*.swift \
        Tests/Watch/main.swift -o build/watch_tests 2>&1 | grep -E 'error' -A3 || true
    build/watch_tests "${3:?usage: ./build.sh watch <scratch dir> <folder of RAW files to copy from>}" "$2"
    exit $?
fi
if [ "$MODE" = test ]; then
    mkdir -p build
    S=Sources/Darkslide
    swiftc -swift-version 5 -target arm64-apple-macos14.0 \
        $S/Models/PhotoItem.swift $S/Models/PhotoMeta.swift $S/Models/AppSettings.swift \
        $S/Services/Variables.swift $S/Services/RenameEngine.swift $S/Services/IngestEngine.swift \
        $S/Services/ExifTool.swift $S/Services/MetadataStore.swift $S/Services/Shortcuts.swift \
        $S/Services/ImageLoader.swift $S/Services/TIFFPreview.swift $S/Services/GPSTrack.swift \
        $S/Services/ExportEngine.swift $S/Services/ExportExtras.swift $S/Services/Keywords.swift $S/Services/Uploader.swift $S/Services/Catalog.swift $S/Services/FolderScanner.swift $S/Services/CaptionAI.swift $S/Services/Log.swift \
        Tests/main.swift -o build/engine_tests
    build/engine_tests "${2:-/tmp/darkslide-engine-test}" "${3:?usage: ./build.sh test <scratch dir> <folder of RAW files to copy from>}"
    exit $?
fi
CONFIG=debug
[ "$MODE" = release ] || [ "$MODE" = install ] && CONFIG=release
rm -f ".build/$CONFIG/Darkslide"
swift build -c "$CONFIG" --arch arm64 2>&1 | grep -v "^\["
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "BUILD FAILED, nothing installed"; exit 1; }
BIN=".build/$CONFIG/Darkslide"
[ -x "$BIN" ] || { echo "build produced no binary"; exit 1; }
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
# A local self-signed identity keeps macOS folder permissions (Dropbox, Photos) across
# rebuilds; ad-hoc signing is a new identity every build. Falls back to ad-hoc.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"[^"]*Dev"' | head -1 | tr -d '"')}"
codesign --force --sign "${IDENTITY:--}" --identifier com.ghostinthebus.darkslide "$APP" >/dev/null
echo "signed as ${IDENTITY:-ad-hoc}"
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
