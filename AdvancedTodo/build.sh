#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./build.sh
  ./build.sh --release <changes.md> --version <x.y.z>

Behavior:
  - Every successful build auto-creates a git commit (if there are changes).
  - --release also updates version, pushes commit, creates zip, and publishes GitHub release.
USAGE
}

RELEASE_MODE=false
CHANGELOG_FILE=""
RELEASE_VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      RELEASE_MODE=true
      shift
      [[ $# -gt 0 ]] || { echo "Error: --release requires a changelog file path"; usage; exit 1; }
      CHANGELOG_FILE="$1"
      ;;
    --version)
      shift
      [[ $# -gt 0 ]] || { echo "Error: --version requires a value"; usage; exit 1; }
      RELEASE_VERSION="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"
APP_NAME="AdvancedTodo"
APP_DIR="$PROJECT_DIR/$APP_NAME.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
PLIST="$APP_DIR/Contents/Info.plist"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
ICONSET_DIR="$PROJECT_DIR/Build/Todo.iconset"
ICON_FILE="$RESOURCES_DIR/Todo.icns"
REPO_ROOT="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"

if [[ "$RELEASE_MODE" == "true" ]]; then
  [[ -n "$RELEASE_VERSION" ]] || { echo "Error: --release requires --version"; exit 1; }
  [[ -f "$CHANGELOG_FILE" ]] || { echo "Error: changelog file not found: $CHANGELOG_FILE"; exit 1; }
  if [[ -z "$REPO_ROOT" ]]; then
    echo "Error: release mode requires a git repository"
    exit 1
  fi

  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $RELEASE_VERSION" "$PROJECT_DIR/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M%S)" "$PROJECT_DIR/Info.plist"
fi

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

# Compile all Swift source files into the executable inside the app bundle.
# Use -parse-as-library so @main attribute works in this context.
SOURCE_FILES=$(find Sources -name '*.swift' | sort)
xcrun --sdk macosx swiftc $TARGET -parse-as-library $SOURCE_FILES -o "$BIN_DIR/$APP_NAME" -framework Cocoa -framework SwiftUI

# Copy Info.plist into bundle
cp Info.plist "$PLIST"

# Ensure a consistent signature for distributed builds.
# This avoids broken-signature errors like "app is damaged" after download.
codesign --force --deep --sign - "$APP_DIR"

echo "Build complete: $APP_DIR"

if [[ -n "$REPO_ROOT" ]]; then
  PROJECT_BASENAME="$(basename "$PROJECT_DIR")"
  git -C "$REPO_ROOT" add -A "$PROJECT_BASENAME"
  if ! git -C "$REPO_ROOT" diff --cached --quiet; then
    COMMIT_MSG="build: update app bundle artifacts"
    if [[ "$RELEASE_MODE" == "true" ]]; then
      COMMIT_MSG="release: v$RELEASE_VERSION"
    fi
    git -C "$REPO_ROOT" commit -m "$COMMIT_MSG"
    echo "Created commit: $COMMIT_MSG"
  else
    echo "No changes to commit after build."
  fi
fi

if [[ "$RELEASE_MODE" == "true" ]]; then
  ZIP_NAME="AdvancedTodo-$RELEASE_VERSION.zip"
  ZIP_PATH="$PROJECT_DIR/$ZIP_NAME"
  rm -f "$ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

  git -C "$REPO_ROOT" push origin "$(git -C "$REPO_ROOT" branch --show-current)"

  if ! command -v gh >/dev/null 2>&1; then
    echo "Error: GitHub CLI (gh) is required for --release"
    exit 1
  fi

  gh release create "v$RELEASE_VERSION" "$ZIP_PATH" \
    --title "AdvancedTodo v$RELEASE_VERSION" \
    --notes-file "$CHANGELOG_FILE"

  echo "Release published: v$RELEASE_VERSION"
fi
