# CleanIT

A transparent, no-snake-oil replacement for Avast Cleanup Premium / CCleaner for Windows 10/11.
Two PowerShell files, no install required, no ads, no telemetry, everything logged and reversible.

> **Status: beta (v2.7.2).** Scanning, the disk tools and the dashboard are tested. Removal features (bloatware,
> uninstall leftovers, services, privacy changes) and the weekly task are new - leave "create a restore point"
> switched on (default) and review every list before you click. Use at your own risk; see LICENSE.

## Requirements
Windows 10 or 11, Windows PowerShell 5.1 (built in), administrator rights. winget (App Installer) for app updates.

## Quick start
1. Download the repo (Code > Download ZIP) and extract it. Keep all files and the `web` folder together.
2. Double-click `CleanIT.vbs` (or `Run-CleanIT.bat`) and approve the UAC prompt.
3. CleanIT opens in its own app window. On the **Dashboard** click **Smart Scan**, then **Clean ...**.
4. Optional: **Settings > Install** adds Start menu + desktop shortcuts (copies to `C:\ProgramData\CleanIT`).

## Updates
CleanIT checks this GitHub repository for new releases (at most every 6 hours) and shows an **Update now** banner.
Updates are downloaded over HTTPS from this repo only, checked (all files present, not damaged, version matches) and the
previous version is kept in `Backups\app-<version>`. Optional: **Settings > Updates > Install updates automatically** lets
the weekly clean update every PC in your fleet by itself. Command line: `.\CleanIT.ps1 -Update`.

## How the app works
The interface is a local web app: `CleanIT.ps1` starts a tiny server on `127.0.0.1` (this PC only, random port)
and opens it in an Edge app window - no browser tabs, no address bar, no console window. Closing the window
stops CleanIT (unless a task such as Windows Update is still running). Nothing is sent to the internet.
The server only accepts the window it opened (one-time login token + HttpOnly/SameSite cookie, Host check,
custom header on every change), so other websites or users on the PC can't control it.

## Fleet (all your PCs in one place)
1. **Fleet > Use my OneDrive** - this PC starts reporting to `OneDrive\CleanIT Fleet`.
2. **Fleet > Add a PC > Create setup** - puts an "Add a PC - CleanIT setup" folder in that OneDrive folder.
3. On the other PC (same OneDrive account) open that folder and double-click **Install CleanIT on this PC**.
   It installs CleanIT, turns on the weekly clean and joins the fleet - nothing to type.
No OneDrive? Use "Put setup on my Desktop", copy the folder over (USB), or point every PC at a shared folder.

If Windows blocks the downloaded files: right-click each > Properties > tick **Unblock**, or run
`Get-ChildItem .\* | Unblock-File`.

## Tabs
| Tab | What it does |
|---|---|
| Dashboard | Health score (0-100), Smart Scan (junk + security + updates + startup + privacy), freed-space history, fleet view of all your PCs |
| Clean | 22 junk categories in 3 groups (Windows / Browsers / Apps), size per category, shows which open apps block a full clean |
| Disk | **Free up space** assistant: drive overview, already-unpacked archives and the Recycle Bin (safe wins, pre-ticked), old disk images/setup files and older versions of the same file to review, and step-by-step guides to move Steam games, VirtualBox VMs and Downloads to your emptier drive. Plus space analyzer with drill-down and size bars; large-file finder ("not used in N days"); duplicate finder (SHA-256, hard-link aware). Files only ever go to the Recycle Bin, one tick at a time |
| Startup | Run keys, Startup folders, logon/boot scheduled tasks, auto-start services. Publisher + signature check (unsigned = orange). Undo all |
| Apps | Bloatware remover (curated recommended list, hard blocklist for system parts, optional de-provisioning, reinstall via Store link). Uninstaller that finds leftover folders/registry keys afterwards |
| Drivers | A plain-English **What to do** checklist (most important first, with Done buttons), a step-by-step BIOS guide for your board, GPU driver vs. the latest official NVIDIA driver (straight from NVIDIA), broken devices explained, BIOS age, older third-party drivers with official links, and removal of old unused driver packages. Never a third-party driver database |
| Updates | Every update labelled Important / Recommended / Optional / Automatic with a one-line reason; only the ones worth installing are pre-ticked. App updates via winget (with "never update" list), Windows updates and official driver updates via the Windows Update API |
| Privacy | 23 toggles (ads, tips, telemetry, Bing in Start, Recall, Copilot...). Original values saved; "Restore everything" button |
| Security | Antivirus, Defender signatures/scan age/tamper protection, threats, firewall, UAC, SmartScreen, Secure Boot, TPM, HVCI, BitLocker, SMBv1, Guest, RDP, Windows support status, outdated apps |
| Protect | Built on Microsoft Defender (no extra antivirus engine): quick / full / Downloads / folder / offline scans, one-click extra protection (block unwanted apps, block scam and malware sites, ransomware folder protection, stronger cloud blocking - each reversible), threat history in plain English with quarantine restore, scheduled scans, Windows Sandbox to test downloads safely, home network check (Wi-Fi security, open ports, connected devices) |
| Health | Unexpected shutdowns explained (power cut vs. crash vs. hardware errors, with "Got it" to clear old ones), SMART health + SSD wear/temperature, battery wear, blue screens / unexpected shutdowns / app crashes (30 days), GPU driver age, Optimize drives, Repair Windows (DISM + SFC), battery report, DNS flush |
| Fleet | Health cards for every PC (score, free space, updates, problems), one-click OneDrive setup, "Add a PC" installer |
| Settings | Theme (Match Windows / Light / Dark), restore points, weekly schedule (day/time, optional app updates), Undo center, install shortcuts |

## Where CleanIT beats the paid cleaners
- **Honest**: no registry cleaner, no RAM/game "booster", no fake "problems found" - every item is real and explained.
- **Reversible**: restore point before changes; privacy/startup/services changes recorded in `State\*.json`; registry
  keys backed up to `.reg` before removal; files go to the Recycle Bin.
- **Safe deletes**: never follows junctions/symlinks/OneDrive placeholders; temp files younger than 24h are left alone;
  locked files are skipped, not forced.
- **Extras** most cleaners don't have: duplicate finder that ignores hard links, crash/blue-screen history, SSD wear,
  Windows end-of-support warning, Windows/driver updates without third-party driver databases, multi-PC fleet reports.

## Cleanup categories
| Key | Default | Notes |
|---|---|---|
| UserTemp | on | All user profiles, files older than 24h |
| WindowsTemp | on | C:\Windows\Temp, older than 24h |
| WindowsUpdate | on | SoftwareDistribution\Download (services stopped/restarted) |
| DeliveryOpt | on | Delivery Optimization peer cache |
| CrashDumps | on | Minidumps, MEMORY.DMP, LiveKernelReports, WER reports |
| OldLogs | on | CBS/DISM/WU logs older than 7 days (event logs untouched) |
| Thumbnails | off | Explorer thumbnail/icon cache |
| ShaderCache | off | DirectX/NVIDIA/AMD/Intel + Steam shader caches |
| RecycleBin | off | All drives, all users (warning shown) |
| DriverLeftovers | off | C:\NVIDIA, C:\AMD, NVIDIA downloader cache |
| ComponentStore | off (deep) | DISM WinSxS cleanup, slow |
| WindowsOld | off | Windows.old + upgrade leftovers via cleanmgr - removes rollback (warning shown) |
| BrowserCache | on | Chrome, Edge, Brave, Vivaldi, Chromium, Opera/GX, Firefox, LibreWolf, Waterfox, INetCache |
| Discord / Spotify / Teams / Slack / Zoom / VSCode | on | Caches only - logins, messages, offline songs untouched |
| GameLaunchers | on | Steam web cache/dumps/logs, Epic web cache |
| AdobeCache | off | Premiere/AE media cache |
| DevCaches | off | npm, yarn, pip, NuGet, Gradle, Maven, Go, Cargo |

## Command line
```powershell
.\CleanIT.ps1 -Scan                                  # reclaimable space (default categories)
.\CleanIT.ps1 -Clean                                 # clean defaults (restore point first if enabled)
.\CleanIT.ps1 -Clean -Deep -NoRestorePoint
.\CleanIT.ps1 -Clean -Categories UserTemp,BrowserCache,Discord
.\CleanIT.ps1 -Updates                               # winget app updates (honours the exclude list)
.\CleanIT.ps1 -WindowsUpdates -Drivers               # Windows + driver updates
.\CleanIT.ps1 -Report -Security                      # health + security report
.\CleanIT.ps1 -DriverCheck                           # graphics/BIOS/device/driver report
.\CleanIT.ps1 -Privacy                               # apply recommended privacy settings
.\CleanIT.ps1 -UndoPrivacy -UndoStartup              # put back everything CleanIT changed
.\CleanIT.ps1 -LargeFiles -Path D:\ -MinSizeMB 1000  # list only, never deletes
.\CleanIT.ps1 -Duplicates -Path $env:USERPROFILE     # list only, never deletes
.\CleanIT.ps1 -Optimize -Repair -QuickScan           # TRIM/defrag, DISM+SFC, Defender quick scan
.\CleanIT.ps1 -FullScan                             # Microsoft Defender full scan (updates virus definitions first)
.\CleanIT.ps1 -ListCategories
.\CleanIT.ps1 -ListBloat
.\CleanIT.ps1 -InstallSchedule                       # weekly silent clean as SYSTEM (day/time from Settings)
.\CleanIT.ps1 -RemoveSchedule
.\CleanIT.ps1 -Install / -Uninstall                  # shortcuts + ProgramData copy
.\CleanIT.ps1 -Fleet                                 # write this PC's report to the fleet folder now
```

## Files
- `C:\ProgramData\CleanIT\Logs` - one log per run
- `C:\ProgramData\CleanIT\settings.json`, `history.json`
- `C:\ProgramData\CleanIT\State\` - original values for privacy/startup/services, removed apps, last update check
- `C:\ProgramData\CleanIT\Backups\` - `.reg` backups of removed registry keys
- The folder is locked down to Administrators/SYSTEM (read-only for users), because the weekly task runs scripts from it as SYSTEM.

## Upgrading from PC Cleanup v1
Run CleanIT once - it removes the old `PCCleanup Weekly` task and recreates the schedule as `CleanIT Weekly`.
The old `C:\ProgramData\PCCleanup` folder (v1 logs and script copy) can be deleted by hand.
