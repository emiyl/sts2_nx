# collect-assemblies.ps1 -- gather everything ILC needs into one folder.
#
# Two sources, easy to conflate:
#   sts2.dll + its references   your Steam install
#   GodotSharp.dll              the launcher APK, NOT Steam
#
# Steam's GodotSharp.dll is built against the DESKTOP engine. The
# libgodot_android.so on the SD card is the launcher's custom Android build.
# GodotSharp carries the interop surface the engine binds against, so a
# mismatch shows up as missing methods at runtime rather than a clean load
# error. This script overwrites Steam's copy with the launcher's on purpose.
#
# -Out defaults to a path inside the repo so the build script can consume it
# directly.

param(
  # Optional. Left out, the script finds the install itself -- see
  # Find-SteamGameDir below. Three people in a row pasted the example path from
  # the guide instead of their own, which is a sign the argument should not
  # have been mandatory in the first place.
  [string]$SteamDir = "",

  # Either of these works:
  [string]$ApkDir = "",            # unzipped APK; store is found inside
  [string]$AssemblyStore = "",     # direct path to libassembly-store.so

  [string]$Out = ".\aot\assemblies-raw"
)

$ErrorActionPreference = "Stop"
function Say($m)  { Write-Host "`n== $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "   $m" -ForegroundColor Yellow }
function Ok($m)   { Write-Host "   $m" -ForegroundColor Green }

New-Item -ItemType Directory -Force -Path $Out | Out-Null
$OutFull = (Resolve-Path $Out).Path

if ($OutFull -match ' ') {
  Warn "The output path contains a space: $OutFull"
}

# --- 1. locate the assemblies -----------------------------------------------
# Find the install without being told where it is.
#
# Steam records its own location in the registry, and every extra library
# folder in steamapps\libraryfolders.vdf. Between them that covers a second
# drive, a moved library, and a non-default Steam directory -- the three
# reasons a hardcoded "C:\Program Files (x86)\..." is wrong.
function Find-SteamGameDir {
  $roots = @()

  $reg = $null
  foreach ($k in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
    $v = (Get-ItemProperty $k -ErrorAction SilentlyContinue)
    if ($v -and $v.SteamPath)     { $reg = $v.SteamPath }
    elseif ($v -and $v.InstallPath) { $reg = $v.InstallPath }
    if ($reg) { break }
  }
  if ($reg) { $roots += $reg }

  foreach ($r in @($roots)) {
    $vdf = Join-Path $r "steamapps\libraryfolders.vdf"
    if (Test-Path $vdf) {
      Select-String -Path $vdf -Pattern '"path"\s+"(.+?)"' -AllMatches |
        ForEach-Object { $_.Matches } |
        ForEach-Object { $roots += ($_.Groups[1].Value -replace '\\\\', '\') }
    }
  }
  # Last resort for an unregistered install.
  $roots += @("C:\Program Files (x86)\Steam", "C:\Steam", "D:\Steam", "D:\SteamLibrary")

  foreach ($r in ($roots | Select-Object -Unique)) {
    $common = Join-Path $r "steamapps\common"
    if (-not (Test-Path $common)) { continue }
    # Match on the FILE we need, not on a folder name that a rename or a
    # localised title would break.
    $hit = Get-ChildItem $common -Directory -ErrorAction SilentlyContinue |
           ForEach-Object {
             Get-ChildItem $_.FullName -Recurse -Filter "sts2.dll" -ErrorAction SilentlyContinue |
               Select-Object -First 1
           } | Select-Object -First 1
    if ($hit) { return $hit.Directory.FullName }
  }
  return $null
}

if (-not $SteamDir) {
  Say "looking for your Steam install"
  $SteamDir = Find-SteamGameDir
  if (-not $SteamDir) {
    throw @"
could not find Slay the Spire 2 automatically.

Find it yourself: in Steam, right-click the game -> Manage -> Browse local
files. Copy the path from the address bar and pass it in:

    .\scripts\collect-assemblies.ps1 -SteamDir "<that path>" -ApkDir "<your apk folder>"
"@
  }
  Ok "found: $SteamDir"
}

Say "looking for assemblies under $SteamDir"

if (-not (Test-Path $SteamDir)) {
  throw @"
not found: $SteamDir

That path does not exist on this PC. If you copied it from the guide, it was an
example -- replace it with your own, or leave -SteamDir off entirely and the
script will find the install by itself.
"@
}

# Accept either the data_* folder itself or something above it.
$src = $null
if (Test-Path (Join-Path $SteamDir "GodotSharp.dll")) {
  $src = (Resolve-Path $SteamDir).Path
  Ok "using $src"
} else {
  $found = Get-ChildItem -Path $SteamDir -Recurse -Filter "GodotSharp.dll" -ErrorAction SilentlyContinue |
           Select-Object -ExpandProperty DirectoryName -Unique
  if (-not $found) {
    Warn "No GodotSharp.dll anywhere under $SteamDir."
    Warn "The assemblies may be packed inside the .pck for this export."
    exit 1
  }
  foreach ($d in $found) { Write-Host "   found: $d" }
  $src = $found | Select-Object -First 1
  if ($found.Count -gt 1) { Warn "using the first" }
}

# --- 2. copy -----------------------------------------------------------------
Say "copying"
Copy-Item -Path (Join-Path $src "*.dll") -Destination $OutFull -Force
$n = (Get-ChildItem $OutFull -Filter *.dll).Count
Ok "$n assemblies -> $OutFull"

if (Test-Path (Join-Path $OutFull "sts2.dll")) {
  Ok "sts2.dll present"
} else {
  Warn "sts2.dll NOT present. Assemblies found:"
  Get-ChildItem $OutFull -Filter *.dll | Select-Object -First 25 |
    ForEach-Object { Write-Host "     $($_.Name)" }
  Warn "Whichever is the game's own assembly, note its name -- DOTNET_SO_NAME"
  Warn "in source/config.h and the 'sts2' entries in aot/rd.xml reference it."
}

# --- 3. GodotSharp.dll from the launcher -------------------------------------
$store = $AssemblyStore
if ($store -eq "" -and $ApkDir -ne "") {
  $store = Join-Path $ApkDir "lib\arm64-v8a\libassembly-store.so"
}

if ($store -ne "" -and (Test-Path $store)) {
  Say "replacing GodotSharp.dll with the launcher's build"

  $py = $null
  foreach ($c in @("python", "python3", "py")) {
    if (Get-Command $c -ErrorAction SilentlyContinue) { $py = $c; break }
  }
  if (-not $py) { Warn "Python not found on PATH; skipping. Steam's GodotSharp.dll is probably WRONG."; }
  else {
    & $py "tools\extract_assembly_store.py" $store $OutFull "GodotSharp.dll"
    if (Test-Path (Join-Path $OutFull "GodotSharp.dll")) { Ok "replaced" }
  }
} else {
  Warn "No assembly store given (-ApkDir or -AssemblyStore)."
  Warn "GodotSharp.dll is Steam's, which is probably WRONG. See docs/BUILDING_LIBSTS2.md."
}

# --- 4. next ------------------------------------------------------------------
Say "ready"
Write-Host "   Build the payload with: bash scripts/build.sh aot"
