# CleanIT roadmap

Goal: match or beat Avast Cleanup Premium / CCleaner / BleachBit on the features that actually help,
and skip the snake oil.

## Done in v2.0.0 (roadmap phases 1-3)
- [x] Restore point before Clean / bloatware / privacy / services / uninstall (once per session, 24h throttle handled,
      offers to turn System Protection on); `-NoRestorePoint`
- [x] App caches: Discord, Spotify, Teams (classic + new), Slack, Zoom, VS Code, Steam/Epic, Adobe, dev caches,
      driver installer leftovers, Windows.old/upgrade leftovers (clearly labelled "removes rollback")
- [x] Disk tab: space analyzer (native C# walker, drill-down, bars, cancel), large files, duplicates (SHA-256, hard-link aware)
- [x] Startup: logon/boot scheduled tasks, auto-start services (-> Manual, original remembered), publisher + signature, undo all
- [x] Apps: bloatware remover with curated list + blocklist + de-provision + reinstall links; uninstaller + strict leftover finder
- [x] Updates: Windows Update + drivers via WUA COM API; winget exclude list
- [x] Privacy tab: 23 reversible toggles, originals in `State\privacy.json`
- [x] Drive optimize (Optimize-Volume - TRIM for SSD, defrag for HDD)
- [x] Dashboard: health score, Smart Scan, freed history, last scheduled clean, toast after weekly clean
- [x] Multi-PC fleet reports + fleet view
- [x] Extras: Security tab, crash/BSOD/unexpected shutdown history, SSD wear/temperature, battery wear, GPU driver age,
      Windows end-of-support warning, DISM+SFC repair, DNS flush, renamed to CleanIT

## Done in v2.1.0 / v2.2.0
- [x] Local web-app UI in its own window (replaces WinForms), no console window, secure localhost server
- [x] Fleet page: one-click OneDrive fleet, "Add a PC" self-installing setup, PC cards, remove PC
- [x] Timeouts around every system query that can hang
- [x] Drivers page: official NVIDIA latest-driver check, problem devices, BIOS age, older drivers, old driver package cleanup
- [x] App window has CleanIT's own taskbar identity/icon
- [x] v2.3.0: built-in updater from GitHub releases (+ optional auto-update in the weekly clean); fixed install-folder permissions
- [x] v2.5.0: Free up space assistant (safe wins, review list, move-to-other-drive guides)
- [x] v2.4.0: plain-English guidance - Drivers to-do list, BIOS guide, Recommended/Optional/Not needed, update importance labels

## Phase 4 - Packaging (next)
- Compile to `CleanIT.exe` with PS2EXE (custom icon, requireAdmin manifest) - note: the core is dot-sourced, so either
  bundle it or inline it at build time
- Simple installer (the in-app "Install" button already makes shortcuts + the ProgramData copy)
- Code-sign the scripts so they run under AllSigned

## Ideas for later
- Browser extension audit (list Chrome/Edge/Firefox extensions with permissions; flag removed-from-store ones)
- Scheduled "Smart Scan" report email/toast with the health score trend
- Per-category history chart on the Dashboard
- Pester tests for the pure functions (Get-NameKey, ConvertFrom-WingetTable, Get-ExePath, Split-CommandLine)
- Split CleanIT.Core.ps1 into a module if it keeps growing
- Modern UI (WPF/XAML) once features settle

## Explicitly out of scope
Registry cleaner, RAM/game boosters, third-party driver databases, event-log wiping, HDD-style defrag on SSDs,
"fake problems found" scare counts.
