# deploy.ps1 — Deploy and package qub for Windows (x64 MSVC).
# Run from the project root after building in ./build/.
# Requires Qt's windeployqt and Inno Setup (ISCC) on PATH.
param(
    [string]$BuildDir = "build",
    [string]$OutDir   = "dist"
)
$ErrorActionPreference = "Stop"

# Anchored on the project() line: an unanchored \d+\.\d+\.\d+ takes whatever
# three-part number comes first in the file, which need not be the version.
$Version = (Select-String -Path CMakeLists.txt `
    -Pattern 'project\(\s*\w+\s+VERSION\s+(\d+\.\d+\.\d+)' |
    Select-Object -First 1).Matches[0].Groups[1].Value
if (-not $Version) { throw "Could not read the version out of CMakeLists.txt" }

# Qt names its Windows tools with and without the 6 depending on how it was
# installed, and CI may not have them on PATH at all — hence QT_ROOT_DIR.
function Find-QtTool([string[]]$Names) {
    foreach ($n in $Names) {
        $cmd = Get-Command $n -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    if ($env:QT_ROOT_DIR) {
        foreach ($n in $Names) {
            $path = Join-Path $env:QT_ROOT_DIR "bin\$n.exe"
            if (Test-Path $path) { return $path }
        }
    }
    throw "None of these are on PATH or under QT_ROOT_DIR: $($Names -join ', ')"
}

# Get-Command only finds files with a PATHEXT extension, and .dll is not one, so
# a DLL has to be looked up by hand.
function Find-OnPath([string]$File) {
    foreach ($dir in $env:PATH.Split(';')) {
        if (-not $dir) { continue }
        $path = Join-Path $dir $File
        if (Test-Path $path) { return $path }
    }
    return $null
}

$WinDeployQt = Find-QtTool @("windeployqt6", "windeployqt")
$Qmake       = Find-QtTool @("qmake6", "qmake")

$StageDir = "$env:TEMP\qub-stage"
Remove-Item -Recurse -Force $StageDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $StageDir, $OutDir | Out-Null

# ── Copy executable ──────────────────────────────────────────────────────────
# Release\ is where a multi-config generator puts it; Ninja and NMake, which are
# single-config, put it straight in the build directory.
$Exe = @("$BuildDir\qub.exe", "$BuildDir\Release\qub.exe") |
       Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Exe) { throw "qub.exe not found under $BuildDir" }
Copy-Item $Exe "$StageDir\qub.exe"

# ── windeployqt ─────────────────────────────────────────────────────────────
& $WinDeployQt `
    --no-translations `
    --no-system-d3d-compiler `
    --no-opengl-sw `
    --qmldir src\qml `
    "$StageDir\qub.exe"

if ($LASTEXITCODE -ne 0) { throw "windeployqt failed" }

# ── Bundle SQL driver plugins ────────────────────────────────────────────────
$QtPlugins = & $Qmake -query QT_INSTALL_PLUGINS
$DriverDst = "$StageDir\plugins\sqldrivers"
New-Item -ItemType Directory -Force -Path $DriverDst | Out-Null

foreach ($drv in @("qsqlpsql.dll", "qsqlmysql.dll", "qsqlite.dll")) {
    $src = "$QtPlugins\sqldrivers\$drv"
    if (Test-Path $src) { Copy-Item $src $DriverDst }
}

# MariaDB Connector/C runtime (LGPL — allowed to bundle)
foreach ($lib in @("libmariadb.dll", "libmariadb3.dll")) {
    $found = Find-OnPath $lib
    if ($found) { Copy-Item $found $StageDir }
}
# libpq runtime
foreach ($lib in @("libpq.dll", "libssl-3-x64.dll", "libcrypto-3-x64.dll")) {
    $found = Find-OnPath $lib
    if ($found) { Copy-Item $found $StageDir }
}

# ── Compile Inno Setup installer ─────────────────────────────────────────────
$iss = (Get-Content packaging\windows\installer.iss -Raw) `
    -replace "__VERSION__", $Version `
    -replace "__STAGE__",   $StageDir.Replace("\", "\\")
$tmpIss = "$env:TEMP\qub-installer.iss"
Set-Content -Path $tmpIss -Value $iss

& iscc $tmpIss "/O$((Get-Item $OutDir).FullName)"
if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed" }

Write-Host "Installer written to $OutDir"
