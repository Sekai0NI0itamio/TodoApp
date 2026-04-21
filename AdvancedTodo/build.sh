#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"
APP_NAME="AdvancedTodo"
APP_DIR="$PROJECT_DIR/$APP_NAME.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
PLIST="$APP_DIR/Contents/Info.plist"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
ICONSET_DIR="$PROJECT_DIR/Build/Todo.iconset"
ICON_FILE="$RESOURCES_DIR/Todo.icns"

rm -rf "$APP_DIR"
rm -f "$PROJECT_DIR/Todo.icns"
mkdir -p "$BIN_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$(dirname "$ICONSET_DIR")"

# Choose target based on host architecture
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
  TARGET="-target arm64-apple-macos13.0"
else
  TARGET="-target x86_64-apple-macos13.0"
fi

echo "Compiling for architecture: $ARCH"

# Generate a rounded app icon from Todo.png using Apple's iconutil toolchain.
rm -rf "$ICONSET_DIR"
swift Scripts/make_iconset.swift Todo.png "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"

# Refresh Finder's view of the app bundle icon.
touch "$APP_DIR"

# Compile Swift source into the executable inside the app bundle
# Use -parse-as-library so @main attribute works in this context
xcrun --sdk macosx swiftc $TARGET -parse-as-library Sources/main.swift -o "$BIN_DIR/$APP_NAME" -framework Cocoa -framework SwiftUI

# Copy Info.plist into bundle
cp Info.plist "$PLIST"

echo "Build complete: $APP_DIR"
