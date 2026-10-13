<#
.SYNOPSIS
    CleanIT - a transparent, no-snake-oil PC cleanup, speed-up and security tool for Windows 10/11.

.DESCRIPTION
    Opens a GUI by default. Almost everything also works from the command line so you can
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
      Settings   restore points, schedule, fleet folder, undo center, install shortcuts

    Deliberately NOT included: registry "cleaning", RAM/game "boosters", event-log wiping, defrag on SSDs.

.EXAMPLE
    .\CleanIT.ps1                                   # GUI
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
    [string]$LogDir,
    [switch]$Relaunched
)

$ErrorActionPreference = 'SilentlyContinue'
$script:SelfPath     = $MyInvocation.MyCommand.Path
$script:AppDir       = Split-Path -Parent $script:SelfPath
$script:IsDotSourced = $MyInvocation.InvocationName -eq '.'
$cliSwitches = @('Scan', 'Clean', 'Updates', 'WindowsUpdates', 'Drivers', 'Report', 'Security', 'Optimize', 'Repair', 'QuickScan',
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
if (-not $script:IsDotSourced -and -not $isAdmin) {
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
$script:Quiet = [bool]$Silent
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# ---------------------------------------------------------------------------
# GUI building blocks
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$script:Accent  = [System.Drawing.Color]::FromArgb(13, 148, 136)
$script:Dark    = [System.Drawing.Color]::FromArgb(15, 23, 42)
$script:Muted   = [System.Drawing.Color]::FromArgb(100, 116, 139)
$script:LevelColors = @{
    BAD  = [System.Drawing.Color]::FromArgb(185, 28, 28)
    WARN = [System.Drawing.Color]::FromArgb(180, 83, 9)
    OK   = [System.Drawing.Color]::FromArgb(21, 128, 61)
    INFO = [System.Drawing.Color]::FromArgb(71, 85, 105)
}

function New-Button {
    param([string]$Text, [int]$Width = 130, [switch]$Primary)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Width = $Width; $b.Height = 32
    $b.Margin = New-Object System.Windows.Forms.Padding(4, 6, 4, 4)
    $b.FlatStyle = 'Flat'; $b.UseMnemonic = $false
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
    if ($Primary) {
        $b.AccessibleDescription = 'primary'
        $b.FlatAppearance.BorderSize = 0
        $b.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
    }
    Set-ButtonLook $b
    $b.Add_EnabledChanged({ Set-ButtonLook $this })
    $b
}

# Flat buttons don't grey out on their own - make disabled ones look disabled.
function Set-ButtonLook {
    param($b)
    if (-not $b.Enabled) {
        $b.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240); $b.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
    }
    elseif ($b.AccessibleDescription -eq 'primary') {
        $b.BackColor = $script:Accent; $b.ForeColor = [System.Drawing.Color]::White
    }
    else {
        $b.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249); $b.ForeColor = $script:Dark
    }
}

function New-Bar {
    param([string]$Dock = 'Bottom')
    $p = New-Object System.Windows.Forms.FlowLayoutPanel
    $p.Dock = $Dock; $p.AutoSize = $true; $p.AutoSizeMode = 'GrowAndShrink'; $p.WrapContents = $true
    $p.Padding = New-Object System.Windows.Forms.Padding(4, 2, 4, 4)
    $p
}

function New-Label {
    param([string]$Text, [switch]$Muted, [int]$Top = 13)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.AutoSize = $true; $l.UseMnemonic = $false
    $l.Margin = New-Object System.Windows.Forms.Padding(8, $Top, 4, 0)
    if ($Muted) { $l.ForeColor = $script:Muted }
    $l
}

function New-CheckBox {
    param([string]$Text, [bool]$Checked)
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $Text; $c.Checked = $Checked; $c.AutoSize = $true; $c.UseMnemonic = $false
    $c.Margin = New-Object System.Windows.Forms.Padding(8, 12, 4, 0)
    $c
}

function New-Num {
    param([int]$Value, [int]$Min = 0, [int]$Max = 100000, [int]$Width = 80)
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Minimum = $Min; $n.Maximum = $Max; $n.Value = $Value; $n.Width = $Width
    $n.Margin = New-Object System.Windows.Forms.Padding(4, 10, 4, 0)
    $n
}

function New-ListView {
    param([object[]]$Columns, [switch]$CheckBoxes, [switch]$NoSort)
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.Dock = 'Fill'; $lv.HideSelection = $false
    $lv.CheckBoxes = [bool]$CheckBoxes; $lv.BorderStyle = 'None'
    foreach ($c in $Columns) { [void]$lv.Columns.Add([string]$c[0], [int]$c[1]) }
    if (-not $NoSort) { [CleanIT.LvSorter]::Attach($lv) }
    $lv
}

# Cells: plain values, or @{ T = 'display text'; K = sort key (double/datetime) }
function Add-LvRow {
    param($Lv, [object[]]$Cells, $Tag, [bool]$Checked = $false, $Group, $Color)
    $first = $Cells[0]
    if ($first -is [hashtable]) { $it = New-Object System.Windows.Forms.ListViewItem([string]$first.T); $it.SubItems[0].Tag = $first.K }
    else { $it = New-Object System.Windows.Forms.ListViewItem([string]$first) }
    for ($i = 1; $i -lt $Cells.Count; $i++) {
        $c = $Cells[$i]
        if ($c -is [hashtable]) { $si = $it.SubItems.Add([string]$c.T); $si.Tag = $c.K }
        else { [void]$it.SubItems.Add([string]$c) }
    }
    $it.Tag = $Tag
    $it.Checked = $Checked
    if ($Group) { $it.Group = $Group }
    if ($Color) { $it.ForeColor = $Color }
    [void]$Lv.Items.Add($it)
    $it
}

function Reset-ListView { param($Lv) $Lv.ListViewItemSorter = $null; $Lv.Items.Clear() }

function Show-Info { param([string]$Text, [string]$Icon = 'Information') [void][System.Windows.Forms.MessageBox]::Show($Text, 'CleanIT', 'OK', $Icon) }

function Confirm-Yes {
    param([string]$Text, [string]$Icon = 'Question')
    ([System.Windows.Forms.MessageBox]::Show($Text, 'CleanIT', 'YesNo', $Icon)) -eq 'Yes'
}

function Open-InExplorer {
    param([string]$Target)
    if (-not $Target) { return }
    if (Test-Path -LiteralPath $Target -PathType Leaf) { Start-Process explorer.exe "/select,`"$Target`"" }
    elseif (Test-Path -LiteralPath $Target) { Start-Process explorer.exe "`"$Target`"" }
}

function Get-ScoreColor {
    param([int]$Score)
    if ($Score -ge 85) { return $script:LevelColors.OK }
    if ($Score -ge 65) { return $script:LevelColors.WARN }
    $script:LevelColors.BAD
}

function New-PathCombo {
    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.Width = 260; $cb.DropDownStyle = 'DropDown'
    $cb.Margin = New-Object System.Windows.Forms.Padding(4, 10, 4, 0)
    foreach ($d in Get-FixedDrives) { [void]$cb.Items.Add("$($d.DeviceID)\") }
    foreach ($p in @($env:USERPROFILE, (Join-Path $env:USERPROFILE 'Downloads'))) { if (Test-Path -LiteralPath $p) { [void]$cb.Items.Add($p) } }
    $cb
}

function Select-Folder {
    param([string]$Start)
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($Start -and (Test-Path -LiteralPath $Start)) { $fb.SelectedPath = $Start }
    if ($fb.ShowDialog() -eq 'OK') { return $fb.SelectedPath }
    $null
}

# Returns $true = create a restore point, $false = skip, $null = user cancelled the whole action
function Get-RestorePointChoice {
    if (-not $script:Settings.RestorePoint -or $script:RestorePointMade) { return $false }
    if ((Test-SystemProtection) -eq $false) {
        $a = [System.Windows.Forms.MessageBox]::Show(
            "System Protection (restore points) is OFF for $env:SystemDrive.`n`nTurn it on so CleanIT can make a restore point before changing things?`n`nYes = turn on and create one`nNo = continue without a restore point`nCancel = stop",
            'CleanIT', 'YesNoCancel', 'Warning')
        if ($a -eq 'Cancel') { return $null }
        if ($a -eq 'No') { return $false }
        try { Enable-SystemProtection } catch { Show-Info "Could not turn on System Protection: $($_.Exception.Message)" 'Warning'; return $false }
    }
    $true
}

# ---------------------------------------------------------------------------
# Background jobs (runspaces) - keep the window responsive during long work
# ---------------------------------------------------------------------------
function Start-BgJob {
    param([string]$Name, [scriptblock]$Work, [object[]]$ArgumentList = @(), [scriptblock]$OnDone, [scriptblock]$OnTick, $Data, $ScanState)
    $sync = [hashtable]::Synchronized(@{
        Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'; Cancel = $false; Progress = -1; Status = $Name
    })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('CleanITBg', $sync)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $boot = 'param($Core, $LogFile, $LogDir, $WorkText, $WorkArgs)
$ErrorActionPreference = ''SilentlyContinue''
$script:LogDir = $LogDir; $script:LogFile = $LogFile
. $Core
& ([scriptblock]::Create($WorkText)) @WorkArgs'
    [void]$ps.AddScript($boot).AddArgument($script:CorePath).AddArgument($script:LogFile).AddArgument($script:LogDir).AddArgument($Work.ToString()).AddArgument($ArgumentList)
    $job = [pscustomobject]@{
        Name = $Name; PS = $ps; RS = $rs; Handle = $null; Sync = $sync; OnDone = $OnDone; OnTick = $OnTick
        Data = $Data; ScanState = $ScanState; Started = Get-Date
    }
    $job.Handle = $ps.BeginInvoke()
    [void]$script:BgJobs.Add($job)
    $job
}

function Stop-AllBgJobs {
    foreach ($j in @($script:BgJobs)) {
        $j.Sync.Cancel = $true
        if ($j.ScanState) { $j.ScanState.Cancel = $true }
    }
}

function Receive-BgLog {
    param($Job)
    $line = $null
    while ($Job.Sync.Log.TryDequeue([ref]$line)) {
        $p = $line.IndexOf('|')
        Write-LogLine $line.Substring($p + 1) $line.Substring(0, $p)
    }
}

# ---------------------------------------------------------------------------
# Tabs (each Add-*Tab is dot-sourced into Show-Gui so event handlers see the shared controls)
# ---------------------------------------------------------------------------
function Add-DashboardTab {
    $tpDash = New-Object System.Windows.Forms.TabPage 'Dashboard'
    $tpDash.BackColor = [System.Drawing.Color]::White

    $dashTop = New-Object System.Windows.Forms.Panel
    $dashTop.Dock = 'Top'; $dashTop.Height = 190

    $scoreBox = New-Object System.Windows.Forms.Panel
    $scoreBox.Dock = 'Left'; $scoreBox.Width = 196; $scoreBox.Padding = New-Object System.Windows.Forms.Padding(12)
    $scoreBox.Add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
        $g.TranslateTransform(12, 12)
        $rect = New-Object System.Drawing.Rectangle(14, 14, 142, 142)
        $bgPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(226, 232, 240), [single]14)
        $g.DrawArc($bgPen, $rect, 135, 270)
        $txt = '--'
        if ($S.Score -ge 0) {
            $pen = New-Object System.Drawing.Pen((Get-ScoreColor $S.Score), [single]14)
            $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
            $g.DrawArc($pen, $rect, 135, [single](270 * [math]::Max(1, $S.Score) / 100))
            $txt = [string]$S.Score
        }
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
        $g.DrawString($txt, $scoreFont, (New-Object System.Drawing.SolidBrush($script:Dark)), (New-Object System.Drawing.RectangleF(0, 0, 170, 160)), $sf)
        $g.DrawString('health score', $uiFont, (New-Object System.Drawing.SolidBrush($script:Muted)), (New-Object System.Drawing.RectangleF(0, 112, 170, 30)), $sf)
    })

    $cards = New-Object System.Windows.Forms.FlowLayoutPanel
    $cards.Dock = 'Fill'; $cards.Padding = New-Object System.Windows.Forms.Padding(0, 14, 0, 0)
    $newCard = {
        param([string]$Title)
        $p = New-Object System.Windows.Forms.Panel
        $p.Size = New-Object System.Drawing.Size(210, 76); $p.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 10)
        $p.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
        $t = New-Object System.Windows.Forms.Label; $t.Text = $Title; $t.AutoSize = $true; $t.ForeColor = $script:Muted
        $t.Location = New-Object System.Drawing.Point(10, 6)
        $v = New-Object System.Windows.Forms.Label; $v.Text = '-'; $v.AutoSize = $true; $v.Font = $cardFont; $v.ForeColor = $script:Dark
        $v.Location = New-Object System.Drawing.Point(8, 24)
        $s = New-Object System.Windows.Forms.Label; $s.Text = ''; $s.AutoSize = $true; $s.ForeColor = $script:Muted
        $s.Location = New-Object System.Drawing.Point(10, 54)
        $p.Controls.AddRange(@($t, $v, $s))
        [void]$cards.Controls.Add($p)
        [pscustomobject]@{ Value = $v; Sub = $s }
    }
    $cJunk    = & $newCard 'Junk found'
    $cFreed   = & $newCard 'Freed by CleanIT'
    $cDisk    = & $newCard "Free on $env:SystemDrive"
    $cStartup = & $newCard 'Startup apps'
    $cUpd     = & $newCard 'Updates waiting'
    $cLast    = & $newCard 'Last clean'
    $dashTop.Controls.AddRange(@($cards, $scoreBox))

    $lblVerdict = New-Object System.Windows.Forms.Label
    $lblVerdict.Dock = 'Top'; $lblVerdict.Height = 30; $lblVerdict.Font = $boldFont
    $lblVerdict.Padding = New-Object System.Windows.Forms.Padding(14, 6, 0, 0)
    $lblVerdict.Text = 'Checking this PC...'

    $lvIssues = New-ListView @(@('Level', 80), @('What CleanIT found', 720), @('Fix it on tab', 130))
    $barDash = New-Bar
    $btnSmart    = New-Button 'Smart Scan' 150 -Primary
    $btnFixJunk  = New-Button 'Clean junk' 170 -Primary
    $btnFixJunk.Enabled = $false
    $btnDashRef  = New-Button 'Refresh' 100
    $btnFleet    = New-Button 'Fleet view (all PCs)' 170
    $barDash.Controls.AddRange(@($btnSmart, $btnFixJunk, $btnDashRef, $btnFleet,
        (New-Label 'Double-click an item to jump to the tab that fixes it.' -Muted)))
    $tpDash.Controls.Add($lvIssues); $tpDash.Controls.Add($lblVerdict); $tpDash.Controls.Add($dashTop); $tpDash.Controls.Add($barDash)
    $lvIssues.BringToFront()

    $fillDashboard = {
        param($d)
        if (-not $d) { return }
        $S.Score = [int]$d.Score
        $scoreBox.Invalidate()
        $cFreed.Value.Text = Format-Size $d.FreedTotal
        $cFreed.Sub.Text = 'all time on this PC'
        $cDisk.Value.Text = Format-Size $d.FreeBytes
        $cDisk.Sub.Text = ('{0:N0}% of {1}' -f $d.FreePct, (Format-Size $d.SizeBytes))
        $cDisk.Value.ForeColor = $script:Dark
        if ($d.FreePct -lt 10) { $cDisk.Value.ForeColor = $script:LevelColors.BAD } elseif ($d.FreePct -lt 20) { $cDisk.Value.ForeColor = $script:LevelColors.WARN }
        $cStartup.Value.Text = [string]$d.StartupCount
        $cStartup.Sub.Text = 'launch when you sign in'
        $u = @(); if ($d.AppUpdates -ge 0) { $u += "$($d.AppUpdates) apps" }; if ($d.WinUpdates -ge 0) { $u += "$($d.WinUpdates) Windows" }
        if ($u.Count) { $cUpd.Value.Text = [string]([math]::Max(0, $d.AppUpdates) + [math]::Max(0, $d.WinUpdates)); $cUpd.Sub.Text = $u -join ', ' }
        else { $cUpd.Value.Text = '?'; $cUpd.Sub.Text = 'not checked yet' }
        if ($d.LastClean) { $cLast.Value.Text = Format-Ago $d.LastClean; $cLast.Sub.Text = ('freed {0}' -f (Format-Size $d.LastFreed)) }
        else { $cLast.Value.Text = 'never'; $cLast.Sub.Text = '' }
        if ($d.LastScheduled) { $cLast.Sub.Text += (' | weekly: {0}' -f (Format-Ago $d.LastScheduled)) }

        Reset-ListView $lvIssues
        $order = @{ BAD = 0; WARN = 1; INFO = 2 }
        foreach ($i in @($d.Issues | Sort-Object { $order[$_.Level] }, { - $_.Penalty })) {
            [void](Add-LvRow $lvIssues @($i.Level, $i.Text, $i.Tab) $i -Color $script:LevelColors[$i.Level])
        }
        $bad = @($d.Issues | Where-Object { $_.Level -eq 'BAD' }).Count
        if ($d.Score -ge 85 -and -not $bad) { $lblVerdict.Text = 'This PC is in good shape.'; $lblVerdict.ForeColor = $script:LevelColors.OK }
        elseif ($bad) { $lblVerdict.Text = "$bad important problem(s) need attention."; $lblVerdict.ForeColor = $script:LevelColors.BAD }
        else { $lblVerdict.Text = 'A few things could be better.'; $lblVerdict.ForeColor = $script:LevelColors.WARN }
        if (-not @($d.Issues).Count) { [void](Add-LvRow $lvIssues @('OK', 'Nothing to fix right now.', '') $null -Color $script:LevelColors.OK) }
    }

    $refreshDashboard = {
        $btnDashRef.Enabled = $false
        [void](Start-BgJob 'Checking PC health' { Get-DashboardData } -OnDone {
            param($out)
            & $fillDashboard ($out | Select-Object -Last 1)
            $btnDashRef.Enabled = $true
        })
    }

    $btnSmart.Add_Click({
        $btnSmart.Enabled = $false; $btnFixJunk.Enabled = $false
        $lblVerdict.Text = 'Smart Scan: junk, security, updates, startup and privacy...'; $lblVerdict.ForeColor = $script:Dark
        $cJunk.Value.Text = '...'
        $keys = @($script:CategoryDefs | Where-Object { $_.Default } | ForEach-Object { $_.Key })
        [void](Start-BgJob 'Smart Scan' {
            param($Keys)
            Write-Log 'Smart Scan started.'
            $scan = @(Invoke-JunkScan $Keys)
            Set-BgProgress 75 'Checking health, security and updates'
            if (Test-Winget) { [void]@(Get-WingetUpgrades) }
            Set-BgProgress 90 'Scoring'
            $dash = Get-DashboardData
            $junk = 0; foreach ($x in $scan) { if ($x.Size -gt 0) { $junk += $x.Size } }
            Write-Log ("Smart Scan done: {0} of junk, score {1}/100, {2} item(s) to look at." -f (Format-Size $junk), $dash.Score, @($dash.Issues).Count) 'OK'
            [pscustomobject]@{ Scan = $scan; Dash = $dash; Junk = $junk }
        } @(, $keys) -OnDone {
            param($out)
            $r = $out | Select-Object -Last 1
            $btnSmart.Enabled = $true
            if (-not $r) { return }
            foreach ($x in $r.Scan) { $S.Sizes[$x.Key] = [double]$x.Size; $S.Running[$x.Key] = $x.Running }
            & $refreshCleanSizes
            $cJunk.Value.Text = Format-Size $r.Junk
            $cJunk.Sub.Text = 'safe to remove (default items)'
            & $fillDashboard $r.Dash
            if ($r.Junk -gt 1MB) { $btnFixJunk.Text = "Clean $(Format-Size $r.Junk)"; $btnFixJunk.Enabled = $true }
        })
    })

    $btnFixJunk.Add_Click({
        $keys = @($script:CategoryDefs | Where-Object { $_.Default } | ForEach-Object { $_.Key })
        & $runClean $keys
    })
    $btnDashRef.Add_Click({ & $refreshDashboard })
    $btnFleet.Add_Click({ Show-FleetDialog })
    $lvIssues.Add_DoubleClick({
        $it = $lvIssues.SelectedItems | Select-Object -First 1
        if ($it -and $it.Tag -and $pages.ContainsKey($it.Tag.Tab)) { $tabs.SelectedTab = $pages[$it.Tag.Tab] }
    })
    $pages['Dashboard'] = $tpDash
}

function Add-CleanTab {
    $tpClean = New-Object System.Windows.Forms.TabPage 'Clean'
    $lvClean = New-ListView @(@('Category', 290), @('Size', 95), @('Note', 190), @('What it removes', 620)) -CheckBoxes
    $groups = @{}
    foreach ($gName in @('Windows', 'Browsers', 'Apps')) {
        $g = New-Object System.Windows.Forms.ListViewGroup($gName, $gName)
        [void]$lvClean.Groups.Add($g); $groups[$gName] = $g
    }
    foreach ($c in $script:CategoryDefs) {
        $label = $c.Name; if ($c.Deep) { $label += '  (deep)' }
        $note = ''; if ($c.Warning) { $note = 'read warning' }
        $row = Add-LvRow $lvClean @($label, @{ T = '-'; K = [double]-1 }, $note, $c.Description) $c $c.Default $groups[$c.Group]
        if ($c.Warning) { $row.ForeColor = $script:LevelColors.WARN }
    }

    $barClean = New-Bar
    $btnScan  = New-Button 'Scan' 100 -Primary
    $btnClean = New-Button 'Clean selected' 140 -Primary
    $btnRec   = New-Button 'Recommended' 115
    $btnAll   = New-Button 'All' 60
    $btnNone  = New-Button 'None' 60
    $lblCleanTotal = New-Label 'Click Scan to see how much space you can free.'
    $barClean.Controls.AddRange(@($btnScan, $btnClean, $btnRec, $btnAll, $btnNone, $lblCleanTotal))
    $tpClean.Controls.Add($lvClean); $tpClean.Controls.Add($barClean); $lvClean.BringToFront()

    $updateCleanTotal = {
        $t = 0; $known = $false
        foreach ($it in $lvClean.CheckedItems) {
            if ($S.Sizes.ContainsKey($it.Tag.Key)) { $known = $true; $v = $S.Sizes[$it.Tag.Key]; if ($v -gt 0) { $t += $v } }
        }
        if ($known) { $lblCleanTotal.Text = "Selected: $(Format-Size $t) can be freed" }
    }
    $refreshCleanSizes = {
        foreach ($it in $lvClean.Items) {
            $k = $it.Tag.Key
            if ($S.Sizes.ContainsKey($k)) {
                $v = [double]$S.Sizes[$k]
                $it.SubItems[1].Text = Format-Size $v
                $it.SubItems[1].Tag = $v
                if ($v -lt 0) { $it.SubItems[1].Text = 'n/a'; $it.SubItems[1].Tag = [double]-1 }
            }
            $note = ''
            if ($it.Tag.Warning) { $note = 'read warning' }
            if ($S.Running[$k]) { $note = 'close: ' + $S.Running[$k] }
            $it.SubItems[2].Text = $note
        }
        & $updateCleanTotal
    }
    $lvClean.Add_ItemChecked({ & $updateCleanTotal })
    $btnRec.Add_Click({ foreach ($it in $lvClean.Items) { $it.Checked = $it.Tag.Default } })
    $btnAll.Add_Click({ foreach ($it in $lvClean.Items) { $it.Checked = -not $it.Tag.Warning -and -not $it.Tag.Deep } })
    $btnNone.Add_Click({ foreach ($it in $lvClean.Items) { $it.Checked = $false } })

    $btnScan.Add_Click({
        $btnScan.Enabled = $false; $btnClean.Enabled = $false
        foreach ($it in $lvClean.Items) { $it.SubItems[1].Text = '...' }
        $keys = @($lvClean.Items | ForEach-Object { $_.Tag.Key } | Where-Object { $_ -ne 'ComponentStore' })
        [void](Start-BgJob 'Scanning junk' {
            param($Keys)
            Write-Log 'Scanning...'
            $r = @(Invoke-JunkScan $Keys)
            Write-Log 'Scan complete.' 'OK'
            $r
        } @(, $keys) -OnDone {
            param($out)
            foreach ($x in $out) { if ($x.Key) { $S.Sizes[$x.Key] = [double]$x.Size; $S.Running[$x.Key] = $x.Running } }
            $S.Sizes['ComponentStore'] = [double]-1
            & $refreshCleanSizes
            $btnScan.Enabled = $true; $btnClean.Enabled = $true
        })
    })

    $runClean = {
        param([string[]]$Keys)
        $cats = @($script:CategoryDefs | Where-Object { $Keys -contains $_.Key })
        if (-not $cats.Count) { Show-Info 'Tick at least one category first.'; return }
        $names = ($cats | ForEach-Object { '  - ' + $_.Name }) -join "`n"
        $warn = ($cats | Where-Object { $_.Warning } | ForEach-Object { "`n! $($_.Name): $($_.Warning)" }) -join ''
        $running = @($cats | ForEach-Object { Get-RunningForCategory $_ } | Sort-Object -Unique)
        $runTxt = ''; if ($running.Count) { $runTxt = "`n`nOpen apps (their caches are partly skipped): " + ($running -join ', ') }
        $icon = 'Question'; if ($warn) { $icon = 'Warning' }
        if (-not (Confirm-Yes "Clean these categories?`n`n$names$warn$runTxt" $icon)) { return }
        $rp = Get-RestorePointChoice
        if ($null -eq $rp) { return }
        if ($rp) { $script:RestorePointMade = $true }
        $btnScan.Enabled = $false; $btnClean.Enabled = $false; $btnFixJunk.Enabled = $false
        [void](Start-BgJob 'Cleaning' {
            param($Keys, $Rp)
            $r = Invoke-CleanRun -Keys $Keys -Source 'Manual' -RestorePoint:$Rp
            Write-FleetReport
            $r
        } @($Keys, [bool]$rp) -OnDone {
            param($out)
            $r = $out | Select-Object -Last 1
            if ($r) {
                foreach ($d in $r.Details) { $S.Sizes[$d.Key] = [double]0 }
                & $refreshCleanSizes
                $lblCleanTotal.Text = "Done - freed $(Format-Size $r.Freed). Scan again to refresh."
                $cJunk.Value.Text = '0 B'; $cJunk.Sub.Text = "just freed $(Format-Size $r.Freed)"
                $btnFixJunk.Text = 'Clean junk'
            }
            $btnScan.Enabled = $true; $btnClean.Enabled = $true
            & $refreshDashboard
        })
    }
    $btnClean.Add_Click({ & $runClean @($lvClean.CheckedItems | ForEach-Object { $_.Tag.Key }) })
    $pages['Clean'] = $tpClean
}

function Add-DiskTab {
    $tpDisk = New-Object System.Windows.Forms.TabPage 'Disk'
    $diskTabs = New-Object System.Windows.Forms.TabControl
    $diskTabs.Dock = 'Fill'
    $tpDisk.Controls.Add($diskTabs)

    # ---------- Space analyzer ----------
    $tpSpace = New-Object System.Windows.Forms.TabPage 'Space analyzer'
    $barSpaceTop = New-Bar 'Top'
    $cbSpace = New-PathCombo
    $cbSpace.Text = "$env:SystemDrive\"
    $btnSpaceBrowse = New-Button 'Browse...' 90
    $btnSpaceGo = New-Button 'Analyze' 100 -Primary
    $btnSpaceUp = New-Button 'Up' 60
    $btnSpaceOpen = New-Button 'Open in Explorer' 140
    $lblSpace = New-Label 'Pick a drive or folder and click Analyze.' -Muted
    $barSpaceTop.Controls.AddRange(@($cbSpace, $btnSpaceBrowse, $btnSpaceGo, $btnSpaceUp, $btnSpaceOpen, $lblSpace))
    $lvSpace = New-ListView @(@('Folder', 360), @('Size', 100), @('Share of parent', 260), @('Files', 90), @('Path', 420))
    [CleanIT.BarList]::Enable($lvSpace, 2, [System.Drawing.Color]::FromArgb(94, 234, 212))
    $tpSpace.Controls.Add($lvSpace); $tpSpace.Controls.Add($barSpaceTop); $lvSpace.BringToFront()

    $showNode = {
        param($Node)
        $S.DiskNode = $Node
        $lvSpace.BeginUpdate()
        Reset-ListView $lvSpace
        $total = [math]::Max([double]1, [double]$Node.Size)
        $rows = @($Node.Children) | Sort-Object Size -Descending
        foreach ($c in $rows) {
            $pct = 100.0 * $c.Size / $total
            $name = $c.Name; if ($c.Denied) { $name += '  (no access)' }
            [void](Add-LvRow $lvSpace @($name, @{ T = (Format-Size $c.Size); K = [double]$c.Size }, @{ T = ('{0:N1}%' -f $pct); K = [double]$pct },
                @{ T = ('{0:N0}' -f $c.Files); K = [double]$c.Files }, $c.FullPath) $c)
        }
        if ($Node.OwnFiles -gt 0) {
            $pct = 100.0 * $Node.OwnBytes / $total
            [void](Add-LvRow $lvSpace @('[files directly in this folder]', @{ T = (Format-Size $Node.OwnBytes); K = [double]$Node.OwnBytes },
                @{ T = ('{0:N1}%' -f $pct); K = [double]$pct }, @{ T = ('{0:N0}' -f $Node.OwnFiles); K = [double]$Node.OwnFiles }, $Node.FullPath) $null -Color $script:Muted)
        }
        $lvSpace.EndUpdate()
        $lblSpace.Text = ('{0}  -  {1} in {2:N0} files' -f $Node.FullPath, (Format-Size $Node.Size), $Node.Files)
        $btnSpaceUp.Enabled = [bool]$Node.Parent
    }

    $btnSpaceBrowse.Add_Click({ $p = Select-Folder $cbSpace.Text; if ($p) { $cbSpace.Text = $p } })
    $btnSpaceGo.Add_Click({
        $root = $cbSpace.Text.Trim()
        if (-not (Test-Path -LiteralPath $root)) { Show-Info "Folder not found: $root" 'Warning'; return }
        $st = New-Object CleanIT.ScanState
        $btnSpaceGo.Enabled = $false
        Reset-ListView $lvSpace
        [void](Start-BgJob "Analyzing $root" {
            param($Root, $St)
            Initialize-Native
            [CleanIT.Disk]::ScanTree($Root, $St)
        } @($root, $st) -ScanState $st -OnTick {
            param($j)
            $s = $j.ScanState
            $lblSpace.Text = ('Scanning... {0:N0} folders, {1} - {2}' -f $s.Dirs, (Format-Size $s.Bytes), $s.Current)
        } -OnDone {
            param($out, $j)
            $btnSpaceGo.Enabled = $true
            $node = $out | Select-Object -Last 1
            if ($node) {
                $S.DiskRoot = $node
                & $showNode $node
                if ($j.ScanState.Cancel) { $lblSpace.Text += '  (cancelled - partial result)' }
                Write-Log ('Analyzed {0}: {1} in {2:N0} files.' -f $node.FullPath, (Format-Size $node.Size), $node.Files) 'OK'
            }
        })
    })
    $lvSpace.Add_DoubleClick({
        $it = $lvSpace.SelectedItems | Select-Object -First 1
        if ($it -and $it.Tag -and @($it.Tag.Children).Count) { & $showNode $it.Tag }
    })
    $btnSpaceUp.Add_Click({ if ($S.DiskNode -and $S.DiskNode.Parent) { & $showNode $S.DiskNode.Parent } })
    $btnSpaceOpen.Add_Click({
        $it = $lvSpace.SelectedItems | Select-Object -First 1
        if ($it) { Open-InExplorer $it.SubItems[4].Text } elseif ($S.DiskNode) { Open-InExplorer $S.DiskNode.FullPath }
    })

    # ---------- Large files ----------
    $tpLarge = New-Object System.Windows.Forms.TabPage 'Large files'
    $barLargeTop = New-Bar 'Top'
    $cbLarge = New-PathCombo; $cbLarge.Text = $env:USERPROFILE
    $btnLargeBrowse = New-Button 'Browse...' 90
    $numLargeMB = New-Num 500 1 1000000
    $numLargeDays = New-Num 0 0 3650 60
    $chkLargeSys = New-CheckBox 'Include Windows, Program Files & AppData' $false
    $btnLargeGo = New-Button 'Find' 80 -Primary
    $barLargeTop.Controls.AddRange(@($cbLarge, $btnLargeBrowse, (New-Label 'Min size (MB):'), $numLargeMB,
        (New-Label 'Not used for (days, 0 = any):'), $numLargeDays, $chkLargeSys, $btnLargeGo))
    $lvLarge = New-ListView @(@('File', 330), @('Size', 100), @('Last used', 110), @('Folder', 600)) -CheckBoxes
    $barLarge = New-Bar
    $btnLargeOpen = New-Button 'Open location' 130
    $btnLargeRecycle = New-Button 'Send checked to Recycle Bin' 220
    $lblLarge = New-Label 'Nothing is ever deleted automatically - tick files yourself.' -Muted
    $barLarge.Controls.AddRange(@($btnLargeOpen, $btnLargeRecycle, $lblLarge))
    $tpLarge.Controls.Add($lvLarge); $tpLarge.Controls.Add($barLargeTop); $tpLarge.Controls.Add($barLarge); $lvLarge.BringToFront()

    $btnLargeBrowse.Add_Click({ $p = Select-Folder $cbLarge.Text; if ($p) { $cbLarge.Text = $p } })
    $btnLargeGo.Add_Click({
        $root = $cbLarge.Text.Trim()
        if (-not (Test-Path -LiteralPath $root)) { Show-Info "Folder not found: $root" 'Warning'; return }
        $st = New-Object CleanIT.ScanState
        $btnLargeGo.Enabled = $false
        Reset-ListView $lvLarge
        [void](Start-BgJob 'Finding large files' {
            param($Root, $Min, $Days, $Sys, $St)
            Find-LargeFiles -Path $Root -MinSizeMB $Min -UnusedDays $Days -IncludeSystem:$Sys -State $St
        } @($root, [int]$numLargeMB.Value, [int]$numLargeDays.Value, $chkLargeSys.Checked, $st) -ScanState $st -OnTick {
            param($j) $lblLarge.Text = ('Searching... {0:N0} folders - {1}' -f $j.ScanState.Dirs, $j.ScanState.Current)
        } -OnDone {
            param($out)
            $btnLargeGo.Enabled = $true
            $lvLarge.BeginUpdate()
            $sum = 0
            foreach ($f in $out) {
                if (-not $f.Path) { continue }
                $last = $f.LastWrite; if ($f.LastAccess -gt $last) { $last = $f.LastAccess }
                [void](Add-LvRow $lvLarge @([IO.Path]::GetFileName($f.Path), @{ T = (Format-Size $f.Size); K = [double]$f.Size },
                    @{ T = $last.ToString('yyyy-MM-dd'); K = $last }, [IO.Path]::GetDirectoryName($f.Path)) $f)
                $sum += $f.Size
            }
            $lvLarge.EndUpdate()
            $lblLarge.Text = ('{0} files, {1} total. Tick the ones you no longer need.' -f $lvLarge.Items.Count, (Format-Size $sum))
        })
    })
    $btnLargeOpen.Add_Click({ $it = $lvLarge.SelectedItems | Select-Object -First 1; if ($it) { Open-InExplorer $it.Tag.Path } })
    $btnLargeRecycle.Add_Click({
        $sel = @($lvLarge.CheckedItems)
        if (-not $sel.Count) { Show-Info 'Tick the files to remove first.'; return }
        $sum = 0; foreach ($i in $sel) { $sum += $i.Tag.Size }
        if (-not (Confirm-Yes ("Send {0} file(s) ({1}) to the Recycle Bin?`n`nYou can restore them from the Recycle Bin." -f $sel.Count, (Format-Size $sum)))) { return }
        foreach ($i in $sel) {
            try { Send-ToRecycleBin $i.Tag.Path; Write-Log "Recycled: $($i.Tag.Path)" 'OK'; $lvLarge.Items.Remove($i) }
            catch { Write-Log "Could not recycle $($i.Tag.Path): $($_.Exception.Message)" 'WARN' }
        }
    })

    # ---------- Duplicates ----------
    $tpDup = New-Object System.Windows.Forms.TabPage 'Duplicate files'
    $barDupTop = New-Bar 'Top'
    $cbDup = New-PathCombo; $cbDup.Text = $env:USERPROFILE
    $btnDupBrowse = New-Button 'Browse...' 90
    $numDupMB = New-Num 1 0 100000
    $chkDupSys = New-CheckBox 'Include Windows, Program Files & AppData' $false
    $btnDupGo = New-Button 'Find duplicates' 140 -Primary
    $barDupTop.Controls.AddRange(@($cbDup, $btnDupBrowse, (New-Label 'Min size (MB):'), $numDupMB, $chkDupSys, $btnDupGo))
    $lvDup = New-ListView @(@('File', 330), @('Size', 100), @('Modified', 110), @('Folder', 600)) -CheckBoxes
    $barDup = New-Bar
    $btnDupKeepOld = New-Button 'Tick all but the oldest' 180
    $btnDupKeepNew = New-Button 'Tick all but the newest' 180
    $btnDupOpen = New-Button 'Open location' 120
    $btnDupRecycle = New-Button 'Send checked to Recycle Bin' 220
    $lblDup = New-Label 'Files are compared by content (SHA-256). Hard links are not counted twice.' -Muted
    $barDup.Controls.AddRange(@($btnDupKeepOld, $btnDupKeepNew, $btnDupOpen, $btnDupRecycle, $lblDup))
    $tpDup.Controls.Add($lvDup); $tpDup.Controls.Add($barDupTop); $tpDup.Controls.Add($barDup); $lvDup.BringToFront()

    $btnDupBrowse.Add_Click({ $p = Select-Folder $cbDup.Text; if ($p) { $cbDup.Text = $p } })
    $btnDupGo.Add_Click({
        $root = $cbDup.Text.Trim()
        if (-not (Test-Path -LiteralPath $root)) { Show-Info "Folder not found: $root" 'Warning'; return }
        $st = New-Object CleanIT.ScanState
        $btnDupGo.Enabled = $false
        Reset-ListView $lvDup; $lvDup.Groups.Clear()
        [void](Start-BgJob 'Finding duplicates' {
            param($Root, $Min, $Sys, $St)
            Find-DuplicateFiles -Path $Root -MinSizeMB $Min -IncludeSystem:$Sys -State $St
        } @($root, [int]$numDupMB.Value, $chkDupSys.Checked, $st) -ScanState $st -OnTick {
            param($j) $lblDup.Text = ('{0}... {1:N0} files, {2} read - {3}' -f $j.ScanState.Phase, $j.ScanState.Files, (Format-Size $j.ScanState.Bytes), $j.ScanState.Current)
        } -OnDone {
            param($out)
            $btnDupGo.Enabled = $true
            $lvDup.BeginUpdate()
            $wasted = 0; $groupsN = 0
            foreach ($grp in @($out | Where-Object { $_.Path } | Group-Object Group)) {
                $files = @($grp.Group)
                $size = $files[0].Size
                $wasted += $size * ($files.Count - 1); $groupsN++
                $g = New-Object System.Windows.Forms.ListViewGroup(('{0} copies of {1} - {2}' -f $files.Count, (Format-Size $size), [IO.Path]::GetFileName($files[0].Path)))
                [void]$lvDup.Groups.Add($g)
                foreach ($f in $files) {
                    [void](Add-LvRow $lvDup @([IO.Path]::GetFileName($f.Path), @{ T = (Format-Size $f.Size); K = [double]$f.Size },
                        @{ T = $f.LastWrite.ToString('yyyy-MM-dd'); K = $f.LastWrite }, [IO.Path]::GetDirectoryName($f.Path)) $f -Group $g)
                }
            }
            $lvDup.EndUpdate()
            $lblDup.Text = ('{0} sets of duplicates - {1} could be freed.' -f $groupsN, (Format-Size $wasted))
        })
    })
    $tickDup = {
        param([bool]$KeepOldest)
        foreach ($g in $lvDup.Groups) {
            $items = @($g.Items) | Sort-Object { $_.Tag.LastWrite }
            if ($items.Count -lt 2) { continue }
            $keep = $items[0]; if (-not $KeepOldest) { $keep = $items[-1] }
            foreach ($i in $items) { $i.Checked = ($i -ne $keep) }
        }
    }
    $btnDupKeepOld.Add_Click({ & $tickDup $true })
    $btnDupKeepNew.Add_Click({ & $tickDup $false })
    $btnDupOpen.Add_Click({ $it = $lvDup.SelectedItems | Select-Object -First 1; if ($it) { Open-InExplorer $it.Tag.Path } })
    $btnDupRecycle.Add_Click({
        $sel = @($lvDup.CheckedItems)
        if (-not $sel.Count) { Show-Info 'Tick the copies to remove first.'; return }
        foreach ($g in $lvDup.Groups) {
            $all = @($g.Items); $chk = @($all | Where-Object { $_.Checked })
            if ($all.Count -and $chk.Count -eq $all.Count) {
                Show-Info "Every copy in '$($g.Header)' is ticked. Leave at least one copy unticked." 'Warning'; return
            }
        }
        $sum = 0; foreach ($i in $sel) { $sum += $i.Tag.Size }
        if (-not (Confirm-Yes ("Send {0} duplicate file(s) ({1}) to the Recycle Bin?" -f $sel.Count, (Format-Size $sum)))) { return }
        foreach ($i in $sel) {
            try { Send-ToRecycleBin $i.Tag.Path; Write-Log "Recycled duplicate: $($i.Tag.Path)" 'OK'; $lvDup.Items.Remove($i) }
            catch { Write-Log "Could not recycle $($i.Tag.Path): $($_.Exception.Message)" 'WARN' }
        }
    })

    $diskTabs.TabPages.AddRange(@($tpSpace, $tpLarge, $tpDup))
    $pages['Disk'] = $tpDisk
}

function Add-StartupTab {
    $tpStart = New-Object System.Windows.Forms.TabPage 'Startup'
    $barStartTop = New-Bar 'Top'
    $chkStartMs = New-CheckBox 'Show Microsoft items' ([bool]$script:Settings.ShowMicrosoft)
    $barStartTop.Controls.AddRange(@($chkStartMs,
        (New-Label 'Ticked = starts automatically. Unticked services switch to Manual (start when needed). Everything can be undone.' -Muted)))
    $lvStart = New-ListView @(@('Name', 230), @('Type', 70), @('Publisher', 210), @('Status', 130), @('Where / command', 620)) -CheckBoxes
    $barStart = New-Bar
    $btnStartRefresh = New-Button 'Refresh' 100
    $btnStartApply   = New-Button 'Apply changes' 140 -Primary
    $btnStartUndo    = New-Button 'Undo all CleanIT changes' 200
    $btnStartOpen    = New-Button 'Open file location' 150
    $lblStart = New-Label '' -Muted
    $barStart.Controls.AddRange(@($btnStartRefresh, $btnStartApply, $btnStartUndo, $btnStartOpen, $lblStart))
    $tpStart.Controls.Add($lvStart); $tpStart.Controls.Add($barStartTop); $tpStart.Controls.Add($barStart); $lvStart.BringToFront()

    $loadStartup = {
        $btnStartRefresh.Enabled = $false; $btnStartApply.Enabled = $false
        Reset-ListView $lvStart
        $lblStart.Text = 'Loading (checking signatures)...'
        [void](Start-BgJob 'Loading startup items' {
            param($Ms)
            @(Get-StartupItems -IncludeMicrosoft:$Ms)
        } @([bool]$chkStartMs.Checked) -OnDone {
            param($out)
            $lvStart.BeginUpdate()
            $kinds = @{ Run = 'Run'; Folder = 'Folder'; Task = 'Task'; Service = 'Service' }
            $on = 0
            foreach ($s in @($out | Where-Object { $_.Kind } | Sort-Object Kind, Name)) {
                $color = $null
                if ($s.Publisher -match 'unsigned|NOT valid') { $color = $script:LevelColors.WARN }
                $status = $s.Status; if (-not $status) { if ($s.Enabled) { $status = 'Enabled' } else { $status = 'Disabled' } }
                [void](Add-LvRow $lvStart @($s.Name, $kinds[$s.Kind], $s.Publisher, $status, ('{0}: {1}' -f $s.Location, $s.Command)) $s $s.Enabled -Color $color)
                if ($s.Enabled) { $on++ }
            }
            $lvStart.EndUpdate()
            $lblStart.Text = "$on of $($lvStart.Items.Count) start automatically. Orange = unsigned/untrusted publisher."
            $btnStartRefresh.Enabled = $true; $btnStartApply.Enabled = $true
        })
    }
    $chkStartMs.Add_CheckedChanged({
        $script:Settings.ShowMicrosoft = $chkStartMs.Checked; Save-Settings $script:Settings
        & $loadStartup
    })
    $btnStartRefresh.Add_Click({ & $loadStartup })
    $btnStartApply.Add_Click({
        $changes = @(foreach ($it in $lvStart.Items) {
            if ($it.Checked -ne $it.Tag.Enabled) { [pscustomobject]@{ Item = $it.Tag; Enable = $it.Checked } }
        })
        if (-not $changes.Count) { Write-Log 'Startup: no changes to apply.'; return }
        $rp = $false
        if (@($changes | Where-Object { $_.Item.Kind -eq 'Service' }).Count) {
            $rp = Get-RestorePointChoice
            if ($null -eq $rp) { return }
            if ($rp) { $script:RestorePointMade = $true }
        }
        $btnStartApply.Enabled = $false
        [void](Start-BgJob 'Applying startup changes' {
            param($Changes, $Rp)
            if ($Rp) { [void](New-CleanITRestorePoint 'Before startup/service changes') }
            foreach ($c in $Changes) {
                $verb = 'disabled'; if ($c.Enable) { $verb = 'enabled' }
                try { Set-StartupItemState $c.Item $c.Enable; Write-Log "Startup: $($c.Item.Name) $verb" 'OK' }
                catch { Write-Log "Startup: $($c.Item.Name) - $($_.Exception.Message)" 'ERROR' }
            }
        } @($changes, [bool]$rp) -OnDone { & $loadStartup })
    })
    $btnStartUndo.Add_Click({
        if (-not (Confirm-Yes 'Re-enable every startup item, task and service that CleanIT turned off?')) { return }
        [void](Start-BgJob 'Undoing startup changes' { Undo-AllStartupChanges } -OnDone { & $loadStartup })
    })
    $btnStartOpen.Add_Click({ $it = $lvStart.SelectedItems | Select-Object -First 1; if ($it) { Open-InExplorer $it.Tag.Exe } })
    $pages['Startup'] = $tpStart
}

function Add-AppsTab {
    $tpApps = New-Object System.Windows.Forms.TabPage 'Apps'
    $appTabs = New-Object System.Windows.Forms.TabControl
    $appTabs.Dock = 'Fill'
    $tpApps.Controls.Add($appTabs)

    # ---------- Bloatware ----------
    $tpBloat = New-Object System.Windows.Forms.TabPage 'Bloatware & Store apps'
    $lvBloat = New-ListView @(@('App', 260), @('Package', 330), @('Publisher', 200), @('Installed', 80), @('Provisioned', 90)) -CheckBoxes
    $gRec = New-Object System.Windows.Forms.ListViewGroup('Recommended to remove (ads, trials, retired apps)')
    $gOpt = New-Object System.Windows.Forms.ListViewGroup('Optional - remove only if you never use it')
    $gOther = New-Object System.Windows.Forms.ListViewGroup('Other removable Store apps')
    [void]$lvBloat.Groups.AddRange(@($gRec, $gOpt, $gOther))
    $barBloat = New-Bar
    $btnBloatLoad = New-Button 'Refresh' 100
    $btnBloatRemove = New-Button 'Remove checked' 140 -Primary
    $chkBloatProv = New-CheckBox "Also stop them coming back for new users" $true
    $btnBloatRe = New-Button 'Reinstall removed...' 160
    $lblBloat = New-Label 'System parts (Store, Defender, winget, shell) are never listed.' -Muted
    $barBloat.Controls.AddRange(@($btnBloatLoad, $btnBloatRemove, $chkBloatProv, $btnBloatRe, $lblBloat))
    $tpBloat.Controls.Add($lvBloat); $tpBloat.Controls.Add($barBloat); $lvBloat.BringToFront()

    $loadBloat = {
        $btnBloatLoad.Enabled = $false; $btnBloatRemove.Enabled = $false
        Reset-ListView $lvBloat
        $lblBloat.Text = 'Loading Store apps...'
        [void](Start-BgJob 'Listing Store apps' { @(Get-AppxInventory) } -OnDone {
            param($out)
            $lvBloat.BeginUpdate()
            foreach ($a in @($out | Where-Object { $_.Name } | Sort-Object Label)) {
                $g = $gOther; if ($a.Known) { if ($a.Recommended) { $g = $gRec } else { $g = $gOpt } }
                $inst = 'no'; if ($a.Installed) { $inst = 'yes' }
                $prov = 'no'; if ($a.Provisioned) { $prov = 'yes' }
                [void](Add-LvRow $lvBloat @($a.Label, $a.Name, $a.Publisher, $inst, $prov) $a ($a.Recommended -and $a.Known) $g)
            }
            $lvBloat.EndUpdate()
            $lblBloat.Text = "$($lvBloat.Items.Count) removable apps. Recommended ones are pre-ticked. System parts are never listed."
            $btnBloatLoad.Enabled = $true; $btnBloatRemove.Enabled = $true
        })
    }
    $btnBloatLoad.Add_Click({ & $loadBloat })
    $btnBloatRemove.Add_Click({
        $sel = @($lvBloat.CheckedItems | ForEach-Object { $_.Tag })
        if (-not $sel.Count) { Show-Info 'Tick the apps to remove first.'; return }
        $names = ($sel | Select-Object -First 25 | ForEach-Object { '  - ' + $_.Label }) -join "`n"
        if ($sel.Count -gt 25) { $names += "`n  ... and $($sel.Count - 25) more" }
        if (-not (Confirm-Yes "Remove these $($sel.Count) app(s) for all users?`n`n$names`n`nThey can be reinstalled from the Microsoft Store (Settings > Reinstall removed apps).")) { return }
        $rp = Get-RestorePointChoice
        if ($null -eq $rp) { return }
        if ($rp) { $script:RestorePointMade = $true }
        $btnBloatRemove.Enabled = $false
        [void](Start-BgJob 'Removing apps' {
            param($Apps, $Deprov, $Rp)
            if ($Rp) { [void](New-CleanITRestorePoint 'Before removing apps') }
            $i = 0
            foreach ($a in $Apps) {
                Set-BgProgress ([int](100 * $i / $Apps.Count)) "Removing $($a.Label)"
                Write-Log "Removing $($a.Label) ($($a.Name))..."
                [void](Remove-BloatApp $a -Deprovision:$Deprov)
                $i++
            }
            Write-Log "App removal finished ($($Apps.Count) app(s))." 'OK'
        } @($sel, $chkBloatProv.Checked, [bool]$rp) -OnDone { & $loadBloat })
    })
    $btnBloatRe.Add_Click({ Show-RemovedAppsDialog })

    # ---------- Programs ----------
    $tpProg = New-Object System.Windows.Forms.TabPage 'Programs (uninstall)'
    $barProgTop = New-Bar 'Top'
    $txtProgFilter = New-Object System.Windows.Forms.TextBox
    $txtProgFilter.Width = 260; $txtProgFilter.Margin = New-Object System.Windows.Forms.Padding(4, 10, 4, 0)
    $barProgTop.Controls.AddRange(@((New-Label 'Search:'), $txtProgFilter))
    $lvProg = New-ListView @(@('Program', 330), @('Publisher', 220), @('Version', 120), @('Size', 90), @('Installed', 95), @('For', 130))
    $lvProg.MultiSelect = $false
    $barProg = New-Bar
    $btnProgRefresh = New-Button 'Refresh' 100
    $btnProgUninst = New-Button 'Uninstall' 110 -Primary
    $btnProgLeft = New-Button 'Find leftovers' 130
    $btnProgOpen = New-Button 'Open install folder' 160
    $lblProg = New-Label 'After an uninstall, CleanIT looks for leftover folders and registry keys.' -Muted
    $barProg.Controls.AddRange(@($btnProgRefresh, $btnProgUninst, $btnProgLeft, $btnProgOpen, $lblProg))
    $tpProg.Controls.Add($lvProg); $tpProg.Controls.Add($barProgTop); $tpProg.Controls.Add($barProg); $lvProg.BringToFront()

    $fillPrograms = {
        $f = $txtProgFilter.Text.Trim()
        $lvProg.BeginUpdate()
        Reset-ListView $lvProg
        foreach ($p in @($S.Programs | Sort-Object Name)) {
            if ($f -and $p.Name -notlike "*$f*" -and $p.Publisher -notlike "*$f*") { continue }
            $date = ''; $dk = [datetime]::MinValue
            if ($p.InstallDate) { $date = $p.InstallDate.ToString('yyyy-MM-dd'); $dk = $p.InstallDate }
            $size = ''; if ($p.SizeBytes -gt 0) { $size = Format-Size $p.SizeBytes }
            [void](Add-LvRow $lvProg @($p.Name, $p.Publisher, $p.Version, @{ T = $size; K = [double]$p.SizeBytes }, @{ T = $date; K = $dk }, $p.Scope) $p)
        }
        $lvProg.EndUpdate()
        $lblProg.Text = "$($lvProg.Items.Count) programs."
    }
    $loadPrograms = { $S.Programs = @(Get-InstalledPrograms); & $fillPrograms }
    $txtProgFilter.Add_TextChanged({ & $fillPrograms })
    $btnProgRefresh.Add_Click({ & $loadPrograms })
    $btnProgOpen.Add_Click({ $it = $lvProg.SelectedItems | Select-Object -First 1; if ($it -and $it.Tag.InstallLocation) { Open-InExplorer $it.Tag.InstallLocation } })

    $findLeftovers = {
        param($Program)
        $btnProgLeft.Enabled = $false
        [void](Start-BgJob "Looking for leftovers of $($Program.Name)" {
            param($Prog, $All)
            Write-Log "Looking for leftovers of $($Prog.Name)..."
            @(Find-ProgramLeftovers $Prog $All)
        } @($Program, @($S.Programs)) -Data $Program -OnDone {
            param($out, $j)
            $btnProgLeft.Enabled = $true
            $hits = @($out | Where-Object { $_.Path })
            if (-not $hits.Count) { Write-Log "No leftovers found for $($j.Data.Name)." 'OK'; Show-Info "No leftovers found for $($j.Data.Name)."; return }
            Show-LeftoversDialog $j.Data $hits
            & $loadPrograms
        })
    }
    $btnProgLeft.Add_Click({ $it = $lvProg.SelectedItems | Select-Object -First 1; if ($it) { & $findLeftovers $it.Tag } else { Show-Info 'Select a program first.' } })

    $unTimer = New-Object System.Windows.Forms.Timer
    $unTimer.Interval = 1000
    $unTimer.Add_Tick({
        $w = $S.Uninstall
        if (-not $w) { $unTimer.Stop(); return }
        if (-not $w.Proc.HasExited) { return }
        if (-not $w.ExitedAt) { $w.ExitedAt = Get-Date }
        $gone = -not (Test-Path -LiteralPath "Registry::$($w.Program.RegKey)")
        if ($gone) {
            $unTimer.Stop(); $S.Uninstall = $null
            Write-Log "$($w.Program.Name) was uninstalled." 'OK'
            & $loadPrograms
            & $findLeftovers $w.Program
        }
        elseif (((Get-Date) - $w.ExitedAt).TotalSeconds -gt 8) {
            $unTimer.Stop(); $S.Uninstall = $null
            Write-Log "If the uninstaller of $($w.Program.Name) is still open, finish it, then click 'Find leftovers'." 'WARN'
            & $loadPrograms
        }
    })
    $startUninstall = {
        param($Program)
        try {
            $proc = Start-ProgramUninstall $Program
            $S.Uninstall = @{ Proc = $proc; Program = $Program; ExitedAt = $null }
            $unTimer.Start()
        }
        catch { Write-Log "Could not start the uninstaller: $($_.Exception.Message)" 'ERROR' }
    }
    $btnProgUninst.Add_Click({
        $it = $lvProg.SelectedItems | Select-Object -First 1
        if (-not $it) { Show-Info 'Select a program first.'; return }
        $p = $it.Tag
        if (-not (Confirm-Yes "Uninstall $($p.Name)?`n`nIts own uninstaller will open. Afterwards CleanIT shows any leftovers it finds.")) { return }
        $rp = Get-RestorePointChoice
        if ($null -eq $rp) { return }
        if ($rp) {
            $script:RestorePointMade = $true
            [void](Start-BgJob 'Creating restore point' { [void](New-CleanITRestorePoint 'Before uninstall') } -Data $p -OnDone { param($out, $j) & $startUninstall $j.Data })
        }
        else { & $startUninstall $p }
    })

    $appTabs.TabPages.AddRange(@($tpBloat, $tpProg))
    $appTabs.Add_SelectedIndexChanged({ if ($appTabs.SelectedTab -eq $tpProg -and -not $S.Programs) { & $loadPrograms } })
    $pages['Apps'] = $tpApps
}

function Add-UpdatesTab {
    $tpUpd = New-Object System.Windows.Forms.TabPage 'Updates'
    $updTabs = New-Object System.Windows.Forms.TabControl
    $updTabs.Dock = 'Fill'
    $tpUpd.Controls.Add($updTabs)

    # ---------- Apps (winget) ----------
    $tpWg = New-Object System.Windows.Forms.TabPage 'Apps (winget)'
    $lvWg = New-ListView @(@('App', 300), @('Id', 280), @('Installed', 150), @('Available', 150), @('Note', 160)) -CheckBoxes
    $barWg = New-Bar
    $btnWgCheck = New-Button 'Check for updates' 160 -Primary
    $btnWgUpdate = New-Button 'Update checked' 140 -Primary
    $btnWgExclude = New-Button 'Never update selected / allow again' 260
    $lblWg = New-Label 'Excluded apps are skipped by "Update", the weekly task and -Updates.' -Muted
    $barWg.Controls.AddRange(@($btnWgCheck, $btnWgUpdate, $btnWgExclude, $lblWg))
    $tpWg.Controls.Add($lvWg); $tpWg.Controls.Add($barWg); $lvWg.BringToFront()

    $loadWinget = {
        if (-not (Test-Winget)) { $lblWg.Text = "winget isn't available. Install 'App Installer' from the Microsoft Store."; return }
        $btnWgCheck.Enabled = $false; $btnWgUpdate.Enabled = $false
        Reset-ListView $lvWg
        $lblWg.Text = 'Checking...'
        [void](Start-BgJob 'Checking app updates' { @(Get-WingetUpgrades) } -OnDone {
            param($out)
            foreach ($u in @($out | Where-Object { $_.Id })) {
                $note = ''; $color = $null
                if ($u.Excluded) { $note = 'excluded'; $color = $script:Muted }
                elseif ($u.Version -eq 'Unknown') { $note = 'version unknown' }
                [void](Add-LvRow $lvWg @($u.Name, $u.Id, $u.Version, $u.Available, $note) $u (-not $u.Excluded) -Color $color)
            }
            $n = @($out | Where-Object { $_.Id -and -not $_.Excluded }).Count
            $lblWg.Text = "$n update(s) available."
            $btnWgCheck.Enabled = $true; $btnWgUpdate.Enabled = $true
        })
    }
    $btnWgCheck.Add_Click({ & $loadWinget })
    $btnWgUpdate.Add_Click({
        $ids = @($lvWg.CheckedItems | ForEach-Object { $_.Tag.Id })
        if (-not $ids.Count) { Show-Info 'Tick the apps to update first.'; return }
        if (-not (Confirm-Yes "Silently update $($ids.Count) app(s)? Save your work first - some apps may close.")) { return }
        $btnWgUpdate.Enabled = $false; $btnWgCheck.Enabled = $false
        [void](Start-BgJob 'Updating apps' { param($Ids) Invoke-WingetUpgrade $Ids } @(, $ids) -OnDone { & $loadWinget })
    })
    $btnWgExclude.Add_Click({
        $it = $lvWg.SelectedItems | Select-Object -First 1
        if (-not $it) { Show-Info 'Select an app first.'; return }
        $id = $it.Tag.Id
        $list = New-Object System.Collections.Generic.List[string]
        foreach ($x in @($script:Settings.WingetExclude)) { if ($x) { $list.Add($x) } }
        if ($list.Contains($id)) { [void]$list.Remove($id); Write-Log "winget: $id will be updated again." 'OK'; $it.SubItems[4].Text = ''; $it.ForeColor = [System.Drawing.SystemColors]::WindowText }
        else { $list.Add($id); Write-Log "winget: $id excluded from updates." 'OK'; $it.SubItems[4].Text = 'excluded'; $it.Checked = $false; $it.ForeColor = $script:Muted }
        $script:Settings.WingetExclude = $list.ToArray()
        Save-Settings $script:Settings
    })

    # ---------- Windows Update + drivers (same layout) ----------
    $newWuPage = {
        param([string]$Title, [string]$Type, [string]$Hint)
        $tp = New-Object System.Windows.Forms.TabPage $Title
        $cols = @(@('Update', 560), @('KB', 100), @('Size', 90), @('Severity', 90), @('Restart', 70))
        if ($Type -eq 'Driver') { $cols = @(@('Driver update', 520), @('Maker / class', 230), @('Size', 90), @('Restart', 70)) }
        $lv = New-ListView $cols -CheckBoxes
        $bar = New-Bar
        $bCheck = New-Button 'Check' 100 -Primary
        $bInst = New-Button 'Install checked' 140 -Primary
        $bOpen = New-Button 'Open Windows Update' 170
        $lbl = New-Label $Hint -Muted
        $bar.Controls.AddRange(@($bCheck, $bInst, $bOpen, $lbl))
        $tp.Controls.Add($lv); $tp.Controls.Add($bar); $lv.BringToFront()
        $ctx = [pscustomobject]@{ Type = $Type; Lv = $lv; Check = $bCheck; Install = $bInst; Label = $lbl }
        $bCheck.Tag = $ctx; $bInst.Tag = $ctx
        $bCheck.Add_Click({ & $loadWu $this.Tag })
        $bInst.Add_Click({
            $c = $this.Tag
            $ids = @($c.Lv.CheckedItems | ForEach-Object { $_.Tag.Id })
            if (-not $ids.Count) { Show-Info 'Tick the updates to install first.'; return }
            if (-not (Confirm-Yes "Download and install $($ids.Count) update(s)? This can take a while; a restart may be needed.")) { return }
            $c.Install.Enabled = $false; $c.Check.Enabled = $false
            [void](Start-BgJob "Installing $($c.Type.ToLower()) updates" { param($Ids, $Type) Install-WindowsUpdates -Ids $Ids -Type $Type } @($ids, $c.Type) -Data $c -OnDone {
                param($out, $j) & $loadWu $j.Data
            })
        })
        $bOpen.Add_Click({ Start-Process 'ms-settings:windowsupdate' })
        [void]$updTabs.TabPages.Add($tp)
        $ctx
    }
    $loadWu = {
        param($c)
        $c.Check.Enabled = $false; $c.Install.Enabled = $false
        Reset-ListView $c.Lv
        $c.Label.Text = 'Searching Windows Update (can take a few minutes)...'
        [void](Start-BgJob "Checking $($c.Type.ToLower()) updates" { param($Type) @(Get-WindowsUpdateList -Type $Type) } @($c.Type) -Data $c -OnDone {
            param($out, $j)
            $c = $j.Data
            foreach ($u in @($out | Where-Object { $_.Id })) {
                $rb = 'no'; if ($u.Reboot) { $rb = 'yes' }
                $title = $u.Title; if ($u.NeedsInput) { $title += '  (install from Settings)' }
                if ($c.Type -eq 'Driver') { [void](Add-LvRow $c.Lv @($title, $u.Driver, @{ T = (Format-Size $u.Size); K = [double]$u.Size }, $rb) $u (-not $u.NeedsInput)) }
                else { [void](Add-LvRow $c.Lv @($title, $u.KB, @{ T = (Format-Size $u.Size); K = [double]$u.Size }, $u.Severity, $rb) $u (-not $u.NeedsInput)) }
            }
            $c.Label.Text = "$($c.Lv.Items.Count) update(s) available."
            $c.Check.Enabled = $true; $c.Install.Enabled = $true
        })
    }
    [void]$updTabs.TabPages.Add($tpWg)
    $wuCtx = & $newWuPage 'Windows Update' 'Software' 'Security and quality updates from Microsoft.'
    $drvCtx = & $newWuPage 'Drivers' 'Driver' 'Official drivers published through Windows Update. GPU vendors (NVIDIA/AMD/Intel) are usually newer in their own app.'
    $updTabs.Add_SelectedIndexChanged({
        if ($updTabs.SelectedIndex -eq 1 -and -not $S.WuLoaded) { $S.WuLoaded = $true; & $loadWu $wuCtx }
        if ($updTabs.SelectedIndex -eq 2 -and -not $S.DrvLoaded) { $S.DrvLoaded = $true; & $loadWu $drvCtx }
    })
    $pages['Updates'] = $tpUpd
}

function Add-PrivacyTab {
    $tpPriv = New-Object System.Windows.Forms.TabPage 'Privacy'
    $lvPriv = New-ListView @(@('Setting', 330), @('Now', 150), @('Recommended', 100), @('What it does', 600)) -CheckBoxes
    $privGroups = @{}
    foreach ($gName in @('Ads', 'Telemetry', 'Search', 'AI')) {
        $label = @{ Ads = 'Ads & suggestions'; Telemetry = 'Data collection'; Search = 'Search'; AI = 'AI features' }[$gName]
        $g = New-Object System.Windows.Forms.ListViewGroup($label); [void]$lvPriv.Groups.Add($g); $privGroups[$gName] = $g
    }
    $barPriv = New-Bar
    $btnPrivRefresh = New-Button 'Refresh' 100
    $btnPrivApply = New-Button 'Apply' 100 -Primary
    $btnPrivRec = New-Button 'Tick recommended' 150
    $btnPrivRestore = New-Button 'Restore everything CleanIT changed' 260
    $btnPrivExplorer = New-Button 'Restart Explorer' 140
    $lblPriv = New-Label 'Ticked = privacy setting on. Original values are saved and can be restored.' -Muted
    $barPriv.Controls.AddRange(@($btnPrivRefresh, $btnPrivApply, $btnPrivRec, $btnPrivRestore, $btnPrivExplorer, $lblPriv))
    $tpPriv.Controls.Add($lvPriv); $tpPriv.Controls.Add($barPriv); $lvPriv.BringToFront()

    $loadPrivacy = {
        Reset-ListView $lvPriv
        $n = 0
        foreach ($s in Get-PrivacyStatus) {
            $now = 'Windows default'
            if ($s.Protected) { $now = 'Protected'; $n++ }
            elseif ($s.ChangedByCleanIT) { $now = 'Partly applied' }
            $rec = ''; if ($s.Item.Recommended) { $rec = 'yes' }
            $color = $null; if ($s.Protected) { $color = $script:LevelColors.OK }
            [void](Add-LvRow $lvPriv @($s.Item.Name, $now, $rec, $s.Item.Description) $s $s.Protected $privGroups[$s.Item.Group] -Color $color)
        }
        $lblPriv.Text = "$n of $($lvPriv.Items.Count) privacy settings on. Some changes need Explorer restart or sign-out."
    }
    $btnPrivRefresh.Add_Click({ & $loadPrivacy })
    $btnPrivRec.Add_Click({ foreach ($it in $lvPriv.Items) { $it.Checked = $it.Tag.Protected -or $it.Tag.Item.Recommended } })
    $applyPrivacy = {
        param($Changes)
        foreach ($c in $Changes) {
            try { Set-PrivacyItem $c.Item $c.Protect } catch { Write-Log "Privacy: $($c.Item.Name) - $($_.Exception.Message)" 'ERROR' }
        }
        & $loadPrivacy
    }
    $btnPrivApply.Add_Click({
        $changes = @(foreach ($it in $lvPriv.Items) {
            if ($it.Checked -ne $it.Tag.Protected) { [pscustomobject]@{ Item = $it.Tag.Item; Protect = $it.Checked } }
        })
        if (-not $changes.Count) { Write-Log 'Privacy: nothing to change.'; return }
        $rp = Get-RestorePointChoice
        if ($null -eq $rp) { return }
        if ($rp) {
            $script:RestorePointMade = $true
            [void](Start-BgJob 'Creating restore point' { [void](New-CleanITRestorePoint 'Before privacy changes') } -Data $changes -OnDone { param($out, $j) & $applyPrivacy $j.Data })
        }
        else { & $applyPrivacy $changes }
    })
    $btnPrivRestore.Add_Click({
        if (-not (Confirm-Yes 'Put every privacy setting CleanIT changed back to how it was before?')) { return }
        Restore-AllPrivacy; & $loadPrivacy
    })
    $btnPrivExplorer.Add_Click({ Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force; Write-Log 'Explorer restarted.' 'OK' })
    $pages['Privacy'] = $tpPriv
}

function Add-SecurityTab {
    $tpSec = New-Object System.Windows.Forms.TabPage 'Security'
    $lvSec = New-ListView @(@('Status', 80), @('Check', 230), @('Details', 760))
    $barSec = New-Bar
    $btnSecCheck = New-Button 'Re-check' 100 -Primary
    $btnSecScan = New-Button 'Defender quick scan' 170
    $btnSecSig = New-Button 'Update signatures' 150
    $btnSecFw = New-Button 'Turn firewall on' 140
    $btnSecOpen = New-Button 'Open Windows Security' 180
    $lblSec = New-Label 'Double-click a row to fix it where possible.' -Muted
    $barSec.Controls.AddRange(@($btnSecCheck, $btnSecScan, $btnSecSig, $btnSecFw, $btnSecOpen, $lblSec))
    $tpSec.Controls.Add($lvSec); $tpSec.Controls.Add($barSec); $lvSec.BringToFront()

    $loadSecurity = {
        $btnSecCheck.Enabled = $false
        Reset-ListView $lvSec
        [void](Start-BgJob 'Security check' { @(Get-SecurityChecks) } -OnDone {
            param($out)
            $order = @{ BAD = 0; WARN = 1; INFO = 2; OK = 3 }
            $fw = $false
            foreach ($c in @($out | Where-Object { $_.Name } | Sort-Object { $order[$_.Level] })) {
                [void](Add-LvRow $lvSec @($c.Level, $c.Name, $c.Detail) $c -Color $script:LevelColors[$c.Level])
                if ($c.Fix -eq 'EnableFirewall') { $fw = $true }
            }
            $btnSecFw.Enabled = $fw
            $bad = @($out | Where-Object { $_.Level -eq 'BAD' }).Count
            $warn = @($out | Where-Object { $_.Level -eq 'WARN' }).Count
            $lblSec.Text = "$bad problem(s), $warn warning(s). Double-click a row to fix it where possible."
            $btnSecCheck.Enabled = $true
        })
    }
    $runSecFix = {
        param([string]$Fix)
        switch ($Fix) {
            'QuickScan' { [void](Start-BgJob 'Defender quick scan' { Invoke-DefenderQuickScan } -OnDone { & $loadSecurity }) }
            'UpdateSignatures' { [void](Start-BgJob 'Updating Defender signatures' { Update-DefenderSignatures } -OnDone { & $loadSecurity }) }
            'EnableFirewall' {
                if (Confirm-Yes 'Turn Windows Firewall on for all network profiles?') {
                    Set-NetFirewallProfile -All -Enabled True; Write-Log 'Firewall turned on for all profiles.' 'OK'; & $loadSecurity
                }
            }
            'OpenSecurity' { Start-Process 'windowsdefender:' }
            'GoUpdates' { $tabs.SelectedTab = $pages['Updates'] }
        }
    }
    $btnSecCheck.Add_Click({ & $loadSecurity })
    $btnSecScan.Add_Click({ & $runSecFix 'QuickScan' })
    $btnSecSig.Add_Click({ & $runSecFix 'UpdateSignatures' })
    $btnSecFw.Add_Click({ & $runSecFix 'EnableFirewall' })
    $btnSecOpen.Add_Click({ & $runSecFix 'OpenSecurity' })
    $lvSec.Add_DoubleClick({ $it = $lvSec.SelectedItems | Select-Object -First 1; if ($it -and $it.Tag.Fix) { & $runSecFix $it.Tag.Fix } })
    $pages['Security'] = $tpSec
}

function Add-HealthTab {
    $tpHealth = New-Object System.Windows.Forms.TabPage 'Health'
    $txtHealth = New-Object System.Windows.Forms.TextBox
    $txtHealth.Multiline = $true; $txtHealth.ReadOnly = $true; $txtHealth.ScrollBars = 'Vertical'
    $txtHealth.Dock = 'Fill'; $txtHealth.Font = $monoFont; $txtHealth.BackColor = [System.Drawing.Color]::White; $txtHealth.BorderStyle = 'None'
    $barHealth = New-Bar
    $btnHealth = New-Button 'Refresh' 100 -Primary
    $btnOpt = New-Button 'Optimize drives' 140
    $btnRepair = New-Button 'Repair Windows (DISM + SFC)' 220
    $btnBattery = New-Button 'Battery report' 130
    $btnDns = New-Button 'Fix network (flush DNS)' 190
    $barHealth.Controls.AddRange(@($btnHealth, $btnOpt, $btnRepair, $btnBattery, $btnDns))
    $tpHealth.Controls.Add($txtHealth); $tpHealth.Controls.Add($barHealth); $txtHealth.BringToFront()
    if (-not (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)) { $btnBattery.Visible = $false }

    $loadHealth = {
        $txtHealth.Text = 'Gathering...'
        $btnHealth.Enabled = $false
        [void](Start-BgJob 'Health report' { Get-HealthReport } -OnDone {
            param($out)
            $txtHealth.Text = [string]($out | Select-Object -Last 1)
            $btnHealth.Enabled = $true
        })
    }
    $btnHealth.Add_Click({ & $loadHealth })
    $btnOpt.Add_Click({
        if (-not (Confirm-Yes "Optimize all drives the way Windows recommends?`n`nSSDs get TRIM (never defragmented); hard disks get defragmented.")) { return }
        $btnOpt.Enabled = $false
        [void](Start-BgJob 'Optimizing drives' { Invoke-DriveOptimize } -OnDone { $btnOpt.Enabled = $true })
    })
    $btnRepair.Add_Click({
        if (-not (Confirm-Yes "Check and repair Windows system files?`n`nRuns DISM /RestoreHealth then sfc /scannow. Takes 10-30 minutes; you can keep using the PC.")) { return }
        $btnRepair.Enabled = $false
        [void](Start-BgJob 'Repairing Windows' { Invoke-WindowsRepair } -OnDone { $btnRepair.Enabled = $true })
    })
    $btnBattery.Add_Click({
        $out = Join-Path $script:DataDir 'battery-report.html'
        & powercfg.exe /batteryreport /output $out 2>&1 | Out-Null
        if (Test-Path -LiteralPath $out) { Start-Process $out; Write-Log "Battery report: $out" 'OK' }
    })
    $btnDns.Add_Click({
        & ipconfig.exe /flushdns 2>&1 | Out-Null
        Write-Log 'DNS cache flushed. If websites still fail, restart the router or use Settings > Network reset.' 'OK'
    })
    $pages['Health'] = $tpHealth
}

function Add-SettingsTab {
    $tpSet = New-Object System.Windows.Forms.TabPage 'Settings'
    $tpSet.AutoScroll = $true
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'; $flow.FlowDirection = 'TopDown'; $flow.WrapContents = $false; $flow.AutoScroll = $true
    $flow.Padding = New-Object System.Windows.Forms.Padding(10)
    $tpSet.Controls.Add($flow)
    $newGroup = {
        param([string]$Title)
        $g = New-Object System.Windows.Forms.GroupBox
        $g.Text = $Title; $g.Width = 1040; $g.AutoSize = $true; $g.AutoSizeMode = 'GrowAndShrink'
        $g.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 8); $g.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
        $f = New-Object System.Windows.Forms.FlowLayoutPanel
        $f.Dock = 'Fill'; $f.AutoSize = $true; $f.AutoSizeMode = 'GrowAndShrink'; $f.WrapContents = $true; $f.MaximumSize = New-Object System.Drawing.Size(1020, 0)
        $g.Controls.Add($f)
        [void]$flow.Controls.Add($g)
        $f
    }

    # Safety
    $fSafe = & $newGroup 'Safety'
    $chkRp = New-CheckBox 'Create a restore point before cleaning or changing system settings (once per session)' ([bool]$script:Settings.RestorePoint)
    $btnRpNow = New-Button 'Create restore point now' 190
    $btnRstrui = New-Button 'Open System Restore' 170
    $lblProt = New-Label '' -Muted
    $fSafe.Controls.AddRange(@($chkRp, $btnRpNow, $btnRstrui, $lblProt))
    $fSafe.SetFlowBreak($chkRp, $true)
    $prot = Test-SystemProtection
    if ($prot -eq $false) { $lblProt.Text = "System Protection is OFF for $env:SystemDrive - CleanIT will offer to turn it on."; $lblProt.ForeColor = $script:LevelColors.WARN }
    elseif ($prot) { $lblProt.Text = "System Protection is on for $env:SystemDrive." }
    $chkRp.Add_CheckedChanged({ $script:Settings.RestorePoint = $chkRp.Checked; Save-Settings $script:Settings })
    $btnRpNow.Add_Click({
        if ((Test-SystemProtection) -eq $false) {
            if (-not (Confirm-Yes "System Protection is off for $env:SystemDrive. Turn it on (uses up to 5% of the drive)?")) { return }
            try { Enable-SystemProtection } catch { Show-Info $_.Exception.Message 'Warning'; return }
        }
        $btnRpNow.Enabled = $false
        [void](Start-BgJob 'Creating restore point' { [void](New-CleanITRestorePoint 'Manual restore point') } -OnDone { $btnRpNow.Enabled = $true })
    })
    $btnRstrui.Add_Click({ Start-Process "$env:SystemRoot\System32\rstrui.exe" })

    # Schedule
    $fSched = & $newGroup 'Automatic weekly clean (runs as SYSTEM, catches up if the PC was off)'
    $chkSched = New-CheckBox 'Weekly auto-clean of the recommended categories' (Test-Schedule)
    $cbDay = New-Object System.Windows.Forms.ComboBox
    $cbDay.DropDownStyle = 'DropDownList'; $cbDay.Width = 110; $cbDay.Margin = New-Object System.Windows.Forms.Padding(4, 10, 4, 0)
    foreach ($d in [Enum]::GetNames([DayOfWeek])) { [void]$cbDay.Items.Add($d) }
    $cbDay.SelectedItem = [string]$script:Settings.ScheduleDay
    $txtTime = New-Object System.Windows.Forms.TextBox
    $txtTime.Width = 60; $txtTime.Text = [string]$script:Settings.ScheduleTime; $txtTime.Margin = New-Object System.Windows.Forms.Padding(4, 10, 4, 0)
    $chkSchedUpd = New-CheckBox 'Also update apps (winget)' ([bool]$script:Settings.ScheduleUpdates)
    $btnSchedSave = New-Button 'Save schedule' 130 -Primary
    $fSched.Controls.AddRange(@($chkSched, (New-Label 'Day:'), $cbDay, (New-Label 'Time (HH:mm):'), $txtTime, $chkSchedUpd, $btnSchedSave))
    $btnSchedSave.Add_Click({
        $t = $txtTime.Text.Trim()
        try { [void][datetime]::ParseExact($t, 'HH:mm', $null) } catch { Show-Info 'Time must look like 03:00 or 21:30.' 'Warning'; return }
        $script:Settings.ScheduleDay = [string]$cbDay.SelectedItem
        $script:Settings.ScheduleTime = $t
        $script:Settings.ScheduleUpdates = $chkSchedUpd.Checked
        Save-Settings $script:Settings
        if ($chkSched.Checked) { Install-Schedule $script:AppDir } else { Remove-Schedule }
    })

    # Fleet
    $fFleet = & $newGroup 'Multi-PC reports (fleet)'
    $txtFleet = New-Object System.Windows.Forms.TextBox
    $txtFleet.Width = 420; $txtFleet.Text = [string]$script:Settings.FleetPath; $txtFleet.Margin = New-Object System.Windows.Forms.Padding(4, 10, 4, 0)
    $btnFleetBrowse = New-Button 'Browse...' 90
    $btnFleetSave = New-Button 'Save' 70 -Primary
    $btnFleetNow = New-Button 'Write report now' 140
    $btnFleetView = New-Button 'Fleet view' 100
    $lblFleet = New-Label 'Shared folder (e.g. \\NAS\CleanIT). Each PC writes COMPUTERNAME.json after every clean. The weekly task runs as SYSTEM, so the share must allow the PC account (or use a local synced folder).' -Muted
    $lblFleet.MaximumSize = New-Object System.Drawing.Size(1000, 0)
    $fFleet.Controls.AddRange(@($txtFleet, $btnFleetBrowse, $btnFleetSave, $btnFleetNow, $btnFleetView, $lblFleet))
    $fFleet.SetFlowBreak($btnFleetView, $true)
    $btnFleetBrowse.Add_Click({ $p = Select-Folder $txtFleet.Text; if ($p) { $txtFleet.Text = $p } })
    $btnFleetSave.Add_Click({ $script:Settings.FleetPath = $txtFleet.Text.Trim(); Save-Settings $script:Settings; Write-Log "Fleet folder set to '$($script:Settings.FleetPath)'." 'OK' })
    $btnFleetNow.Add_Click({
        $script:Settings.FleetPath = $txtFleet.Text.Trim(); Save-Settings $script:Settings
        [void](Start-BgJob 'Writing fleet report' { Write-FleetReport })
    })
    $btnFleetView.Add_Click({ Show-FleetDialog })

    # Undo
    $fUndo = & $newGroup 'Undo center'
    $btnUndoStart = New-Button 'Undo startup changes' 170
    $btnUndoPriv = New-Button 'Restore privacy settings' 190
    $btnUndoApps = New-Button 'Reinstall removed apps...' 190
    $btnBackups = New-Button 'Registry backups folder' 190
    $btnRstrui2 = New-Button 'System Restore' 130
    $fUndo.Controls.AddRange(@($btnUndoStart, $btnUndoPriv, $btnUndoApps, $btnBackups, $btnRstrui2))
    $btnUndoStart.Add_Click({
        if (Confirm-Yes 'Re-enable every startup item, task and service CleanIT turned off?') { [void](Start-BgJob 'Undoing startup changes' { Undo-AllStartupChanges }) }
    })
    $btnUndoPriv.Add_Click({ if (Confirm-Yes 'Put every privacy setting CleanIT changed back?') { Restore-AllPrivacy } })
    $btnUndoApps.Add_Click({ Show-RemovedAppsDialog })
    $btnBackups.Add_Click({ Open-InExplorer $script:BackupDir })
    $btnRstrui2.Add_Click({ Start-Process "$env:SystemRoot\System32\rstrui.exe" })

    # App
    $fApp = & $newGroup "About CleanIT $($script:Version)"
    $btnInstall = New-Button 'Install (Start menu + desktop)' 230 -Primary
    $btnUninstall = New-Button 'Remove shortcuts & tasks' 200
    $btnLogs = New-Button 'Open logs' 100
    $btnData = New-Button 'Open data folder' 140
    $lblAbout = New-Label "Data: $($script:DataDir)    Running from: $($script:AppDir)" -Muted
    $fApp.Controls.AddRange(@($btnInstall, $btnUninstall, $btnLogs, $btnData, $lblAbout))
    $fApp.SetFlowBreak($btnData, $true)
    $btnInstall.Add_Click({ Install-CleanITApp $script:AppDir; Show-Info "CleanIT is installed in $($script:DataDir).`nUse the Start menu or desktop shortcut from now on." })
    $btnUninstall.Add_Click({ if (Confirm-Yes 'Remove CleanIT shortcuts and scheduled tasks? (Settings, logs and backups are kept.)') { Uninstall-CleanITApp; $chkSched.Checked = $false } })
    $btnLogs.Add_Click({ Open-InExplorer $script:LogDir })
    $btnData.Add_Click({ Open-InExplorer $script:DataDir })
    $pages['Settings'] = $tpSet
}

# ---------------------------------------------------------------------------
# Dialogs
# ---------------------------------------------------------------------------
function New-Dialog {
    param([string]$Title, [int]$Width = 900, [int]$Height = 520)
    $d = New-Object System.Windows.Forms.Form
    $d.Text = $Title; $d.Size = New-Object System.Drawing.Size($Width, $Height)
    $d.StartPosition = 'CenterParent'; $d.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $d.MinimizeBox = $false; $d.ShowInTaskbar = $false; $d.BackColor = [System.Drawing.Color]::White
    $d
}

function Show-LeftoversDialog {
    param($Program, [object[]]$Hits)
    $d = New-Dialog "Leftovers of $($Program.Name)" 1000 520
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Dock = 'Top'; $lbl.Height = 44; $lbl.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 0)
    $lbl.Text = "These look like leftovers. Nothing is ticked - check each one. Folders go to the Recycle Bin; registry keys are backed up to a .reg file first."
    $lv = New-ListView @(@('Type', 80), @('Path', 560), @('Size', 90), @('Why', 230)) -CheckBoxes
    foreach ($h in $Hits) { [void](Add-LvRow $lv @($h.Type, $h.Path, @{ T = (Format-Size $h.Size); K = [double]$h.Size }, $h.Reason) $h) }
    $bar = New-Bar
    $bRemove = New-Button 'Remove checked' 140 -Primary
    $bOpen = New-Button 'Open' 80
    $bClose = New-Button 'Close' 80
    $bar.Controls.AddRange(@($bRemove, $bOpen, $bClose))
    $d.Controls.Add($lv); $d.Controls.Add($lbl); $d.Controls.Add($bar); $lv.BringToFront()
    $bRemove.Add_Click({
        $sel = @($lv.CheckedItems)
        if (-not $sel.Count) { return }
        if (-not (Confirm-Yes "Remove $($sel.Count) leftover item(s)?")) { return }
        foreach ($i in $sel) {
            try { Remove-Leftover $i.Tag; $lv.Items.Remove($i) } catch { Write-Log "Leftover not removed ($($i.Tag.Path)): $($_.Exception.Message)" 'WARN' }
        }
    })
    $bOpen.Add_Click({
        $it = $lv.SelectedItems | Select-Object -First 1
        if (-not $it) { return }
        if ($it.Tag.Type -eq 'Folder') { Open-InExplorer $it.Tag.Path }
        else {
            Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Applets\Regedit' -Name LastKey -Value ('Computer\' + $it.Tag.Path)
            Start-Process regedit.exe
        }
    })
    $bClose.Add_Click({ $d.Close() })
    [void]$d.ShowDialog()
}

function Show-RemovedAppsDialog {
    $d = New-Dialog 'Reinstall removed apps' 760 460
    $lv = New-ListView @(@('App', 260), @('Package', 300), @('Removed', 140))
    foreach ($a in @(Get-RemovedApps)) {
        $dt = ''; try { $dt = ([datetime]$a.Date).ToString('yyyy-MM-dd HH:mm') } catch {}
        [void](Add-LvRow $lv @($a.Label, $a.Name, $dt) $a)
    }
    $bar = New-Bar
    $bStore = New-Button 'Open in Microsoft Store' 200 -Primary
    $bClose = New-Button 'Close' 80
    $bar.Controls.AddRange(@($bStore, $bClose, (New-Label 'Double-click an app to open its Store page.' -Muted)))
    $d.Controls.Add($lv); $d.Controls.Add($bar); $lv.BringToFront()
    $open = {
        $it = $lv.SelectedItems | Select-Object -First 1
        if (-not $it) { return }
        if ($it.Tag.Family) { Start-Process ("ms-windows-store://pdp/?PFN=" + $it.Tag.Family) }
        else { Start-Process ("ms-windows-store://search/?query=" + [uri]::EscapeDataString($it.Tag.Label)) }
    }
    $bStore.Add_Click({ & $open })
    $lv.Add_DoubleClick({ & $open })
    $bClose.Add_Click({ $d.Close() })
    [void]$d.ShowDialog()
}

function Show-FleetDialog {
    $d = New-Dialog 'CleanIT fleet view' 1150 520
    $lv = New-ListView @(@('PC', 140), @('Report', 120), @('Score', 60), @('Free C:', 110), @('Freed total', 100), @('Last clean', 110),
                         @('Updates', 90), @('Reboot', 60), @('Top issue', 380))
    $bar = New-Bar
    $bRef = New-Button 'Refresh' 100 -Primary
    $bClose = New-Button 'Close' 80
    $lbl = New-Label '' -Muted
    $bar.Controls.AddRange(@($bRef, $bClose, $lbl))
    $d.Controls.Add($lv); $d.Controls.Add($bar); $lv.BringToFront()
    $load = {
        Reset-ListView $lv
        $path = (Get-Settings).FleetPath
        if (-not $path) { $lbl.Text = 'Set a shared folder on the Settings tab first.'; return }
        $n = 0
        foreach ($r in @(Get-FleetReports)) {
            $t = [datetime]::MinValue; try { $t = [datetime]$r.Time } catch {}
            $lc = ''; if ($r.LastClean) { try { $lc = Format-Ago ([datetime]$r.LastClean) } catch {} }
            $rb = ''; if ($r.PendingReboot) { $rb = 'yes' }
            $top = ''; if (@($r.Issues).Count) { $top = @($r.Issues)[0] }
            $color = Get-ScoreColor ([int]$r.Score)
            [void](Add-LvRow $lv @($r.Computer, @{ T = (Format-Ago $t); K = $t }, @{ T = [string]$r.Score; K = [double]$r.Score },
                @{ T = ('{0} ({1}%)' -f (Format-Size $r.FreeBytes), $r.FreePct); K = [double]$r.FreePct }, @{ T = (Format-Size $r.FreedTotal); K = [double]$r.FreedTotal },
                $lc, ('{0} apps / {1} Win' -f $r.AppUpdates, $r.WinUpdates), $rb, $top) $r -Color $color)
            $n++
        }
        $lbl.Text = "$n PC(s) in $path"
    }
    $bRef.Add_Click({ & $load })
    $bClose.Add_Click({ $d.Close() })
    & $load
    [void]$d.ShowDialog()
}

# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------
function Show-Gui {
    param([string]$RenderTo, [scriptblock]$RenderHook)
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
    [System.Windows.Forms.Application]::EnableVisualStyles()
    Initialize-Native

    $script:Settings = Get-Settings
    $script:BgJobs = New-Object System.Collections.ArrayList
    $script:RestorePointMade = $false
    $S = @{ Score = -1; Sizes = @{}; Running = @{} }   # mutable state shared by event handlers
    $pages = @{}

    $uiFont    = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $boldFont  = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
    $monoFont  = New-Object System.Drawing.Font('Consolas', 9.5)
    $cardFont  = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
    $scoreFont = New-Object System.Drawing.Font('Segoe UI Semibold', 30)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "CleanIT $($script:Version)  -  $env:COMPUTERNAME"
    $form.Size = New-Object System.Drawing.Size(1240, 840)
    $form.MinimumSize = New-Object System.Drawing.Size(940, 620)
    $form.StartPosition = 'CenterScreen'
    $form.Font = $uiFont
    $form.BackColor = [System.Drawing.Color]::White
    $form.Icon = [System.Drawing.Icon]::FromHandle((Get-CleanITIconBitmap 32).GetHicon())

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Top'; $header.Height = 60; $header.BackColor = $script:Dark
    $logo = New-Object System.Windows.Forms.PictureBox
    $logo.Image = Get-CleanITIconBitmap 40; $logo.Size = New-Object System.Drawing.Size(40, 40)
    $logo.Location = New-Object System.Drawing.Point(14, 10)
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = 'CleanIT'; $lblTitle.AutoSize = $true; $lblTitle.ForeColor = [System.Drawing.Color]::White
    $lblTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 16); $lblTitle.Location = New-Object System.Drawing.Point(60, 4)
    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.Text = "Clean  -  Speed up  -  Protect          $env:COMPUTERNAME   |   v$($script:Version)   |   no ads, no telemetry, everything logged"
    $lblSub.AutoSize = $true; $lblSub.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184); $lblSub.Location = New-Object System.Drawing.Point(62, 35)
    $header.Controls.AddRange(@($logo, $lblTitle, $lblSub))

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'; $split.Orientation = 'Horizontal'; $split.FixedPanel = 'Panel2'; $split.SplitterWidth = 6
    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'; $tabs.Padding = New-Object System.Drawing.Point(14, 6)
    $split.Panel1.Controls.Add($tabs)
    $log = New-Object System.Windows.Forms.RichTextBox
    $log.ReadOnly = $true; $log.Dock = 'Fill'; $log.Font = $monoFont; $log.BorderStyle = 'None'
    $log.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 27); $log.ForeColor = [System.Drawing.Color]::FromArgb(212, 212, 216)
    $split.Panel2.Controls.Add($log)
    $script:LogSink = $log

    $status = New-Object System.Windows.Forms.StatusStrip
    $stLabel = New-Object System.Windows.Forms.ToolStripStatusLabel 'Ready'
    $stLabel.Spring = $true; $stLabel.TextAlign = 'MiddleLeft'
    $stProg = New-Object System.Windows.Forms.ToolStripProgressBar
    $stProg.Width = 180; $stProg.Visible = $false
    $stCancel = New-Object System.Windows.Forms.ToolStripButton 'Cancel'
    $stCancel.Visible = $false
    [void]$status.Items.AddRange(@($stLabel, $stProg, $stCancel))
    $stCancel.Add_Click({ Stop-AllBgJobs; Write-Log 'Cancel requested - stopping after the current step.' 'WARN' })

    $form.Controls.Add($split); $form.Controls.Add($status); $form.Controls.Add($header)

    . Add-DashboardTab
    . Add-CleanTab
    . Add-DiskTab
    . Add-StartupTab
    . Add-AppsTab
    . Add-UpdatesTab
    . Add-PrivacyTab
    . Add-SecurityTab
    . Add-HealthTab
    . Add-SettingsTab
    $tabs.TabPages.AddRange(@($pages['Dashboard'], $pages['Clean'], $pages['Disk'], $pages['Startup'], $pages['Apps'],
                              $pages['Updates'], $pages['Privacy'], $pages['Security'], $pages['Health'], $pages['Settings']))

    $tabs.Add_SelectedIndexChanged({
        $t = $tabs.SelectedTab
        if ($t -eq $pages['Startup'] -and -not $S.StartupLoaded) { $S.StartupLoaded = $true; & $loadStartup }
        if ($t -eq $pages['Apps'] -and -not $S.BloatLoaded) { $S.BloatLoaded = $true; & $loadBloat }
        if ($t -eq $pages['Updates'] -and -not $S.WgLoaded) { $S.WgLoaded = $true; & $loadWinget }
        if ($t -eq $pages['Privacy'] -and -not $S.PrivLoaded) { $S.PrivLoaded = $true; & $loadPrivacy }
        if ($t -eq $pages['Security'] -and -not $S.SecLoaded) { $S.SecLoaded = $true; & $loadSecurity }
        if ($t -eq $pages['Health'] -and -not $S.HealthLoaded) { $S.HealthLoaded = $true; & $loadHealth }
    })

    # One UI timer drives every background job: log lines, progress, completion callbacks.
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 150
    $timer.Add_Tick({
        foreach ($j in @($script:BgJobs)) {
            $done = $j.Handle.IsCompleted
            Receive-BgLog $j
            if ($j.OnTick -and -not $done) { try { & $j.OnTick $j } catch {} }
            if ($done) {
                [void]$script:BgJobs.Remove($j)
                $out = @()
                try { $out = @($j.PS.EndInvoke($j.Handle)) }
                catch {
                    $msg = $_.Exception.Message; if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
                    Write-Log "$($j.Name) failed: $msg" 'ERROR'
                }
                Receive-BgLog $j
                $j.PS.Dispose(); $j.RS.Dispose()
                if ($j.OnDone) {
                    try { & $j.OnDone $out $j }
                    catch { Write-Log "Updating the window after '$($j.Name)' failed: $($_.Exception.Message)" 'ERROR' }
                }
            }
        }
        $jobs = @($script:BgJobs)
        if ($jobs.Count) {
            $first = $jobs[0]
            $txt = 'Working: ' + (($jobs | ForEach-Object { $_.Name }) -join ', ')
            if ($first.Sync.Status -and $first.Sync.Status -ne $first.Name) { $txt += "  -  $($first.Sync.Status)" }
            $stLabel.Text = $txt
            $stProg.Visible = $true; $stCancel.Visible = $true
            if ($first.Sync.Progress -ge 0) { $stProg.Style = 'Continuous'; $stProg.Value = [int]$first.Sync.Progress }
            else { $stProg.Style = 'Marquee' }
        }
        else {
            $stLabel.Text = 'Ready'; $stProg.Visible = $false; $stCancel.Visible = $false
        }
    })
    $timer.Start()

    $form.Add_Shown({
        $split.SplitterDistance = [math]::Max(250, $split.Height - 170)
        & $refreshDashboard
    })
    $form.Add_FormClosing({
        param($sender, $e)
        $jobs = @($script:BgJobs)
        if ($jobs.Count -and -not $RenderTo) {
            $names = ($jobs | ForEach-Object { $_.Name }) -join ', '
            if (-not (Confirm-Yes "Still working on: $names.`n`nClose CleanIT anyway?" 'Warning')) { $e.Cancel = $true; return }
            Stop-AllBgJobs
        }
        $timer.Stop()
    })

    Write-Log "CleanIT $($script:Version) ready. Log file: $($script:LogFile)"

    if ($RenderTo) {
        # Test hook: render every tab to PNG without user interaction.
        $form.Show()
        $wait = {
            $until = (Get-Date).AddSeconds(90)
            do { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 } while ($script:BgJobs.Count -and (Get-Date) -lt $until)
            1..10 | ForEach-Object { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 30 }
        }
        & $wait
        $snap = {
            param([string]$Name)
            & $wait
            $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
            $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
            $bmp.Save((Join-Path $RenderTo "$Name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        }
        foreach ($tp in @($tabs.TabPages)) {
            $tabs.SelectedTab = $tp
            & $snap ('tab_{0:D2}_{1}' -f $tabs.SelectedIndex, $tp.Text)
        }
        if ($RenderHook) { . $RenderHook }
        $form.Close()
        return
    }
    [void]$form.ShowDialog()
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if ($script:IsDotSourced) { return }

if (-not $script:IsCli) {
    Invoke-Migration
    Show-Gui
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
