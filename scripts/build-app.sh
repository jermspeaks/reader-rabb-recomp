#!/bin/sh
# Build "Reader Rabbit's Preschool.app" into dist/.
# Pass --game DIR to embed the user's own runtime game files in that local app.
set -eu

GAME_DIR=
APP_NAME="Reader Rabbit's Preschool.app"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --game)
            if [ "$#" -lt 2 ]; then
                echo "Usage: $0 [--game DIR] [--output-name NAME.app]" >&2
                exit 2
            fi
            GAME_DIR=$2
            shift 2
            ;;
        --output-name)
            if [ "$#" -lt 2 ]; then
                echo "Usage: $0 [--game DIR] [--output-name NAME.app]" >&2
                exit 2
            fi
            APP_NAME=$2
            shift 2
            ;;
        *)
            echo "Usage: $0 [--game DIR] [--output-name NAME.app]" >&2
            exit 2
            ;;
    esac
done
case "$APP_NAME" in
    ""|*/*)
        echo "Output name must be a simple .app name inside dist/: $APP_NAME" >&2
        exit 2
        ;;
esac
case "$APP_NAME" in
    *.app) ;;
    *)
        echo "Output name must end in .app: $APP_NAME" >&2
        exit 2
        ;;
esac

CALLER_DIR=$(pwd -P)
if [ -n "$GAME_DIR" ]; then
    case "$GAME_DIR" in
        /*) ;;
        *) GAME_DIR="$CALLER_DIR/$GAME_DIR" ;;
    esac
    if [ ! -d "$GAME_DIR" ]; then
        echo "Game folder not found: $GAME_DIR" >&2
        exit 2
    fi

    find_dat() {
        for directory in RRPDATA rrpdata RRPData; do
            for extension in DAT dat DLL dll; do
                candidate="$GAME_DIR/$directory/$1.$extension"
                if [ -f "$candidate" ]; then
                    printf '%s\n' "$candidate"
                    return 0
                fi
            done
        done
        return 1
    }

    for name in GRAPHIC SPEECH SOUNDS MUSIC; do
        if ! find_dat "$name" >/dev/null; then
            echo "Missing RRPDATA/$name.DAT (or .DLL) in: $GAME_DIR" >&2
            exit 2
        fi
    done
    if [ -f "$GAME_DIR/RRPW32.EXE" ]; then
        GAME_EXE="$GAME_DIR/RRPW32.EXE"
    elif [ -f "$GAME_DIR/rrpw32.exe" ]; then
        GAME_EXE="$GAME_DIR/rrpw32.exe"
    else
        echo "Missing RRPW32.EXE in: $GAME_DIR" >&2
        exit 2
    fi
fi

cd "$(dirname "$0")/.."
swift build --package-path app -c release
BIN="$(swift build --package-path app -c release --show-bin-path)/ReaderRabbit"
APP="dist/$APP_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ReaderRabbit"
if [ -n "$GAME_DIR" ]; then
    GAME_DATA="$APP/Contents/Resources/GameData"
    mkdir -p "$GAME_DATA/RRPDATA"
    for name in GRAPHIC SPEECH SOUNDS MUSIC; do
        source=$(find_dat "$name")
        cp "$source" "$GAME_DATA/RRPDATA/$name.DAT"
    done
    cp "$GAME_EXE" "$GAME_DATA/RRPW32.EXE"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Reader Rabbit's Preschool</string>
    <key>CFBundleDisplayName</key><string>Reader Rabbit's Preschool</string>
    <key>CFBundleIdentifier</key><string>com.github.jermspeaks.reader-rabbit-preschool</string>
    <key>CFBundleExecutable</key><string>ReaderRabbit</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.kids-games</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
