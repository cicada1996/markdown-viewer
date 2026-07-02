#!/bin/bash
# Builds Markdown Viewer.app, installs it into ~/Applications, and makes it
# the default app for .md files.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Markdown Viewer.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Rendering icon…"
./make-icon.sh

echo "Compiling…"
clang -fobjc-arc -O2 \
    -framework Cocoa -framework WebKit -framework UniformTypeIdentifiers \
    Sources/main.m -o "$APP/Contents/MacOS/MarkdownViewer"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/marked.min.js Resources/template.html Resources/AppIcon.icns "$APP/Contents/Resources/"

# Strip extended attributes (e.g. quarantine flags) that break codesign.
xattr -cr "$APP"
codesign --force --sign - "$APP"

echo "Installing to ~/Applications…"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Markdown Viewer.app"
cp -R "$APP" "$HOME/Applications/"

# Tell LaunchServices about the app so Finder sees it as a Markdown handler.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$HOME/Applications/Markdown Viewer.app"

echo "Setting as default app for Markdown files…"
clang -fobjc-arc -framework Cocoa -framework UniformTypeIdentifiers \
    Sources/set_default.m -o build/set_default
./build/set_default "$HOME/Applications/Markdown Viewer.app"

echo "Done: ~/Applications/Markdown Viewer.app"
