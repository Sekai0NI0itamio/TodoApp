# AdvancedTodo v2.0

## What's New

### Focus Timer System
- Full-screen intelligent timer popup when a distraction is detected
- Choose from Quick (10m relax / 30m work), Standard (20m / 40m), or Deep Work (30m / 60m) sessions
- Custom session builder with sliders and manual minute input
- Menu bar countdown shows remaining relax or work time live
- During work phase, entertainment tabs are closed instantly (1-second polling)
- Two-stage warning: orange toast banner first, then full-screen prompt after 60 seconds

### Reflections
- After each work session, log what you accomplished and rate the session (1–5 stars)
- All past sessions stored and viewable in the Reflections sidebar tab
- Voluntary session launcher in Reflections — start a session any time without a distraction trigger

### Screen Time
- Automatic 30-second app usage sampling while the app is running
- Three stat cards: Computer Use, Entertainment time, Focus Work time
- 24-hour stacked bar chart showing activity across the day (work / entertainment / other)
- Per-app breakdown with proportional bars and health colour coding
  - Green = low entertainment, Orange = moderate, Red = high entertainment / low work
- 7-day history with day picker

### General Settings
- **Always on Top** toggle — keep the window floating above everything, or let it behave like a normal window
- **Menu Bar Icon** toggle — adds a ✓ icon to the macOS menu bar
  - Click to open a compact todo popover: add tasks, check them off, see focus session status
  - Closing the popover keeps the app running in the background

### YouTube Shorts & Detection Fixes
- Reads the browser address bar via Accessibility API for accurate URL-based detection
- YouTube Shorts (`/shorts/`) detected reliably regardless of video title
- Non-browser apps (VS Code, Kiro, terminals) no longer trigger false positives
- Word-boundary matching prevents short domain names like "x" from matching unrelated titles

### Sidebar Reorganisation
- Order: Todo → Note boards → Reflections → Screen Time → Trash (always last)
