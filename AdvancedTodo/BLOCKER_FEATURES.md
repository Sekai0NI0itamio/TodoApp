# Focus Blocker — Feature Summary

## What It Does

The Focus Blocker monitors which app and window you're using. When it detects a distracting app or website (like YouTube Shorts, Instagram, TikTok, Discord, Steam, etc.), it shows a full-screen reminder with your pending tasks and a motivational message.

**New in this version:** 
- On the **second consecutive detection** of a "shorts-type" distraction (YouTube Shorts, TikTok, Instagram, Reddit, etc.), the app **automatically closes the browser tab** — but only the distracting tab, not the whole browser or other tabs.
- **Configurable block duration**: Set how long the blocker prompt stays on screen (default: 60 seconds / 1 minute, range: 10-600 seconds).
- **Debug mode**: Enable in settings to see detailed console logs of what the blocker is detecting.
- **Auto-sync permissions**: Permission state is automatically synced when you return to the app from System Settings.
- **Window close prevention**: Prevents accidental closing/minimizing of the todo window with confirmation dialog.
- **Auto-reopen window**: Optionally auto-reopens the window after a configurable delay (default: 5 minutes).

---

## How It Works

### 3-Layer Detection Engine

**Layer 1: App Name / Bundle ID**
- Catches standalone apps like Discord, Steam, Minecraft, TikTok app, Spotify, etc.
- Matches against your blocked apps list

**Layer 2: Window Titles (CGWindowListCopyWindowInfo)**
- Reads all visible window titles on screen (no extra permission needed)
- Catches browser tabs showing distracting content (YouTube Shorts in Safari, Instagram in Chrome, etc.)

**Layer 3: Focused Window Title (AXUIElement)**
- Uses the Accessibility API to read the exact title of the focused window
- More reliable for the active browser tab
- Requires granting Accessibility permission in System Settings → Privacy & Security → Accessibility

### Event-Driven Detection

- Subscribes to `NSWorkspace.didActivateApplicationNotification` for instant detection when you switch apps
- Also polls every 6 seconds as a backup for title changes within the same app

---

## Auto-Close Behavior

**Strike 1:** Distraction detected → show popup with tasks and motivational message

**Strike 2:** Distraction detected again (you dismissed the popup but went back to shorts/distracting content) → **auto-close the tab**

**What gets auto-closed:**
- YouTube Shorts, YouTube videos, TikTok, Instagram, Reddit, Twitter/X, Facebook, Snapchat, Twitch, Netflix, etc.
- Anything classified as a "shorts-type" browser-based distraction

**What NEVER gets auto-closed:**
- Standalone apps like Discord, Steam, WeChat, Slack, etc. — these are not browser tabs
- Chat apps, productivity tools, or anything that's not a browser window

**How it closes:**
- Sends `Cmd+W` to the focused browser window via the Accessibility API
- Only closes the active tab, not the whole browser
- Requires Accessibility permission to be granted

**Strike counter resets when:**
- You switch to a clean app/website (no distraction detected)
- You switch to a non-shorts distraction (e.g. Discord — shows popup but doesn't count as a strike)

---

## Permissions Required

**App Monitoring (NSWorkspace)** — Required
- Allows reading the frontmost app name and bundle ID
- No special system permission needed — just toggle it on in settings
- No data leaves your device

**Accessibility (AXUIElement)** — Optional but Recommended
- Enables reading the exact focused window title (catches browser tabs more reliably)
- Enables auto-closing distracting tabs on strike 2
- **Setup**: 
  1. Open System Settings → Privacy & Security → Accessibility
  2. Click the + button and add AdvancedTodo
  3. Restart the app
  4. Toggle "Accessibility Permission Granted" in app settings
- **Auto-sync**: The app automatically detects when you've granted permission and updates the toggle

---

## Default Blocklist

### Blocked Apps (30+)
Discord, WeChat, Instagram, Telegram, WhatsApp, Messenger, Signal, Slack, Messages, TikTok, Snapchat, Steam, Minecraft, Prism Launcher, TLauncher, Epic Games Launcher, GOG Galaxy, Battle.net, Heroic Games Launcher, Riot Client, League of Legends, Origin, EA, Roblox, Spotify, Apple Music, Music, TV, Netflix, Prime Video, Disney+, Plex, VLC, Twitch

### Blocked Websites (20+)
instagram.com, tiktok.com, facebook.com, twitter.com, x.com, snapchat.com, threads.net, reddit.com, youtube.com, twitch.tv, netflix.com, primevideo.com, disneyplus.com, hulu.com, discord.com, web.whatsapp.com, web.telegram.org, news.ycombinator.com, 9gag.com, tumblr.com

### Blocked Keywords (15+)
shorts, reels, tiktok, reel, minecraft, steam, roblox, fortnite, valorant, instagram, twitter, reddit, facebook, netflix, spotify, twitch

### Motivational Phrases (10)
- Small focus now creates big freedom later.
- Discipline is a gift to your future self.
- Finish what matters before what distracts.
- Stay with the work. You are building momentum.
- Every minute you protect is a minute invested in your future.
- The work is the reward. Start.
- You don't need motivation. You need to begin.
- Close the tab. Open the task.
- Your future self is watching. Make them proud.
- One focused hour beats ten distracted ones.

---

## Settings

Open Settings (gear icon in toolbar) → Blocker

**Enable Focus Blocker** — Master toggle

**App Monitoring Permission Granted** — Toggle on to allow reading frontmost app

**Accessibility Permission Granted** — Toggle on after granting in System Settings (enables auto-close)

**Also block YouTube videos (not just Shorts)** — When on, any YouTube window is blocked (YouTube Music excluded)

**Auto-close tab on second strike** — When enabled, shorts-type distractions are automatically closed on the second consecutive detection

**Block Duration** — How long (in seconds) the blocker prompt stays on screen before you can be interrupted again. Default: 60 seconds (1 minute). Range: 10-600 seconds.

**Prevent accidental window closing** — When enabled, shows a confirmation dialog before closing or minimizing the todo window.

**Auto-reopen window** — When enabled, provides a "Close & Auto-Reopen" option in the confirmation dialog that will automatically reopen the window after the specified delay.

**Reopen after X minutes** — Configurable delay for auto-reopen (default: 5 minutes, range: 1-60 minutes).

**Blocked Apps / Websites / Keywords / Motivational Phrases** — Add/remove items from each list

---

## Debugging Detection Issues

If the blocker isn't detecting distractions:

1. **Enable Debug Mode** in Settings → General → Debug Mode
2. **Open Console.app** (Applications → Utilities → Console)
3. **Filter for "Blocker"** in the search box
4. **Switch to the distracting app/website** and watch the console output
5. You should see logs like:
   - `[Blocker] Checking app: Safari (com.apple.safari)`
   - `[Blocker] Is browser: true`
   - `[Blocker] Layer 2 checking window: YouTube Shorts - ...`
   - `[Blocker] Layer 2 match (window title): YouTube Shorts`

If you don't see any logs:
- Make sure "Enable Focus Blocker" is ON
- Make sure "App Monitoring Permission Granted" is ON
- Try switching apps to trigger detection

If you see logs but no matches:
- Check that the window title contains keywords from your blocklist
- Add the specific keyword or website to your blocklist in settings

---

## Troubleshooting

**Window is too small / stuck at tiny size:**
- Go to menu bar → Debug → Reset Window Size
- This will restore the window to its default size

**Accessibility permission not working:**
- Make sure you've added AdvancedTodo in System Settings → Privacy & Security → Accessibility
- Restart the app after granting permission
- Toggle "Accessibility Permission Granted" in app settings
- The toggle should auto-sync when you return to the app

**Auto-close not working:**
- Make sure Accessibility permission is granted (see above)
- Check that "Auto-close tab on second strike" is enabled in settings
- The tab will only close on the second consecutive shorts-type detection
- Enable Debug Mode to see detection logs in Console.app

**Window keeps closing accidentally:**
- Enable "Prevent accidental window closing" in Settings → Blocker
- This will show a confirmation dialog before closing or minimizing
- You can also enable "Auto-reopen window" to automatically reopen after a delay

**Auto-reopen not working:**
- Make sure "Prevent accidental window closing" is enabled
- Make sure "Auto-reopen window" is enabled
- Choose "Close & Auto-Reopen" in the confirmation dialog (not "Close Anyway")
- The window will reopen after the configured delay

---

## Technical Details

- Detection runs every 6 seconds + instant on app switch
- Popup cooldown: configurable (default 60 seconds, range 10-600 seconds)
- Strike counter: tracks consecutive shorts-type detections
- Auto-close: sends `Cmd+W` via `CGEvent.postToPid()` to the browser process
- Debug mode: prints detailed detection logs to console for troubleshooting
- All data stays on your device — no network requests, no tracking
- Built with SwiftUI + AppKit + Accessibility API
