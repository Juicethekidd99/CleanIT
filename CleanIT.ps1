<#
.SYNOPSIS
    CleanIT - a transparent, no-snake-oil PC cleanup, speed-up and security tool for Windows 10/11.

.DESCRIPTION
    Double-click (or run without switches) to open the CleanIT app: a local web interface in its own
    window, served only to this PC. Almost everything also works from the command line so you can
    script it, schedule it, or push it to several PCs.

      Dashboard  health score, one-click Smart Scan, freed-space history, multi-PC fleet view
      Clean      22 junk categories: Windows, browsers, Discord/Spotify/Teams/Slack/Zoom/VS Code,
                 game launchers, shader caches, dev caches, driver leftovers, WinSxS, Windows.old
      Disk       space analyzer, large-file finder, duplicate finder (SHA-256, hard-link aware)
      Startup    Run keys, Startup folders, logon/boot tasks, auto-start services - all reversible
      Apps       bloatware remover (curated, with blocklist) and uninstaller with leftover finder
      Updates    app updates (winget, with exclude list), Windows updates, driver updates
      Privacy    23 reversible privacy/ads toggles, original values saved
      Security   antivirus, firewall, UAC, SmartScreen, Secure Boot, TPM, BitLocker, HVCI, SMBv1 checks
      Health     SMART/SSD wear, battery wear, crashes & blue screens, GPU driver age, repair & optimize
      Fleet      every PC reports to a shared (OneDrive) folder; "Add a PC" makes a one-click installer
      Settings   restore points, schedule, undo center, install shortcuts

    Deliberately NOT included: registry "cleaning", RAM/game "boosters", event-log wiping, defrag on SSDs.

.EXAMPLE
    .\CleanIT.ps1                                   # open the app
    .\CleanIT.ps1 -Scan                             # show reclaimable space (default categories)
    .\CleanIT.ps1 -Clean                            # clean default categories (restore point first)
    .\CleanIT.ps1 -Clean -Deep -NoRestorePoint
    .\CleanIT.ps1 -Clean -Categories UserTemp,BrowserCache,Discord
    .\CleanIT.ps1 -Updates -WindowsUpdates          # update apps (winget) + install Windows updates
    .\CleanIT.ps1 -Report -Security                 # health + security report
    .\CleanIT.ps1 -Privacy                          # apply recommended privacy settings (reversible)
    .\CleanIT.ps1 -UndoPrivacy -UndoStartup         # put back everything CleanIT changed
    .\CleanIT.ps1 -LargeFiles -Path D:\ -MinSizeMB 1000
    .\CleanIT.ps1 -Duplicates -Path $env:USERPROFILE
    .\CleanIT.ps1 -Optimize -Repair -QuickScan
    .\CleanIT.ps1 -InstallSchedule                  # weekly silent clean (day/time from Settings)
    .\CleanIT.ps1 -Install                          # copy to ProgramData + Start menu/desktop shortcuts
#>
[CmdletBinding()]
param(
    [switch]$Scan,
    [switch]$Clean,
    [switch]$Deep,
    [string[]]$Categories,
    [switch]$NoRestorePoint,
    [switch]$Updates,
    [switch]$WindowsUpdates,
    [switch]$Drivers,
    [switch]$DriverCheck,
    [switch]$Report,
    [switch]$Security,
    [switch]$Optimize,
    [switch]$Repair,
    [switch]$QuickScan,
    [switch]$LargeFiles,
    [switch]$Duplicates,
    [string]$Path = $env:USERPROFILE,
    [int]$MinSizeMB = 0,
    [switch]$Privacy,
    [switch]$UndoPrivacy,
    [switch]$UndoStartup,
    [switch]$ListCategories,
    [switch]$ListBloat,
    [switch]$InstallSchedule,
    [switch]$RemoveSchedule,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Fleet,
    [switch]$Silent,
    [switch]$Scheduled,
    [switch]$Notify,
    [string]$JoinFleet,
    [string]$LogDir,
    [switch]$Relaunched
)

$ErrorActionPreference = 'SilentlyContinue'
$script:SelfPath     = $MyInvocation.MyCommand.Path
$script:AppDir       = Split-Path -Parent $script:SelfPath
$script:IsDotSourced = $MyInvocation.InvocationName -eq '.'
$cliSwitches = @('Scan', 'Clean', 'Updates', 'WindowsUpdates', 'Drivers', 'DriverCheck', 'Report', 'Security', 'Optimize', 'Repair', 'QuickScan',
                 'LargeFiles', 'Duplicates', 'Privacy', 'UndoPrivacy', 'UndoStartup', 'ListCategories', 'ListBloat',
                 'InstallSchedule', 'RemoveSchedule', 'Install', 'Uninstall', 'Fleet')
$script:IsCli = @($cliSwitches | Where-Object { $PSBoundParameters[$_] }).Count -gt 0

# Shown to the signed-in user after the weekly SYSTEM clean (runs without admin rights).
if ($Notify) {
    $script:LogDir = Join-Path $env:TEMP 'CleanIT'
    . (Join-Path $script:AppDir 'CleanIT.Core.ps1')
    $last = @(Get-CleanHistory) | Select-Object -Last 1
    if ($last) { Show-Notification 'CleanIT weekly clean' ('Freed {0}. Open CleanIT for details.' -f (Format-Size $last.Freed)) }
    exit
}

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $script:IsDotSourced -and -not $isAdmin -and -not $env:CLEANIT_NOELEVATE) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
    if (-not $script:IsCli) { $argList += @('-WindowStyle', 'Hidden') }
    $argList += @('-File', "`"$script:SelfPath`"")
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $argList += "-$k" } }
        elseif ($v -is [array]) { $argList += "-$k"; $argList += ($v -join ',') }
        else { $argList += "-$k"; $argList += "`"$v`"" }
    }
    $argList += '-Relaunched'
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit
}

if ($LogDir) { $script:LogDir = $LogDir }
. (Join-Path $script:AppDir 'CleanIT.Core.ps1')
. (Join-Path $script:AppDir 'CleanIT.Server.ps1')
$script:Quiet = [bool]$Silent
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if ($script:IsDotSourced) { return }

if ($JoinFleet) {
    # "Install CleanIT on this PC.bat" from an "Add a PC" setup folder
    try {
        Join-Fleet $JoinFleet $script:AppDir
        Show-Notification 'CleanIT' "$env:COMPUTERNAME joined your CleanIT fleet."
    }
    catch {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'CleanIT - could not join the fleet', 'OK', 'Warning')
        exit
    }
    Start-CleanITApp
    exit
}

if (-not $script:IsCli) {
    Invoke-Migration
    Start-CleanITApp -NoWindow:([bool]$env:CLEANIT_NOWINDOW)
    exit
}

Write-Log "CleanIT $($script:Version) on $env:COMPUTERNAME"
Invoke-Migration
$settings = Get-Settings

if ($ListCategories) {
    $script:CategoryDefs | Select-Object Key, Group, Name, Default, Deep, Description | Format-Table -AutoSize -Wrap | Out-String | Write-Host
}
if ($ListBloat) {
    Get-AppxInventory | Sort-Object @{ e = { -[int]$_.Recommended } }, Label |
        Format-Table Label, Name, Recommended, Installed, @{ n = 'Provisioned'; e = { [bool]$_.Provisioned } } -AutoSize | Out-String | Write-Host
}
if ($Install)         { Install-CleanITApp $script:AppDir }
if ($Uninstall)       { Uninstall-CleanITApp }
if ($InstallSchedule) { Install-Schedule $script:AppDir }
if ($RemoveSchedule)  { Remove-Schedule }
if ($UndoPrivacy)     { Restore-AllPrivacy }
if ($UndoStartup)     { Undo-AllStartupChanges }

$rpWanted = $settings.RestorePoint -and -not $NoRestorePoint
if ($Privacy) {
    if ($rpWanted) { [void](New-CleanITRestorePoint 'Before privacy changes'); $rpWanted = $false }
    Set-RecommendedPrivacy
}

$selected = @(Get-SelectedCategories -Keys $Categories -Deep:$Deep)
if ($Scan) {
    $total = 0
    $rows = foreach ($c in $selected) {
        $s = Get-CategorySize $c
        if ($s -gt 0) { $total += $s }
        [pscustomobject]@{ Key = $c.Key; Category = $c.Name; Size = (Format-Size $s) }
    }
    $table = $rows | Format-Table -AutoSize | Out-String
    Add-Content -Path $script:LogFile -Value $table
    Write-Host $table
    Write-Log "Reclaimable: $(Format-Size $total)" 'OK'
}
if ($Clean) {
    $src = 'Manual (command line)'; if ($Scheduled) { $src = 'Scheduled' }
    [void](Invoke-CleanRun -Keys @($selected | ForEach-Object { $_.Key }) -Source $src -RestorePoint:$rpWanted)
}
if ($Updates)        { Invoke-AllAppUpdates }
if ($WindowsUpdates) { Install-WindowsUpdates -Type Software }
if ($Drivers)        { Install-WindowsUpdates -Type Driver }
if ($Optimize)       { Invoke-DriveOptimize }
if ($Repair)         { Invoke-WindowsRepair }
if ($QuickScan)      { Update-DefenderSignatures; Invoke-DefenderQuickScan }
if ($Report) {
    $r = Get-HealthReport
    Add-Content -Path $script:LogFile -Value $r
    Write-Host $r
}
if ($DriverCheck) {
    $d = Get-DriverReport
    $lines = @('GRAPHICS') + @($d.Gpu | ForEach-Object { "  [$($_.Level)] $($_.Name): $($_.Text)" }) +
              @('', "DEVICES: $(@($d.Problems).Count) with problems") + @($d.Problems | ForEach-Object { "  [$($_.Level)] $($_.Problem)" }) +
              @('', 'BIOS', "  [$($d.Bios.Level)] $($d.Bios.Text)", '', "OLDER DRIVERS WORTH CHECKING: $(@($d.Outdated).Count)") +
              @($d.Outdated | ForEach-Object { "  $($_.Device) ($($_.Provider)) $($_.Date)" }) +
              @('', ("OLD DRIVER PACKAGES: {0} removable ({1})" -f @($d.Packages | Where-Object Removable).Count, (Format-Size (($d.Packages | Where-Object Removable | Measure-Object Size -Sum).Sum))))
    $txt = $lines -join "`r`n"
    Add-Content -Path $script:LogFile -Value $txt
    Write-Host $txt
}
if ($Security) {
    $t = Get-SecurityChecks | Format-Table Level, Name, Detail -AutoSize -Wrap | Out-String
    Add-Content -Path $script:LogFile -Value $t
    Write-Host $t
}
if ($LargeFiles) {
    $min = 500; if ($MinSizeMB -gt 0) { $min = $MinSizeMB }
    $t = Find-LargeFiles -Path $Path -MinSizeMB $min -Max 100 |
        Format-Table @{ n = 'Size'; e = { Format-Size $_.Size } }, @{ n = 'Last used'; e = { $_.LastWrite.ToString('yyyy-MM-dd') } }, Path -AutoSize | Out-String -Width 300
    Write-Host $t
}
if ($Duplicates) {
    $min = 1; if ($MinSizeMB -gt 0) { $min = $MinSizeMB }
    $d = @(Find-DuplicateFiles -Path $Path -MinSizeMB $min)
    $wasted = 0
    foreach ($g in ($d | Group-Object Group)) { $wasted += $g.Group[0].Size * ($g.Count - 1) }
    $d | Format-Table Group, @{ n = 'Size'; e = { Format-Size $_.Size } }, Path -AutoSize | Out-String -Width 300 | Write-Host
    Write-Log "Duplicates: $(@($d | Group-Object Group).Count) set(s), $(Format-Size $wasted) could be freed (nothing was deleted)." 'OK'
}
if ($Clean -or $Fleet) { Write-FleetReport }
if ($Scheduled -and $Clean) { Start-ScheduledTask -TaskName $script:NotifyTaskName -ErrorAction SilentlyContinue }

if ($Relaunched -and -not $Silent) { Read-Host 'Press Enter to close' | Out-Null }
