<#
.SYNOPSIS
  OptiDrop - built by Floki. https://github.com/kennethwaldmer-ship-it/optidrop

  Floating drop target for Add-OptiScaler.ps1. Drag a game folder (or its .exe) onto the
  bubble, pick frame gen / multi-frame / Neural Rendering, then Install / Preview / Remove.

.DESCRIPTION
  Front end only - every real decision still happens in Add-OptiScaler.ps1, which runs in its
  own console window so its coloured output stays live (wrapping/capturing it loses both).

  Left-drag moves the bubble, double-click picks a folder, right-click for options.
  Launch through OptiDrop.vbs so no console flashes.

.PARAMETER InstallShortcut
  Render OptiDrop.ico and create the "OptiDrop" shortcut on the Desktop, then exit.
#>
param([switch]$InstallShortcut)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$Deploy       = Join-Path $PSScriptRoot 'Add-OptiScaler.ps1'
$StateFile    = Join-Path $PSScriptRoot 'optidrop.json'
$IconFile     = Join-Path $PSScriptRoot 'OptiDrop.ico'
$Launcher     = Join-Path $PSScriptRoot 'OptiDrop.vbs'
$ManifestName = '.optiscaler-deploy.json'
$ProjectUrl   = 'https://github.com/kennethwaldmer-ship-it/optidrop'
$Size        = 64
$RestOpacity  = 0.6    # idle; goes solid on hover / drag-over

# Same patterns as Test-AntiCheat in Add-OptiScaler.ps1. Only used to decide whether a
# failed run is worth offering -Force for; the script itself still does the real check.
$AntiCheatPatterns = 'EasyAntiCheat*','EACLauncher*','eac_*','start_protected_game*',
                     'BEService*','BattlEye*','BEClient*','*_EAC.*','EOSAntiCheat*','AntiCheat*'

# ------------------------------------------------------------------------- artwork
function Draw-Bubble([Drawing.Graphics]$g, [int]$s, [bool]$hot) {
    $g.SmoothingMode     = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $rect = New-Object Drawing.Rectangle 1, 1, ($s - 3), ($s - 3)
    if ($hot) { $c1 = [Drawing.Color]::FromArgb(60, 220, 130); $c2 = [Drawing.Color]::FromArgb(10, 90, 55) }
    else      { $c1 = [Drawing.Color]::FromArgb(90, 110, 235); $c2 = [Drawing.Color]::FromArgb(22, 22, 58) }
    $fill = New-Object Drawing.Drawing2D.LinearGradientBrush($rect, $c1, $c2, [single]90)
    $g.FillEllipse($fill, $rect)
    $ring = New-Object Drawing.Pen([Drawing.Color]::FromArgb(170, 255, 255, 255), [single][Math]::Max(1, $s / 30))
    $g.DrawEllipse($ring, $rect)

    # download-style glyph: arrow into a tray
    $pen = New-Object Drawing.Pen([Drawing.Color]::White, [single][Math]::Max(1.5, $s / 13))
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
    $cx = $s / 2
    $g.DrawLine($pen, [single]$cx, [single]($s * 0.20), [single]$cx, [single]($s * 0.48))
    $g.DrawLines($pen, [Drawing.PointF[]]@(
        (New-Object Drawing.PointF ([single]($cx - $s * 0.12)), ([single]($s * 0.37))),
        (New-Object Drawing.PointF ([single]$cx),               ([single]($s * 0.49))),
        (New-Object Drawing.PointF ([single]($cx + $s * 0.12)), ([single]($s * 0.37)))))
    $g.DrawLines($pen, [Drawing.PointF[]]@(
        (New-Object Drawing.PointF ([single]($s * 0.28)), ([single]($s * 0.50))),
        (New-Object Drawing.PointF ([single]($s * 0.28)), ([single]($s * 0.58))),
        (New-Object Drawing.PointF ([single]($s * 0.72)), ([single]($s * 0.58))),
        (New-Object Drawing.PointF ([single]($s * 0.72)), ([single]($s * 0.50)))))

    if ($s -ge 32) {
        $font = New-Object Drawing.Font('Segoe UI', [single]($s * 0.15), [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
        $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
        $g.DrawString('OPTI', $font, [Drawing.Brushes]::White,
            (New-Object Drawing.RectangleF 0, ([single]($s * 0.62)), ([single]$s), ([single]($s * 0.2))), $sf)
        $font.Dispose()
    }
    $fill.Dispose(); $ring.Dispose(); $pen.Dispose()
}

# PNG-in-ICO (Vista+). Icon.FromHandle(...).Save() drops the alpha channel, so build it by hand.
function Save-Icon([string]$Path) {
    $sizes = 256, 48, 32, 16
    $pngs  = New-Object 'System.Collections.Generic.List[byte[]]'
    foreach ($sz in $sizes) {
        $bmp = New-Object Drawing.Bitmap $sz, $sz
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.Clear([Drawing.Color]::Transparent)
        Draw-Bubble $g $sz $false
        $g.Dispose()
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $pngs.Add($ms.ToArray())
    }
    $fs = [IO.File]::Create($Path)
    try {
        $w = New-Object IO.BinaryWriter($fs)
        $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
        $offset = 6 + 16 * $sizes.Count
        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $d = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
            $w.Write([byte]$d); $w.Write([byte]$d); $w.Write([byte]0); $w.Write([byte]0)
            $w.Write([uint16]1); $w.Write([uint16]32)
            $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
            $offset += $pngs[$i].Length
        }
        foreach ($p in $pngs) { $w.Write($p) }
        $w.Flush()
    } finally { $fs.Dispose() }
}

if ($InstallShortcut) {
    Save-Icon $IconFile
    $lnkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'OptiDrop.lnk'
    $sh  = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($lnkPath)
    $lnk.TargetPath       = Join-Path $env:WINDIR 'System32\wscript.exe'
    $lnk.Arguments        = "`"$Launcher`""
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.IconLocation     = "$IconFile,0"
    $lnk.Description      = 'OptiDrop by Floki - drag a game folder on to add/remove OptiScaler'
    $lnk.Save()
    Write-Host "icon     : $IconFile"
    Write-Host "shortcut : $lnkPath"
    exit 0
}

# ------------------------------------------------------------------ single instance
$created = $false
$mutex = New-Object Threading.Mutex($true, 'Local\OptiDropWidget', [ref]$created)
if (-not $created) { exit 0 }

[Windows.Forms.Application]::EnableVisualStyles()

# ------------------------------------------------------------------------- helpers
function Say([string]$text, [string]$icon = 'Information') {
    [void][Windows.Forms.MessageBox]::Show($text, 'OptiDrop', 'OK', $icon)
}

# Single-quote a value for the child's -Command string.
function Q([string]$s) { "'" + $s.Replace("'", "''") + "'" }

function Find-Manifest([string]$Dir) {
    Get-ChildItem -LiteralPath $Dir -Recurse -Depth 6 -Filter $ManifestName -File -Force -ErrorAction SilentlyContinue |
        Select-Object -First 1
}

function Test-AntiCheat([string]$Dir) {
    # Explicit -like, not -Include: PS 5.1's -LiteralPath + -Include returns unrelated files.
    Get-ChildItem -LiteralPath $Dir -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $n = $_.Name; $AntiCheatPatterns | Where-Object { $n -like $_ } } |
        Select-Object -First 8 -ExpandProperty Name | Sort-Object -Unique
}

# Program Files etc. need an elevated child. The widget itself stays un-elevated: Explorer
# cannot drag-drop into an elevated window (UIPI).
function Test-NeedsAdmin([string]$Dir) {
    $probe = Join-Path $Dir ('.optidrop-probe-' + [guid]::NewGuid().ToString('N'))
    try { [IO.File]::WriteAllText($probe, ''); Remove-Item -LiteralPath $probe -Force; $false }
    catch { $true }
}

$FgModes = [ordered]@{
    'fsrfg-2x' = 'FSR 3.1 frame gen - 2x (any GPU)'
    'xefg-2x'  = 'XeSS frame gen - 2x'
    'xefg-3x'  = 'XeSS frame gen - 3x (multi-frame)'
    'xefg-4x'  = 'XeSS frame gen - 4x (multi-frame)'
}
$NrModel = Join-Path $PSScriptRoot 'payload\nvngx_dlssnr.dll'

function Test-Rtx50 {
    [bool](Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'RTX\s*50\d\d' })
}

function Show-Choice([string]$Dir, [string]$Exe, $Manifest) {
    $d = New-Object Windows.Forms.Form
    $d.Text = 'OptiDrop'
    $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.StartPosition = 'CenterScreen'
    $d.TopMost = $true
    $d.Font = New-Object Drawing.Font('Segoe UI', 9)
    $d.ClientSize = New-Object Drawing.Size 460, 262
    if (Test-Path $IconFile) { $d.Icon = New-Object Drawing.Icon($IconFile, 32, 32) } else { $d.Icon = [Drawing.SystemIcons]::Application }

    $title = New-Object Windows.Forms.Label
    $title.Text = Split-Path $Dir -Leaf
    $title.Font = New-Object Drawing.Font('Segoe UI', 12, [Drawing.FontStyle]::Bold)
    $title.AutoSize = $false; $title.AutoEllipsis = $true
    $title.SetBounds(14, 10, 432, 26)

    $where = New-Object Windows.Forms.Label
    $where.Text = if ($Exe) { Join-Path $Dir $Exe } else { $Dir }
    $where.ForeColor = [Drawing.Color]::DimGray
    $where.AutoSize = $false; $where.AutoEllipsis = $true
    $where.SetBounds(14, 38, 432, 18)

    $status = New-Object Windows.Forms.Label
    $status.AutoSize = $false
    $status.SetBounds(14, 60, 432, 20)
    $info = $null
    if ($Manifest) {
        $info = try { Get-Content -LiteralPath $Manifest.FullName -Raw | ConvertFrom-Json } catch { $null }
        $status.Text = 'Installed' + $(if ($info) {
            $fg = if ($info.fgOutput -eq 'xefg') { "XeSS FG $($info.mfg)" } else { 'FSR FG 2x' }
            "  -  $($info.proxyName), $fg$(if ($info.neuralRendering) { ', Neural Rendering' }), $($info.deployedAt)" })
        $status.ForeColor = [Drawing.Color]::SeaGreen
    } else {
        $status.Text = 'Not installed'
        $status.ForeColor = [Drawing.Color]::Gray
    }

    $grp = New-Object Windows.Forms.GroupBox
    $grp.Text = 'Install options'
    $grp.SetBounds(14, 86, 432, 92)

    $fgLabel = New-Object Windows.Forms.Label
    $fgLabel.Text = 'Frame gen:'
    $fgLabel.SetBounds(12, 26, 72, 20)
    $fgBox = New-Object Windows.Forms.ComboBox
    $fgBox.DropDownStyle = 'DropDownList'
    $fgBox.SetBounds(88, 22, 330, 24)
    foreach ($k in $FgModes.Keys) { [void]$fgBox.Items.Add($FgModes[$k]) }
    $keys = @($FgModes.Keys)
    $sel = [Array]::IndexOf($keys, [string]$script:opts.fg)
    $fgBox.SelectedIndex = [Math]::Max(0, $sel)

    $nrBox = New-Object Windows.Forms.CheckBox
    $nrBox.SetBounds(12, 56, 410, 24)
    $haveModel = Test-Path $NrModel
    if ($haveModel) {
        $nrBox.Text = 'DLSS Neural Rendering (RTX 50, DX12 game with DLSS)'
        $nrBox.Checked = [bool]$script:opts.nr
    } else {
        $nrBox.Text = 'DLSS Neural Rendering - put nvngx_dlssnr.dll in payload\ first'
        $nrBox.Enabled = $false
    }
    $grp.Controls.AddRange(@($fgLabel, $fgBox, $nrBox))

    # DialogResult per button: no click handlers, so no closure/scope surprises.
    $mk = {
        param($text, $result, $x)
        $b = New-Object Windows.Forms.Button
        $b.Text = $text; $b.DialogResult = $result
        $b.SetBounds($x, 190, 100, 30)
        $b
    }
    $bInstall = & $mk $(if ($Manifest) { 'Reinstall' } else { 'Install' }) 'Yes'    14
    $bPreview = & $mk 'Preview'                                             'Retry'  124
    $bRemove  = & $mk 'Remove'                                              'No'     234
    $bCancel  = & $mk 'Cancel'                                              'Cancel' 346
    $bRemove.Enabled = [bool]$Manifest
    $d.AcceptButton = if ($Manifest) { $bRemove } else { $bInstall }
    $d.CancelButton = $bCancel

    $credit = New-Object Windows.Forms.Label
    $credit.Text = 'OptiDrop - built by Floki'
    $credit.ForeColor = [Drawing.Color]::Gray
    $credit.Font = New-Object Drawing.Font('Segoe UI', 8, [Drawing.FontStyle]::Italic)
    $credit.TextAlign = 'MiddleRight'
    $credit.SetBounds(14, 234, 432, 20)

    $d.Controls.AddRange(@($title, $where, $status, $grp, $bInstall, $bPreview, $bRemove, $bCancel, $credit))
    $d.Add_Shown({ $this.AcceptButton.Focus() })
    $r = $d.ShowDialog()
    $mode = $keys[$fgBox.SelectedIndex]
    $nr = $nrBox.Enabled -and $nrBox.Checked
    $d.Dispose()

    $action = switch ($r) { 'Yes' { 'install' } 'Retry' { 'preview' } 'No' { 'remove' } default { $null } }
    if (-not $action) { return $null }
    if ($action -ne 'remove') { $script:opts.fg = $mode; $script:opts.nr = $nr; Save-State }
    [pscustomobject]@{ Action = $action; Mode = $mode; NR = $nr }
}

$script:jobs = New-Object Collections.ArrayList

function Start-Deploy([string]$Dir, [string]$Exe, $Choice, [bool]$Force) {
    $flags = switch ($Choice.Action) { 'preview' { ' -DryRun' } 'remove' { ' -Uninstall' } default { '' } }
    if ($Choice.Action -ne 'remove') {
        $out, $mult = $Choice.Mode -split '-'
        $flags += " -FGOutput $out"
        if ($out -eq 'xefg') { $flags += " -MFG $mult" }
        if ($Choice.NR)  { $flags += ' -NeuralRendering' }
    }
    if ($Exe)   { $flags += ' -Exe ' + (Q $Exe) }
    if ($Force) { $flags += ' -Force' }
    $cmd = '$Host.UI.RawUI.WindowTitle = ' + (Q "OptiDrop $($Choice.Action) - $(Split-Path $Dir -Leaf)") + '; ' +
           '& ' + (Q $Deploy) + ' ' + (Q $Dir) + $flags + '; $c = $LASTEXITCODE; ' +
           'Write-Host; Read-Host ''Press Enter to close''; exit $c'

    $sp = @{
        FilePath     = 'powershell.exe'
        ArgumentList = "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
        PassThru     = $true
    }
    $admin = Test-NeedsAdmin $Dir
    if ($admin) { $sp.Verb = 'RunAs' }
    try { $proc = Start-Process @sp }
    catch { Say "Could not start the deploy console:`n$($_.Exception.Message)" 'Warning'; return }
    [void]$script:jobs.Add([pscustomobject]@{ Proc = $proc; Dir = $Dir; Exe = $Exe; Choice = $Choice; Force = $Force })
}

function Open-Drop([string]$Path) {
    try {
        $exe = $null
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            if ([IO.Path]::GetExtension($Path) -ne '.exe') { Say "Drop a game folder, or the game's .exe.`n`n$Path"; return }
            $exe = [IO.Path]::GetFileName($Path)
            $dir = [IO.Path]::GetDirectoryName($Path)
        } elseif (Test-Path -LiteralPath $Path -PathType Container) {
            $dir = $Path.TrimEnd('\')
        } else { return }

        if ([IO.Path]::GetPathRoot($dir).TrimEnd('\') -eq $dir) { Say "That's a whole drive. Drop the game's own folder." 'Warning'; return }

        $choice = Show-Choice $dir $exe (Find-Manifest $dir)
        if (-not $choice) { return }

        # Neural Rendering on anything older than RTX 50: one explicit, default-No heads-up.
        # Copying the model is harmless by itself - the pass stays off until ticked in the overlay.
        if ($choice.NR -and $choice.Action -eq 'install' -and -not (Test-Rtx50)) {
            $msg = "No RTX 50 series GPU found.`n`n" +
                   "The model will be copied but stays OFF until you tick Enable Neural Rendering in the Insert menu. " +
                   "Turning it on outside RTX 50 has HARD-LOCKED a PC (RTX 3090: black screen, hard reset needed).`n`n" +
                   "Copy the model anyway?"
            $r = [Windows.Forms.MessageBox]::Show($msg, 'OptiDrop - Neural Rendering', 'YesNo', 'Warning', 'Button2')
            if ($r -ne 'Yes') { $choice.NR = $false }
        }
        Start-Deploy $dir $exe $choice $false
    } catch {
        Say "Something went wrong:`n$($_.Exception.Message)" 'Error'
    }
}

# A failed install/preview on an anti-cheat game gets one explicit, default-No offer of -Force.
function Watch-Jobs {
    if ($script:busy) { return }
    $script:busy = $true
    try {
        foreach ($j in @($script:jobs)) {
            $done = try { $j.Proc.HasExited } catch { $true }
            if (-not $done) { continue }
            $script:jobs.Remove($j)
            $code = try { $j.Proc.ExitCode } catch { $null }
            if ($code -ne 1 -or $j.Force -or $j.Choice.Action -eq 'remove') { continue }
            $ac = Test-AntiCheat $j.Dir
            if (-not $ac) { continue }
            $msg = "Anti-cheat files found in $(Split-Path $j.Dir -Leaf):`n  $($ac -join "`n  ")`n`n" +
                   "OptiScaler is an injected proxy DLL. In an online / anti-cheat game that can get the account BANNED.`n`n" +
                   "Only continue if this game is single-player / offline.`n`n$($j.Choice.Action) anyway with -Force?"
            $r = [Windows.Forms.MessageBox]::Show($msg, 'OptiDrop - anti-cheat', 'YesNo', 'Warning', 'Button2')
            if ($r -eq 'Yes') { Start-Deploy $j.Dir $j.Exe $j.Choice $true }
        }
    } finally { $script:busy = $false }
}

# --------------------------------------------------------------------------- state
function Save-State {
    try {
        @{ x = $form.Left; y = $form.Top; topMost = $form.TopMost; fg = $script:opts.fg; nr = $script:opts.nr } |
            ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
    } catch { }
}

$state = $null
if (Test-Path $StateFile) { try { $state = Get-Content $StateFile -Raw | ConvertFrom-Json } catch { } }
# last-used install options, so the dialog opens on what you picked before
$script:opts = @{
    fg = $(if ($state -and $state.fg -and $FgModes.Contains([string]$state.fg)) { [string]$state.fg } else { 'fsrfg-2x' })
    nr = [bool]($state -and $state.nr)
}
$wa  = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$loc = New-Object Drawing.Point ($wa.Right - $Size - 24), ($wa.Bottom - $Size - 24)
if ($state -and $null -ne $state.x) {
    $saved  = New-Object Drawing.Point ([int]$state.x), ([int]$state.y)
    $center = New-Object Drawing.Point ($saved.X + $Size / 2), ($saved.Y + $Size / 2)
    if ([Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.Contains($center) }) { $loc = $saved }
}

# -------------------------------------------------------------------------- widget
$form = New-Object Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar   = $false
$form.StartPosition   = 'Manual'
$form.Location        = $loc
$form.ClientSize      = New-Object Drawing.Size $Size, $Size
$form.TopMost         = if ($state -and $null -ne $state.topMost) { [bool]$state.topMost } else { $true }
$form.AllowDrop       = $true
$form.Opacity         = $RestOpacity
$form.BackColor       = [Drawing.Color]::FromArgb(22, 22, 58)
$form.Text            = 'OptiDrop'
$form.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($form, $true, $null)
$shape = New-Object Drawing.Drawing2D.GraphicsPath
$shape.AddEllipse(0, 0, $Size, $Size)
$form.Region = New-Object Drawing.Region $shape

$script:hot = $false
function Set-Hot([bool]$on) {
    $script:hot = $on
    $form.Opacity = if ($on) { 1.0 } else { $RestOpacity }
    $form.Invalidate()
}
$form.Add_MouseEnter({ $form.Opacity = 1.0 })
$form.Add_MouseLeave({ if (-not $script:hot) { $form.Opacity = $RestOpacity } })
$form.Add_Paint({ Draw-Bubble $_.Graphics $Size $script:hot })

# drag to move
$form.Add_MouseDown({
    if ($_.Button -eq 'Left') {
        $script:dragFrom = [Windows.Forms.Cursor]::Position
        $script:formFrom = $form.Location
        $script:moved    = $false
    }
})
$form.Add_MouseMove({
    if ($_.Button -ne 'Left' -or -not $script:dragFrom) { return }
    $c  = [Windows.Forms.Cursor]::Position
    $dx = $c.X - $script:dragFrom.X; $dy = $c.Y - $script:dragFrom.Y
    if ([Math]::Abs($dx) + [Math]::Abs($dy) -gt 3) { $script:moved = $true }
    if ($script:moved) { $form.Location = New-Object Drawing.Point ($script:formFrom.X + $dx), ($script:formFrom.Y + $dy) }
})
$form.Add_MouseUp({ if ($script:moved) { Save-State }; $script:dragFrom = $null })

function Pick-Folder {
    $fb = New-Object Windows.Forms.FolderBrowserDialog
    $fb.Description = 'Pick the game folder'
    $fb.ShowNewFolderButton = $false
    if ($fb.ShowDialog($form) -eq 'OK') { Open-Drop $fb.SelectedPath }
    $fb.Dispose()
}
$form.Add_MouseDoubleClick({ if ($_.Button -eq 'Left') { Pick-Folder } })

# drop. The dialog is shown from a timer, NOT inside DragDrop: Explorer (the drag source)
# stays frozen until the DragDrop handler returns.
$script:pending = @()
$deferTimer = New-Object Windows.Forms.Timer
$deferTimer.Interval = 60
$deferTimer.Add_Tick({
    $deferTimer.Stop()
    $items = $script:pending; $script:pending = @()
    foreach ($p in $items) { Open-Drop $p }
})
$form.Add_DragEnter({
    if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy'; Set-Hot $true }
    else { $_.Effect = 'None' }
})
$form.Add_DragLeave({ Set-Hot $false })
$form.Add_DragDrop({
    $script:pending = @($_.Data.GetData([Windows.Forms.DataFormats]::FileDrop))
    Set-Hot $false
    $deferTimer.Start()
})

$pollTimer = New-Object Windows.Forms.Timer
$pollTimer.Interval = 1000
$pollTimer.Add_Tick({ Watch-Jobs })
$pollTimer.Start()

$tip = New-Object Windows.Forms.ToolTip
$tip.SetToolTip($form, "OptiDrop - built by Floki`nDrop a game folder (or its .exe) here`nDouble-click to browse, right-click for options")

# right-click menu
$menu = New-Object Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Pick game folder...', $null, { Pick-Folder })
$miTop = New-Object Windows.Forms.ToolStripMenuItem 'Always on top'
$miTop.CheckOnClick = $true
$miTop.Checked = $form.TopMost
$miTop.Add_Click({ $form.TopMost = $this.Checked; Save-State })
[void]$menu.Items.Add($miTop)
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add('Open deploy folder', $null, { Start-Process explorer.exe $PSScriptRoot })
[void]$menu.Items.Add('README', $null, { Start-Process notepad.exe (Join-Path $PSScriptRoot 'README.md') })
[void]$menu.Items.Add('Project page', $null, { Start-Process $ProjectUrl })
[void]$menu.Items.Add('About OptiDrop', $null, {
    Say "OptiDrop - built by Floki`n`nFloating drop target for OptiScaler: FSR / XeSS frame generation (XeSS up to 4x multi-frame) and DLSS Neural Rendering.`n`n$ProjectUrl"
})
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add('Exit', $null, { $form.Close() })
$form.ContextMenuStrip = $menu

$form.Add_FormClosing({ Save-State; $pollTimer.Stop() })

[Windows.Forms.Application]::Run($form)
$mutex.ReleaseMutex()
$mutex.Dispose()
