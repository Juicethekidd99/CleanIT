# CleanIT for Mac

The macOS version of CleanIT: same idea, same look, same rules as the Windows version - honest, transparent,
everything logged, nothing removed that can't be put back (files, apps and leftovers go to the Trash).

> **Status: early (v0.1.0).** Clean, Disk, Startup, Apps, Security and Health are tested on macOS 15 (Intel).
> Review every list before you click.

## Requirements
macOS 12 or newer (Intel or Apple silicon). To build: Xcode or the Command Line Tools (Swift 5.9+).

## Install (download)
1. Download [CleanIT-Mac.zip](https://github.com/Juicethekidd99/CleanIT/releases/latest/download/CleanIT-Mac.zip) and double-click it to unzip.
2. Drag **CleanIT** into your **Applications** folder.
3. Open it. The first time, macOS says it can't check the app (it is not notarized by Apple yet): click **Done**, then open
   **System Settings > Privacy & Security**, scroll down and click **Open Anyway** next to CleanIT. You only do this once.

Works on Intel and Apple silicon Macs.

## Build it yourself
```bash
cd mac
./build.sh --open          # builds mac/build/CleanIT.app (universal) and opens it
```
Then drag `build/CleanIT.app` into **Applications** (needed for the weekly clean and Full Disk Access).
The build is ad-hoc signed; the first time, right-click CleanIT > **Open** if macOS asks.

## How it works
`CleanIT.app` is a small Swift program. Its window shows the same web UI as Windows (`web/app.js` is the Mac
version of `../web/app.js`; `app.css` is shared and copied in by `build.sh`). The page talks to the Swift engine
through a WebKit message handler using the same `/api/...` paths as the Windows server - no network server,
no open port.

## Tabs
| Tab | What it does |
|---|---|
| Dashboard | Health score, Smart Scan, free space, startup items, updates waiting, problems found |
| Clean | 19 junk categories (Mac / Browsers / Apps / Developer). Caches of open apps are skipped |
| Disk | Space analyzer, large-file finder ("not opened in N days"), duplicate finder (SHA-256, hard-link aware). Files only go to the Trash |
| Startup | Launch Agents, Launch Daemons, Login Items with code-signature check. Uses launchd's own on/off switch (plists are never deleted). Undo all |
| Apps | Uninstaller (app to the Trash) + strict leftover finder (exact bundle id or app name in ~/Library and /Library) |
| Updates | macOS Software Update with Important/Recommended/Optional advice; Homebrew formulae and casks with a "never update" list |
| Security | macOS support status, FileVault, firewall, SIP, Gatekeeper, automatic updates, XProtect, auto-login, SSH/Screen Sharing, unsigned startup items |
| Health | Model, memory, uptime, SSD SMART, Time Machine, battery cycles/capacity, crashes and kernel panics (30 days), flush DNS |
| Fleet | Health cards for all your Macs **and PCs** in one shared folder (OneDrive "CleanIT Fleet", or any folder you pick). Same report format as Windows, so this Mac also shows up on your PCs' Fleet page |
| Settings | Full Disk Access status, weekly clean (LaunchAgent), undo center, logs |

## Cleanup categories
| Key | Default | Notes |
|---|---|---|
| UserCaches | on | ~/Library/Caches; skips open apps, iCloud/CloudKit, Find My, Home, keychain/security caches |
| UserLogs | on | ~/Library/Logs older than 7 days (CleanIT's own logs kept) |
| TempFiles | on | $TMPDIR, older than 3 days |
| DeviceUpdates | on | iPhone/iPad .ipsw downloads |
| MailDownloads | on | Mail's copies of opened attachments (needs Full Disk Access) |
| OldInstallers | off | .dmg/.pkg in Downloads older than 30 days - to the Trash |
| Trash | off | Empties the Trash (warning shown; needs Full Disk Access) |
| BrowserCache | on | Safari, Chrome, Edge, Brave, Arc, Vivaldi, Opera, Firefox - caches only |
| Discord / Spotify / Slack / Teams / VSCode / Steam | on | Caches only |
| AdobeCache | off | Premiere/AE media cache |
| XcodeDerivedData / XcodeDeviceSupport / SimulatorCaches | off | Developer caches, rebuilt when needed |
| DevCaches | off | npm, Yarn, pnpm, pip, Homebrew, CocoaPods, SwiftPM, Go, Gradle, Cargo |

## Command line
```bash
C=/Applications/CleanIT.app/Contents/MacOS/CleanIT
$C --scan                                   # reclaimable space (default categories)
$C --clean                                  # clean defaults
$C --clean --categories UserCaches,BrowserCache
$C --list-categories
$C --startup [--all]                        # list startup items (--all includes Apple's)
$C --report                                 # health + security report
$C --updates                                # Homebrew upgrades (honours the "never update" list)
$C --fleet                                  # write this Mac's report to the fleet folder now
```

## Fleet with your PCs
Your PCs keep their reports in `OneDrive\CleanIT Fleet`. To add this Mac: install **OneDrive for Mac** (free, App Store),
sign in with the same Microsoft account, then **CleanIT > Fleet > Join my fleet in OneDrive**. The Mac writes its report
after every scan, clean and weekly clean. Not using OneDrive? **Choose a folder...** works with Dropbox, Google Drive or a NAS.

## Files
- `~/Library/Application Support/CleanIT/` - `settings.json`, `history.json`, `State/` (startup changes, update counts)
- `~/Library/Logs/CleanIT/` - one log per day
- `~/Library/LaunchAgents/io.github.juicethekidd99.cleanit.weekly.plist` - only when the weekly clean is on

## Not on the Mac (on purpose)
Drivers, the Windows privacy toggles, bloatware removal and restore points have no real Mac equivalent.
No "memory cleaner", no language-file stripping (breaks app signatures), no fake problem counts.
