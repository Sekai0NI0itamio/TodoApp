# AdvancedTodo

AdvancedTodo is a native macOS task manager built with SwiftUI + AppKit integration.
It is designed for people who want an always-visible planning surface to track urgent tasks and long-form notes in one place.

## What the app does

- Keeps the app window always on top so tasks stay visible.
- Lets you create, edit, complete, and delete todo items.
- Sorts todos by urgency (unfinished first by due date, completed items below).
- Supports rich text task descriptions using native `NSTextView`.
  - Paste images directly into task descriptions.
  - Use rich text keyboard shortcuts such as Cmd+B and Cmd+I.
- Shows live countdown text and urgency colors for each task.
- Supports note sidebars (`Work`, `Personal`, `Ideas`, and custom note boards).
  - Fixed `Todo` sidebar is pinned and not deletable.
  - Right-click note sidebars to rename or delete.
  - Drag to reorder note sidebars.
- Persists application state between launches.

## Who it is designed for

This app is designed for builders, founders, and entrepreneurs who need a compact command-center style app to avoid forgetting tasks while collecting ideas and notes at the same time.

Organization statement:

AsdUnionTch is an organization dedicated to providing essential tools for individuals who seek to become entrepreneurs, and this app helps ensure important tasks are not forgotten.

## Build locally

```bash
cd AdvancedTodo
chmod +x build.sh
./build.sh
open AdvancedTodo.app
```

## GitHub workflows

### Test build workflow

- File: `.github/workflows/test-build.yml`
- Purpose: builds the app on macOS and uploads a test artifact.
- Triggers:
  - pushes to `main`
  - pull requests
  - manual dispatch

### Release workflow

- File: `.github/workflows/release.yml`
- Purpose: builds, zips, and publishes a GitHub release.
- Trigger: manual dispatch with:
  - `version`
  - `changelog`
- Release output:
  - tag: `v<version>`
  - release notes include version and changenotes
  - release asset: `AdvancedTodo-<version>.zip`

## In-app update flow

The app includes a menu action to check GitHub releases for updates. When a newer release is found, users can review:

- current app version
- new version
- asset size
- release changelog/new features

The update installer performs:

1. Backup of app data into a zipped backup folder.
2. Download of the selected GitHub release zip.
3. User confirmation before replacing the existing app.
4. App replacement and relaunch.
