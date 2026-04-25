# AdvancedTodo v1.4

## What's New

### Whitelist — never block the apps you need
- New **Whitelist** section in Settings → Blocker
- Add any app or website to the whitelist and it will never trigger a reminder or be auto-closed, regardless of what's in the other lists
- **Microsoft apps are always exempt by default** (Word, Excel, PowerPoint, Outlook, Teams, OneNote, Edge, OneDrive, To Do, Visual Studio Code, Visual Studio) — the reminder window will never appear while you're using them
- Reset button restores the default Microsoft whitelist

### Select App — pick from your Applications folder
- Every app list (Reminder Apps, Auto Close Apps, Whitelisted Apps) now has a **Select App** button
- Opens the macOS file picker pointed at `/Applications` so you can browse and add any installed app without typing its name

### Auto Close is now fully list-driven
- **YouTube Shorts, TikTok, Instagram Reels, Snapchat, Reddit, Twitter/X, Facebook, Twitch, Netflix, and more** are now visible entries in the Auto Close Websites list — you can see exactly what gets force-closed and remove anything you don't want
- The old hidden "Auto-close tab on second strike" toggle is replaced by a clear **Enable Auto Close** toggle at the top of the Auto Close section
- When disabled, items in the list still show the reminder popup but nothing is ever force-closed
- Reset restores the full default list

### Expanded gaming website blocklist
- 50+ gaming domains added to the default Reminder Websites list: Steam, Epic Games, GOG, Blizzard, Roblox, Minecraft, EA, Ubisoft, Xbox, PlayStation, itch.io, browser game sites (Poki, CrazyGames, Miniclip, Kongregate, Newgrounds, Armor Games, Cool Math Games), .io multiplayer games (Krunker, Slither, Agar, Diep, MooMoo, Zombs, Surviv), MMOs (RuneScape, World of Warcraft, Genshin Impact), chess and board game sites

### List item deletion — three ways to remove items
- **Click to select** any item in any list, then press **Delete/Backspace** on your keyboard
- A **trash button** appears in the list header when an item is selected
- **Right-click** any item for a context menu with a Remove option
- Works on every list: Reminder Apps, Reminder Websites, Auto Close Apps, Auto Close Websites, Blocked Keywords, Motivational Phrases, Whitelisted Apps, Whitelisted Websites

### Auto-update: launch check + hourly background check
- On every launch the app silently checks for a new version (3-second delay so the window is visible first)
- A background timer checks again **every hour** while the app is running
- Both checks use a **30-second network timeout** so a slow connection never hangs the app
- If a new version is found, the update prompt appears automatically
