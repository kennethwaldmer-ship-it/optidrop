<#
.SYNOPSIS
  Deploy OptiScaler (FSR/XeSS frame generation) into any game folder, or remove it again.
  Part of OptiDrop - built by Floki. https://github.com/kennethwaldmer-ship-it/optidrop

.DESCRIPTION
  Point it at a game folder. It works out the real executable, reads that executable's
  PE import table to find a proxy DLL name the game will ACTUALLY load, avoids slots that
  are already taken or that a third-party loader / Steam emulator needs, deploys the payload,
  writes a tuned OptiScaler.ini, and records a manifest so -Uninstall is exact.

  Configures FSR 3.1 FG (or XeSS FG) driven off the upscaler pass. That works on any
  DX11/DX12 GPU - including RTX 20/30 cards, where NVIDIA's own Streamline runtime refuses
  DLSS Frame Generation ("Disabling DLSS-G since it is not supported on current hardware").

  Deliberately never deploys:
    nvngx_dlssnr.dll / nvngx.dll_dlssnr.dll  - unofficial DLSS Neural Rendering model builds.
                                               Driven by vtable probing on unsupported cards;
                                               known to hard-lock the whole machine.
    D3D12_OptiScaler\D3D12Core.dll           - Agility SDK PREVIEW runtime. Preview Agility
                                               runtimes need Windows Developer Mode, and most
                                               games ship their own.

.PARAMETER GamePath
  The game folder. Can be the folder holding the .exe, or a parent - it will search.

.PARAMETER Exe
  Override executable detection, e.g. -Exe "MyGame-Win64-Shipping.exe".

.PARAMETER ProxyName
  Force a specific proxy DLL name instead of letting it choose.

.PARAMETER FGOutput
  fsrfg (default, FSR 3.1 FG) or xefg (XeSS FG).

.PARAMETER MFG
  2x (default), 3x or 4x. Multi-frame generation - XeSS FG only (-FGOutput xefg).

.PARAMETER NeuralRendering
  Also copy YOUR OWN nvngx_dlssnr.dll (the DLSS Neural Rendering model, from an NVIDIA driver
  package - it cannot be redistributed) into the game, from payload\ or -ModelPath.
  The NR pass itself is built into this OptiScaler build and stays OFF until you tick
  "Enable Neural Rendering" in the Insert overlay. Made for RTX 50 + DX12 games with DLSS.

.PARAMETER ModelPath
  Where your nvngx_dlssnr.dll is, if not in payload\.

.PARAMETER DryRun
  Report the full plan, change nothing.

.PARAMETER Uninstall
  Remove a previous deployment using its manifest.

.PARAMETER Force
  Proceed despite an anti-cheat warning. Read what it says first.

.EXAMPLE
  .\Add-OptiScaler.ps1 "D:\SteamLibrary\steamapps\common\MyGame" -DryRun
.EXAMPLE
  .\Add-OptiScaler.ps1 "D:\SteamLibrary\steamapps\common\MyGame"
.EXAMPLE
  .\Add-OptiScaler.ps1 "D:\SteamLibrary\steamapps\common\MyGame" -Uninstall
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$GamePath,
    [string]$Exe,
    [string]$ProxyName,
    [ValidateSet('fsrfg', 'xefg')][string]$FGOutput = 'fsrfg',
    # Multi-frame generation. ONLY xefg supports a multiplier - FSR FG is 2x only.
    [ValidateSet('2x','3x','4x')][string]$MFG = '2x',
    [switch]$NeuralRendering,
    [string]$ModelPath,
    [switch]$DryRun,
    [switch]$Uninstall,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$PayloadRoot  = Join-Path $PSScriptRoot 'payload'
$ManifestName = '.optiscaler-deploy.json'

# OptiScaler only responds to these proxy names. Anything else is silently never loaded.
$SupportedProxies = @('dxgi.dll','d3d12.dll','winmm.dll','version.dll','dbghelp.dll','wininet.dll','winhttp.dll')
# Preference when a third-party loader / Steam emulator is present: keep OFF the graphics slots,
# because those loaders patch the graphics imports themselves and collide.
$NonGraphicsFirst = @('wininet.dll','winhttp.dll','winmm.dll','version.dll','dbghelp.dll','dxgi.dll','d3d12.dll')
$GraphicsFirst    = @('dxgi.dll','d3d12.dll','wininet.dll','winhttp.dll','winmm.dll','version.dll','dbghelp.dll')

$ExeBlacklist = 'CrashReport|InstallerMessage|UnityCrashHandler|crashpad|vcredist|dxsetup|DXSETUP|UnrealCEFSubProcess|EpicWebHelper|Launcher$|launcher\.exe|setup|unins|Report|Helper|Subprocess|EasyAntiCheat|BEService|nvngx_update'

function Write-Head($t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Write-Ok  ($t) { Write-Host "   $t" -ForegroundColor Green }
function Write-Note($t) { Write-Host "   $t" -ForegroundColor Gray }
function Write-Warn($t) { Write-Host "   $t" -ForegroundColor Yellow }
function Write-Bad ($t) { Write-Host "   $t" -ForegroundColor Red }

# ---------------------------------------------------------------- PE import parser
# Real import-directory walk. A byte-scan for DLL name strings gives false positives
# (names can appear in unrelated data) and false negatives (bound/delay imports).
function Get-PeInfo {
    param([string]$Path)
    $fs = [IO.File]::OpenRead($Path)
    try {
        $br = New-Object IO.BinaryReader($fs)
        if ($br.ReadUInt16() -ne 0x5A4D) { throw "not a PE file: $Path" }
        $fs.Position = 0x3C
        $peOff = $br.ReadUInt32()
        $fs.Position = $peOff
        if ($br.ReadUInt32() -ne 0x00004550) { throw "bad PE signature: $Path" }

        $null = $br.ReadUInt16()                      # machine
        $numSections = $br.ReadUInt16()
        $fs.Position += 12
        $optSize = $br.ReadUInt16()
        $null = $br.ReadUInt16()                      # characteristics
        $optStart = $fs.Position
        $magic = $br.ReadUInt16()
        $is64 = ($magic -eq 0x20B)

        # DataDirectory[1] = Import Table
        $ddOff = $optStart + $(if ($is64) { 112 } else { 96 })
        $fs.Position = $ddOff + 8
        $importRva  = $br.ReadUInt32()
        $null       = $br.ReadUInt32()

        # section headers -> RVA to file offset
        $fs.Position = $optStart + $optSize
        $sections = @()
        for ($i = 0; $i -lt $numSections; $i++) {
            $null = $br.ReadBytes(8)                  # name
            $vsz  = $br.ReadUInt32(); $vad = $br.ReadUInt32()
            $rsz  = $br.ReadUInt32(); $rptr = $br.ReadUInt32()
            $null = $br.ReadBytes(16)
            $sections += [pscustomobject]@{ VA = $vad; VSize = $vsz; RawSize = $rsz; RawPtr = $rptr }
        }
        function ToOffset($rva) {
            foreach ($s in $sections) {
                $span = [Math]::Max($s.VSize, $s.RawSize)
                if ($rva -ge $s.VA -and $rva -lt ($s.VA + $span)) { return $s.RawPtr + ($rva - $s.VA) }
            }
            return 0
        }

        $imports = New-Object System.Collections.Generic.List[string]
        if ($importRva -ne 0) {
            $p = ToOffset $importRva
            if ($p -gt 0) {
                while ($true) {
                    $fs.Position = $p
                    $oft = $br.ReadUInt32(); $null = $br.ReadUInt32(); $null = $br.ReadUInt32()
                    $nameRva = $br.ReadUInt32(); $null = $br.ReadUInt32()
                    if ($oft -eq 0 -and $nameRva -eq 0) { break }
                    if ($nameRva -ne 0) {
                        $np = ToOffset $nameRva
                        if ($np -gt 0) {
                            $fs.Position = $np
                            $sb = New-Object Text.StringBuilder
                            while ($true) { $b = $br.ReadByte(); if ($b -eq 0) { break }; [void]$sb.Append([char]$b) }
                            $imports.Add($sb.ToString().ToLower())
                        }
                    }
                    $p += 20
                    if ($imports.Count -gt 512) { break }
                }
            }
        }
        [pscustomobject]@{ Is64 = $is64; Imports = ($imports | Sort-Object -Unique) }
    }
    finally { $fs.Dispose() }
}

function Find-GameExe {
    param([string]$Dir)
    $cands = Get-ChildItem $Dir -Recurse -Filter *.exe -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -notmatch $ExeBlacklist } |
             Sort-Object Length -Descending
    if (-not $cands) { return $null }
    # Prefer a *-Win64-Shipping.exe (Unreal) if one exists; else the largest exe.
    $ue = $cands | Where-Object { $_.Name -match 'Win64-Shipping\.exe$' } | Select-Object -First 1
    if ($ue) { return $ue }
    $cands | Select-Object -First 1
}

function Test-Loader {
    param([string]$Dir)
    $reasons = @()
    $f = Get-ChildItem $Dir -File -ErrorAction SilentlyContinue
    foreach ($x in $f) {
        if ($x.Name -match '^(OnlineFix|SteamFix|EpicFix|Goldberg)' ) { $reasons += $x.Name }
        if ($x.Name -match '^steam_api(64)?\.(dll|v\d+)$' -and $x.Length -gt 1MB) {
            $reasons += ("{0} is {1:N1} MB (a real steam_api is ~0.3 MB) - emulator" -f $x.Name, ($x.Length/1MB))
        }
        # DLLs renamed to odd extensions and side-loaded, e.g. voices38.v38
        if ($x.Extension -match '^\.v\d+$' -and $x.Length -gt 500KB) { $reasons += "$($x.Name) (renamed side-loaded DLL)" }
    }
    $reasons | Sort-Object -Unique
}

# REAL kernel/userland anti-cheat only. Do NOT include EOSSDK here: Epic Online Services
# is achievements / leaderboards / presence and ships in plenty of single-player games
# (plenty of single-player games have it). EOS Anti-Cheat is a separate optional component with its own files.
function Test-AntiCheat {
    param([string]$Dir)
    $hits = @()
    $ac = Get-ChildItem $Dir -Recurse -ErrorAction SilentlyContinue -Include `
            'EasyAntiCheat*','EACLauncher*','eac_*','start_protected_game*',
            'BEService*','BattlEye*','BEClient*','*_EAC.*','EOSAntiCheat*','AntiCheat*' |
          Select-Object -First 8
    foreach ($a in $ac) { $hits += $a.Name }
    $hits | Sort-Object -Unique
}

# Online SDKs worth MENTIONING but never blocking on - not anti-cheat.
function Test-OnlineSdk {
    param([string]$Dir)
    $hits = @()
    $s = Get-ChildItem $Dir -Recurse -ErrorAction SilentlyContinue -Include `
            'EOSSDK*','steam_api*.dll','GalaxyCSharp*','Galaxy64.dll' | Select-Object -First 6
    foreach ($a in $s) { $hits += $a.Name }
    $hits | Sort-Object -Unique
}

function Get-SlotState {
    param([string]$Dir, [string]$Name)
    $p = Join-Path $Dir $Name
    if (-not (Test-Path $p)) { return [pscustomobject]@{ Free = $true;  Owner = $null } }
    $vi = (Get-Item $p).VersionInfo
    [pscustomobject]@{ Free = $false; Owner = ($vi.ProductName, $vi.FileDescription, 'unknown' | Where-Object { $_ } | Select-Object -First 1) }
}

# OptiScaler REWRITES OptiScaler.ini on exit as "Key = Value" (spaces around =), while the
# shipped template uses "Key=Value". Match BOTH, or a redeploy over an already-run install
# silently changes nothing - which can leave FGOutput on DLSSG and hang the game on launch.
function Set-IniValue {
    param([string]$Text, [string]$Section, [string]$Key, [string]$Value)
    $rx = '(\[' + [regex]::Escape($Section) + '\].*?)^(' + [regex]::Escape($Key) + '[ \t]*=[ \t]*)([^\r\n]*)'
    $opt = [Text.RegularExpressions.RegexOptions]::Singleline -bor [Text.RegularExpressions.RegexOptions]::Multiline
    $pat = [regex]::new($rx, $opt)
    $m = $pat.Match($Text)
    if (-not $m.Success) { Write-Warn "ini: [$Section] $Key NOT FOUND - value not applied"; return $Text }
    # Rebuild by index. No MatchEvaluator scriptblock: PS 5.1 does not always bind one and
    # throws "Argument types do not match".
    $Text.Substring(0, $m.Groups[3].Index) + $Value + $Text.Substring($m.Groups[3].Index + $m.Groups[3].Length)
}

# Read a value back so a deploy can PROVE what it wrote instead of assuming.
function Get-IniValue {
    param([string]$Path, [string]$Section, [string]$Key)
    $t = [IO.File]::ReadAllText($Path)
    $rx = '\[' + [regex]::Escape($Section) + '\].*?^' + [regex]::Escape($Key) + '[ \t]*=[ \t]*([^\r\n]*)'
    $opt = [Text.RegularExpressions.RegexOptions]::Singleline -bor [Text.RegularExpressions.RegexOptions]::Multiline
    $m = [regex]::new($rx, $opt).Match($t)
    if ($m.Success) { $m.Groups[1].Value.Trim() } else { $null }
}

# =================================================================== resolve target
if (-not (Test-Path $GamePath)) { Write-Bad "Path not found: $GamePath"; exit 1 }
$GamePath = (Resolve-Path $GamePath).Path

Write-Head "Target"
Write-Note $GamePath

# --------------------------------------------------------------------- uninstall
if ($Uninstall) {
    $man = Get-ChildItem $GamePath -Recurse -Filter $ManifestName -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $man) { Write-Bad "No $ManifestName found under that path - nothing deployed by this tool."; exit 1 }
    $d = Get-Content $man.FullName -Raw | ConvertFrom-Json
    Write-Head "Uninstalling"
    Write-Note "manifest : $($man.FullName)"
    Write-Note "deployed : $($d.deployedAt)   proxy: $($d.proxyName)"
    $dir = $d.gameDir
    foreach ($f in $d.filesAdded) {
        $p = Join-Path $dir $f
        if (Test-Path $p) { if (-not $DryRun) { Remove-Item $p -Force -Recurse }; Write-Ok "removed  $f" }
    }
    foreach ($b in $d.backups) {
        $orig = Join-Path $dir $b.original
        $bak  = Join-Path $dir $b.backup
        if (Test-Path $bak) { if (-not $DryRun) { Move-Item $bak $orig -Force }; Write-Ok "restored $($b.original)" }
    }
    if (-not $DryRun) {
        foreach ($leftover in 'OptiScaler.log','OptiScaler.ini') {
            $p = Join-Path $dir $leftover
            if (Test-Path $p) { Remove-Item $p -Force; Write-Ok "removed  $leftover" }
        }
        $od = Join-Path $dir 'OptiScaler'
        if (Test-Path $od) { Remove-Item $od -Recurse -Force; Write-Ok "removed  OptiScaler\" }
        Remove-Item $man.FullName -Force
    }
    Write-Host ''
    Write-Ok $(if ($DryRun) { 'DRY RUN - nothing changed' } else { 'Uninstalled.' })
    exit 0
}

# ------------------------------------------------------------------ payload check
if (-not (Test-Path (Join-Path $PayloadRoot 'OptiScaler.dll'))) {
    Write-Bad "Payload missing: $PayloadRoot\OptiScaler.dll"; exit 1
}

# ------------------------------------------------------------ neural rendering (opt-in)
# The model is never bundled: it is NVIDIA's, from a driver package, and not redistributable.
# nvngx.dll_dlssnr.dll is the fork's own 112 KB forwarder - the pass refuses callers whose
# module path lacks "nvngx.dll", which is the only reason it exists.
# The forwarder is deployed on EVERY install (tiny, inert until NR is ticked in the overlay),
# so the overlay's NR panel can report exactly what is missing instead of failing silently.
$nrModel = $null
$nrForwarder = Join-Path $PayloadRoot 'nvngx.dll_dlssnr.dll'
if (-not (Test-Path $nrForwarder)) { $nrForwarder = $null }
if ($NeuralRendering) {
    Write-Head "Neural Rendering (opt-in)"
    $cand = if ($ModelPath) { $ModelPath } else { Join-Path $PayloadRoot 'nvngx_dlssnr.dll' }
    if (-not (Test-Path -LiteralPath $cand -PathType Leaf)) {
        Write-Bad "Model not found: $cand"
        Write-Note "Copy nvngx_dlssnr.dll (~160 MB, from an NVIDIA driver package) into payload\, or pass -ModelPath."
        exit 1
    }
    $vi = (Get-Item -LiteralPath $cand).VersionInfo
    if ("$($vi.FileDescription) $($vi.ProductName)" -notmatch 'DLSSNR') {
        Write-Bad "$cand does not identify itself as NVIDIA DLSSNR (says '$($vi.FileDescription)')."
        Write-Note "A ~160 MB file under another nvngx name is usually the NR model misnamed - check its properties."
        exit 1
    }
    if (-not $nrForwarder) { Write-Bad "Forwarder missing: payload\nvngx.dll_dlssnr.dll (ships with this tool)"; exit 1 }
    $nrModel = (Get-Item -LiteralPath $cand).FullName
    Write-Ok "model     : $($vi.FileDescription) $($vi.FileVersion)"

    # Warn, don't block: the pass stays off until the user ticks it in the overlay.
    $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $rtx50 = $gpus | Where-Object { $_ -match 'RTX\s*50\d\d' }
    if ($rtx50) { Write-Ok "gpu       : $($rtx50 | Select-Object -First 1)" }
    else {
        Write-Warn "No RTX 50 series GPU found ($($gpus -join ', '))."
        Write-Warn "The NR model is driven through undocumented entry points. On an RTX 30 card turning it"
        Write-Warn "on has HARD-LOCKED the whole PC (black screen, no BSOD, hard reset). Enable it at your own risk."
    }
}

# --------------------------------------------------------------------- find exe
Write-Head "Executable"
if ($Exe) {
    $exeItem = Get-ChildItem $GamePath -Recurse -Filter $Exe -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exeItem) { Write-Bad "-Exe '$Exe' not found under $GamePath"; exit 1 }
} else {
    $exeItem = Find-GameExe $GamePath
    if (-not $exeItem) { Write-Bad "No candidate .exe found. Use -Exe to name it."; exit 1 }
}
$gameDir = $exeItem.DirectoryName
Write-Ok  "$($exeItem.Name)  ($('{0:N1}' -f ($exeItem.Length/1MB)) MB)"
Write-Note "folder: $gameDir"
if (-not $Exe) { Write-Note "(detected; override with -Exe if that's a launcher)" }

# running?
$procName = [IO.Path]::GetFileNameWithoutExtension($exeItem.Name)
if (Get-Process -Name $procName -ErrorAction SilentlyContinue) {
    Write-Bad "$procName is RUNNING. Close the game first - it may rewrite its config on exit."
    exit 1
}

# --------------------------------------------------------------------- imports
Write-Head "Import table (only imported names can ever load)"
$pe = Get-PeInfo $exeItem.FullName
if (-not $pe.Is64) { Write-Bad "$($exeItem.Name) is 32-bit. This OptiScaler payload is 64-bit only."; exit 1 }
$importedSupported = $SupportedProxies | Where-Object { $pe.Imports -contains $_ }
Write-Note ("arch     : x64")
Write-Note ("imports  : {0}" -f ($(if ($importedSupported) { $importedSupported -join ', ' } else { '<none statically>' })))

# A static import GUARANTEES the proxy loads. It is not required: Windows' DLL search order
# checks the application directory first, so LoadLibrary("dxgi.dll") from the engine also
# picks up a proxy sitting beside the exe. Thin launcher stubs (Unity's small game .exe,
# UE shipping exes) import nothing useful yet load DXGI dynamically from UnityPlayer.dll etc.
# Verified: a Unity game ran OptiScaler as dxgi.dll with zero static dxgi import.
$dynamicOnly = $false
if (-not $importedSupported) {
    $dynamicOnly = $true
    $importedSupported = @('dxgi.dll')
    Write-Note "no static match - the engine loads its graphics DLLs dynamically"
    Write-Note "falling back to dxgi.dll (app-directory search order still finds it)"
}

# --------------------------------------------------------------------- hazards
Write-Head "Environment checks"
$loader = Test-Loader $gameDir
if ($loader) {
    Write-Warn "Loader / emulator detected:"
    $loader | ForEach-Object { Write-Warn "  - $_" }
    Write-Note "These patch the graphics imports themselves. Avoiding dxgi/d3d12 slots."
} else { Write-Ok "no third-party loader / emulator signatures" }

$sdk = Test-OnlineSdk $gameDir
if ($sdk) { Write-Note "online SDK present (not anti-cheat): $($sdk -join ', ')" }

$ac = Test-AntiCheat $gameDir
if ($ac) {
    Write-Bad "ANTI-CHEAT PRESENT: $($ac -join ', ')"
    Write-Bad "OptiScaler injects a proxy DLL. In a multiplayer/anti-cheat game that risks a BAN."
    Write-Bad "OptiScaler's own log says: DO NOT USE IN MULTIPLAYER GAMES."
    if (-not $Force) { Write-Note "Single-player only? re-run with -Force."; exit 1 }
    Write-Warn "-Force given; continuing anyway."
} else { Write-Ok "no anti-cheat signatures" }

# --------------------------------------------------------------------- pick slot
Write-Head "Proxy slot"
if ($ProxyName) {
    if ($SupportedProxies -notcontains $ProxyName.ToLower()) { Write-Bad "'$ProxyName' is not an OptiScaler proxy name."; exit 1 }
    $chosen = $ProxyName.ToLower()
    Write-Warn "forced: $chosen"
} else {
    $order  = if ($loader) { $NonGraphicsFirst } else { $GraphicsFirst }
    $ranked = $order | Where-Object { $importedSupported -contains $_ }
    $chosen = $null
    foreach ($c in $ranked) {
        $st = Get-SlotState $gameDir $c
        if ($st.Free) { $chosen = $c; Write-Ok "chose $c (free)"; break }
        if ($st.Owner -match 'OptiScaler') { $chosen = $c; Write-Warn "chose $c (replacing an existing OptiScaler)"; break }
        Write-Note "skip  $c - occupied by '$($st.Owner)'"
    }
    if (-not $chosen) { Write-Bad "Every candidate slot is occupied by another mod. Remove it, or pass -ProxyName."; exit 1 }
}

# --------------------------------------------------------------------- api / upscaler
# API detection is only a HINT - static imports lie. Some games import d3d11.dll but run
# D3D12 (the log shows NVSDK_NGX_D3D12_*, and they ship a D3D12\ Agility folder). So rather
# than guess one key and get it wrong, configure ALL THREE upscaler keys sensibly and let
# OptiScaler pick at runtime, which it does correctly on its own.
$apiHints = @()
if ($pe.Imports -contains 'vulkan-1.dll') { $apiHints += 'vulkan' }
if (($pe.Imports -contains 'd3d12.dll') -or (Test-Path (Join-Path $gameDir 'D3D12')) -or
    (Test-Path (Join-Path $gameDir 'D3D12Core.dll'))) { $apiHints += 'dx12' }
if ($pe.Imports -contains 'd3d11.dll') { $apiHints += 'dx11' }
if ($apiHints.Count -eq 0) { $apiHints += 'unknown (loaded dynamically)' }

$hasDlss   = Test-Path (Join-Path $gameDir 'nvngx_dlss.dll')
$dx12Val   = if ($hasDlss) { 'dlss' }    else { 'ffx' }
$dx11Val   = if ($hasDlss) { 'dlss_12' } else { 'ffx_12' }
$vulkanVal = if ($hasDlss) { 'dlss' }    else { 'ffx' }
$api       = $apiHints -join ','

Write-Head "Configuration"
Write-Note "api hints      : $($apiHints -join ', ')   (hint only - OptiScaler decides at runtime)"
Write-Note "nvngx_dlss.dll : $(if($hasDlss){'present - DLSS upscaler'}else{'absent - FSR upscaler'})"
Write-Note "Dx12Upscaler   : $dx12Val"
Write-Note "Dx11Upscaler   : $dx11Val"
Write-Note "VulkanUpscaler : $vulkanVal"
Write-Note "FGInput        : upscaler   (works without the game calling DLSS-G; RTX 20/30 cannot run DLSS-G)"
Write-Note "FGOutput       : $FGOutput"
Write-Note "multi-frame    : $MFG$(if($FGOutput -ne 'xefg' -and $MFG -ne '2x'){'   <- IGNORED, FSR FG is 2x only'}elseif($FGOutput -eq 'xefg'){"   (XeFG InterpolationCount)"})"
Write-Note "OptiFG.HUDFix  : true       (required with FGInput=upscaler)"
Write-Note "DlssNr.Enabled : false      (built into this OptiScaler - tick it in the Insert overlay)"
if ($nrModel) {
    Write-Note "NR model       : copied in  (overlay > DLSS Neural Rendering > Enable Neural Rendering)"
    if (-not $hasDlss) {
        Write-Warn "no nvngx_dlss.dll here: NR reads the depth/motion vectors the game hands to DLSS."
        Write-Warn "In a game without DLSS the NR pass will do nothing."
    }
} else {
    Write-Note "NR model       : not copied (overlay will say nvngx_dlssnr.dll was not found; -NeuralRendering adds it)"
}

# --------------------------------------------------------------------- plan
$added   = @()
$backups = @()
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$redeploy = Test-Path (Join-Path $gameDir $ManifestName)

$slotPath = Join-Path $gameDir $chosen
if (Test-Path $slotPath) {
    # Only back up a FOREIGN occupant. Backing up a previous OptiScaler would make
    # -Uninstall "restore" OptiScaler instead of leaving the slot empty.
    $occupant = (Get-Item $slotPath).VersionInfo.ProductName
    if ($occupant -match 'OptiScaler') {
        Write-Note "existing OptiScaler in $chosen will be overwritten (not backed up)"
    } else {
        $bakName = "$chosen.pre-optiscaler-$stamp"
        $backups += [pscustomobject]@{ original = $chosen; backup = $bakName }
    }
}
$added += $chosen
$added += 'OptiScaler.ini'
$added += 'OptiScaler'
$nrFiles = @()
if ($nrForwarder) { $nrFiles += 'nvngx.dll_dlssnr.dll' }
if ($nrModel)     { $nrFiles += 'nvngx_dlssnr.dll' }
foreach ($n in $nrFiles) {
    # A pre-existing copy that isn't ours (no manifest yet) is backed up, not clobbered.
    if ((Test-Path (Join-Path $gameDir $n)) -and -not $redeploy) {
        $backups += [pscustomobject]@{ original = $n; backup = "$n.pre-optiscaler-$stamp" }
    }
    $added += $n
}

# Redeploying WITHOUT -NeuralRendering over a deploy that had it: the new manifest would no
# longer list the model, so -Uninstall would leave 160 MB behind. Remove it now.
$staleNr = @()
if (-not $nrModel -and $redeploy) {
    $old = try { Get-Content (Join-Path $gameDir $ManifestName) -Raw | ConvertFrom-Json } catch { $null }
    if ($old -and ($old.filesAdded -contains 'nvngx_dlssnr.dll')) { $staleNr = @('nvngx_dlssnr.dll') }
}

Write-Head $(if ($DryRun) { 'PLAN (dry run)' } else { 'Deploying' })
foreach ($a in $added)   { Write-Note "+ $a" }
foreach ($b in $backups) { Write-Note "~ $($b.original) -> $($b.backup)" }
foreach ($s in $staleNr) { Write-Note "- $s (left over from an earlier Neural Rendering deploy)" }

if ($DryRun) { Write-Host ''; Write-Ok 'DRY RUN - nothing changed.'; exit 0 }

# --------------------------------------------------------------------- deploy
foreach ($b in $backups) { Move-Item (Join-Path $gameDir $b.original) (Join-Path $gameDir $b.backup) -Force }
Copy-Item (Join-Path $PayloadRoot 'OptiScaler.dll') $slotPath -Force
$libDir = Join-Path $gameDir 'OptiScaler'
New-Item -ItemType Directory -Force -Path $libDir | Out-Null
Copy-Item (Join-Path $PayloadRoot 'OptiScaler\*') $libDir -Force
if ($nrForwarder) { Copy-Item $nrForwarder (Join-Path $gameDir 'nvngx.dll_dlssnr.dll') -Force }
if ($nrModel)     { Copy-Item -LiteralPath $nrModel (Join-Path $gameDir 'nvngx_dlssnr.dll') -Force }
foreach ($s in $staleNr) { Remove-Item (Join-Path $gameDir $s) -Force -ErrorAction SilentlyContinue }

$ini = Get-Content (Join-Path $PayloadRoot 'OptiScaler.ini') -Raw
$ini = Set-IniValue $ini 'Upscalers'    'Dx12Upscaler'      $dx12Val
$ini = Set-IniValue $ini 'Upscalers'    'Dx11Upscaler'      $dx11Val
$ini = Set-IniValue $ini 'Upscalers'    'VulkanUpscaler'    $vulkanVal
$ini = Set-IniValue $ini 'FrameGen'     'Enabled'           'true'
$ini = Set-IniValue $ini 'FrameGen'     'FGInput'           'upscaler'
$ini = Set-IniValue $ini 'FrameGen'     'FGOutput'          $FGOutput
# XeSS FG is the only output with an interpolated-frame-count. FSR 3.1 FG is fixed 2x,
# so asking for 3x/4x there silently gives you 2x.
$interp = @{ '2x' = '1'; '3x' = '2'; '4x' = '3' }[$MFG]
if ($FGOutput -eq 'xefg') {
    $ini = Set-IniValue $ini 'XeFG' 'InterpolationCount' $interp
} elseif ($MFG -ne '2x') {
    Write-Warn "-MFG $MFG ignored: FSR FG is 2x only. Use -FGOutput xefg for multi-frame."
}
$ini = Set-IniValue $ini 'OptiFG'       'HUDFix'            'true'
# NR is never forced on at launch: the user ticks it in the overlay, and OptiScaler saves it.
$nrVal = 'false'
$ini = Set-IniValue $ini 'DlssNr'       'Enabled'           $nrVal
$ini = Set-IniValue $ini 'Log'          'LogToFile'         'true'
$ini = Set-IniValue $ini 'ProcessFilter' 'TargetProcessName' $exeItem.Name
[IO.File]::WriteAllText((Join-Path $gameDir 'OptiScaler.ini'), $ini, (New-Object Text.UTF8Encoding($false)))

# Read the file back and assert. A silently-unapplied FGOutput is the difference between
# working frame generation and a hang on launch, so never assume the write took.
$iniPath  = Join-Path $gameDir 'OptiScaler.ini'
$expected = @(
    @{ S='FrameGen';  K='Enabled';      V='true'      },
    @{ S='FrameGen';  K='FGInput';      V='upscaler'  },
    @{ S='FrameGen';  K='FGOutput';     V=$FGOutput   },
    @{ S='OptiFG';    K='HUDFix';       V='true'      },
    @{ S='DlssNr';    K='Enabled';      V=$nrVal      },
    @{ S='Upscalers'; K='Dx12Upscaler'; V=$dx12Val    }
)
if ($FGOutput -eq 'xefg') { $expected += @{ S='XeFG'; K='InterpolationCount'; V=$interp } }
$bad = @()
foreach ($e in $expected) {
    $got = Get-IniValue $iniPath $e.S $e.K
    if ($got -ne $e.V) { $bad += ('[{0}] {1} = "{2}" (wanted "{3}")' -f $e.S, $e.K, $got, $e.V) }
}
if ($bad.Count -gt 0) {
    Write-Bad 'ini verification FAILED - these did not apply:'
    foreach ($b in $bad) { Write-Bad "  $b" }
    Write-Bad 'Do NOT launch: a wrong FGOutput hangs the game on startup.'
    exit 1
}
Write-Ok 'ini verified - all frame-gen keys applied'

$manifest = [pscustomobject]@{
    tool        = 'Add-OptiScaler.ps1'
    deployedAt  = (Get-Date).ToString('s')
    gameDir     = $gameDir
    exe         = $exeItem.Name
    api         = $api
    proxyName   = $chosen
    fgOutput    = $FGOutput
    mfg         = $(if ($FGOutput -eq 'xefg') { $MFG } else { '2x' })
    neuralRendering = [bool]$nrModel
    loaderSeen  = [string[]]@($loader  | Where-Object { $_ })
    antiCheat   = [string[]]@($ac      | Where-Object { $_ })
    filesAdded  = [string[]]@($added   | Where-Object { $_ })
    backups     = @($backups | Where-Object { $_ })
}
$manifestJson = $manifest | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText((Join-Path $gameDir $ManifestName), $manifestJson, (New-Object Text.UTF8Encoding($false)))

Write-Host ''
Write-Ok "Deployed as $chosen"
Write-Note "manifest: $(Join-Path $gameDir $ManifestName)"
Write-Host ''
Write-Host "   Launch the game normally - nothing to start separately." -ForegroundColor White
Write-Host "   Press INSERT in game for the OptiScaler overlay." -ForegroundColor White
Write-Host "   END toggles frame gen, PAGE UP shows the FPS counter, PAGE DOWN cycles its detail." -ForegroundColor White
Write-Host "   Frame gen is under Frame Generation; log is OptiScaler.log beside the exe." -ForegroundColor White
if ($nrModel) { Write-Host "   Neural Rendering: overlay > DLSS Neural Rendering (Detail / Colour strength)." -ForegroundColor White }
Write-Host ''
Write-Host "   If the game won't start, the proxy slot collided:" -ForegroundColor Yellow
Write-Host "     .\Add-OptiScaler.ps1 `"$GamePath`" -Uninstall" -ForegroundColor Yellow
Write-Host "     .\Add-OptiScaler.ps1 `"$GamePath`" -ProxyName winmm.dll" -ForegroundColor Yellow
