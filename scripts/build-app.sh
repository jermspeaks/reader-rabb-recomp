#!/bin/sh
# Build "Reader Rabbit's Preschool.app" into dist/.
# The app contains only our code; it reads the game data from your own copy
# of the CD at runtime (chosen on first launch, or passed with --game DIR).
set -eu
cd "$(dirname "$0")/.."

swift build --package-path app -c release
BIN="$(swift build --package-path app -c release --show-bin-path)/ReaderRabbit"
APP="dist/Reader Rabbit's Preschool.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ReaderRabbit"
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
