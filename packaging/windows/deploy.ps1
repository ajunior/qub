# deploy.ps1 — Deploy and package qub for Windows (x64 MSVC).
# Run from the project root after building in ./build/.
# Requires Qt's windeployqt and Inno Setup (ISCC) on PATH.
param(
    [string]$BuildDir = "build",
    [string]$OutDir   = "dist",
    # Local builds on a machine without PostgreSQL installed. A release build
    # must never set this: it is what turns a missing client library from a
    # failed build into an installer that cannot connect to anything.
    [switch]$SkipClientLibs
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

# ── DLLs built alongside qub ─────────────────────────────────────────────────
# qtkeychain comes in through FetchContent, so qt6keychain.dll is produced in the
# build tree rather than shipped next to Qt. The installer needs it, so stage it
# with everything else the build produced.
Get-ChildItem -Path $BuildDir -Recurse -Filter *.dll |
    Where-Object { $_.FullName -notmatch '[\\/]CMakeFiles[\\/]' } |
    ForEach-Object {
        Write-Host "Staging $($_.Name)"
        Copy-Item $_.FullName $StageDir -Force
    }

# ── windeployqt ─────────────────────────────────────────────────────────────
# A dependency named qt6keychain.dll reads to windeployqt as one of Qt's own
# libraries, so it goes looking in Qt's bin directory and fails there — staging
# the DLL next to the executable does not help, and there is no flag to add a
# search path. So lend Qt's bin directory whatever it is missing for the length
# of the call, and take it back out afterwards whatever happens.
$QtBin    = Split-Path $WinDeployQt
$Borrowed = @()
foreach ($dll in Get-ChildItem $StageDir -Filter *.dll) {
    $target = Join-Path $QtBin $dll.Name
    if (-not (Test-Path $target)) {
        Copy-Item $dll.FullName $target
        $Borrowed += $target
    }
}

try {
    & $WinDeployQt `
        --no-translations `
        --no-system-d3d-compiler `
        --no-opengl-sw `
        --qmldir src\qml `
        "$StageDir\qub.exe"

    if ($LASTEXITCODE -ne 0) { throw "windeployqt failed" }
}
finally {
    foreach ($lent in $Borrowed) {
        Remove-Item $lent -Force -ErrorAction SilentlyContinue
    }
}

# ── SQL client libraries ─────────────────────────────────────────────────────
# windeployqt already staged Qt's SQL driver plugins into $StageDir\sqldrivers,
# which is where Qt looks for them. It does not, and cannot, bring the vendor
# client library each one dlopens: qsqlpsql.dll is useless without libpq.dll
# next to the executable, and the failure is a bare "Driver not loaded" at
# connect time. So the plugins that shipped are read back off disk and their
# client libraries chased down here.
#
# What this block used to do, and why it changed. It copied three plugins into
# $StageDir\plugins\sqldrivers, a directory Qt never searches — windeployqt had
# already put the real ones in $StageDir\sqldrivers, so those two were dead
# weight in the installer. And it looked for client libraries on PATH with
# `if ($found)`, taking silence for absence: libpq.dll happened to be on the
# runner's PATH and shipped, but libssl-3-x64.dll and libcrypto-3-x64.dll are
# in the same directory and were only found if that directory was on PATH too.
# A libpq that cannot load its OpenSSL fails exactly like no libpq at all.
#
# So: client libraries are resolved from where PostgreSQL actually is rather
# than from PATH alone, the whole dependency closure comes along, and a missing
# one is fatal instead of silent.

$DriverDir = "$StageDir\sqldrivers"
if (-not (Test-Path $DriverDir)) {
    throw "windeployqt staged no sqldrivers directory — qub cannot open a database"
}
$Drivers = (Get-ChildItem $DriverDir -Filter *.dll).Name
Write-Host "SQL drivers deployed: $($Drivers -join ', ')"

# Resolve a DLL's import table with dumpbin, which the MSVC environment this
# builds under already provides. Returns $null when dumpbin is unavailable, so
# the caller can fall back rather than conclude the DLL has no dependencies.
function Get-DllImports([string]$Dll) {
    if (-not (Get-Command dumpbin -ErrorAction SilentlyContinue)) { return $null }
    $out = & dumpbin /nologo /dependents $Dll 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    # Inside the dependents block each line is an indented bare filename; every
    # other line in the report is prose or a section name, neither of which
    # ends in .dll.
    return @($out | ForEach-Object { $_.Trim() } |
             Where-Object { $_ -match '^[\w.+-]+\.dll$' })
}

# An API set contract — api-ms-win-*, ext-ms-* — is not a file. The loader
# resolves the name through the OS API-set schema to whichever system DLL
# actually implements it, so nothing is on disk to find and nothing has to be
# shipped. dumpbin lists them like any other import, and 0.44.9-rc.8 failed its
# Windows package because the verifier below looked for them in System32, did
# not find them, and declared SQLite, PostgreSQL and ODBC broken over the
# Universal CRT.
function Test-IsApiSet([string]$Name) {
    return $Name -match '^(api-ms-win-|ext-ms-)'
}

# The imports that nothing in $SearchDirs provides. A function rather
# than a few lines inside the verification loop so that tests/tst_deploy.ps1 can
# exercise it: rc.8 failed inside exactly this logic, in the one part of the
# packager the old test could not reach.
function Get-UnresolvedImports([string[]]$Imports, [string[]]$SearchDirs) {
    return @($Imports | Where-Object {
        $name = $_
        -not (Test-IsApiSet $name) -and
        -not ($SearchDirs | Where-Object { Test-Path (Join-Path $_ $name) })
    })
}

# Copy $Name out of $SrcDir together with everything it transitively imports
# that also lives in $SrcDir. A name that is not there is a Windows system DLL
# and comes from the target machine, so it is skipped rather than chased.
function Copy-RuntimeClosure([string]$Name, [string]$SrcDir, [string]$DstDir) {
    $copied  = @()
    $seen    = @{}
    $pending = New-Object System.Collections.Queue
    $pending.Enqueue($Name)

    while ($pending.Count -gt 0) {
        $n = $pending.Dequeue()
        if ($seen.ContainsKey($n)) { continue }
        $seen[$n] = $true

        $src = Join-Path $SrcDir $n
        if (-not (Test-Path $src)) { continue }

        Copy-Item $src $DstDir -Force
        $copied += $n

        $imports = Get-DllImports $src
        if ($null -eq $imports) { return $null }
        foreach ($i in $imports) { $pending.Enqueue($i) }
    }
    return $copied
}

# ── PostgreSQL ───────────────────────────────────────────────────────────────
if ($SkipClientLibs) {
    Write-Warning "-SkipClientLibs: shipping SQL driver plugins with no client libraries"
}
elseif ($Drivers -contains "qsqlpsql.dll") {
    # PGBIN is set by the GitHub runner image; the glob covers a normal EDB
    # install, and PATH is the last resort rather than the only one.
    $LibpqDir = $null
    $cands = @()
    if ($env:PGBIN)  { $cands += $env:PGBIN }
    if ($env:PGROOT) { $cands += (Join-Path $env:PGROOT "bin") }
    $cands += @(Get-ChildItem "C:\Program Files\PostgreSQL" -Directory -ErrorAction SilentlyContinue |
                Sort-Object { if ($_.Name -match '^\d+') { [int]$Matches[0] } else { 0 } } -Descending |
                ForEach-Object { Join-Path $_.FullName "bin" })
    $onPath = Find-OnPath "libpq.dll"
    if ($onPath) { $cands += (Split-Path $onPath) }

    foreach ($c in $cands) {
        if ($c -and (Test-Path (Join-Path $c "libpq.dll"))) { $LibpqDir = $c; break }
    }
    if (-not $LibpqDir) {
        throw "qsqlpsql.dll was deployed but libpq.dll was not found. Looked in " +
              "PGBIN, PGROOT\bin, C:\Program Files\PostgreSQL\*\bin and PATH. " +
              "Install PostgreSQL or pass -SkipClientLibs to build without Postgres support."
    }

    $staged = Copy-RuntimeClosure "libpq.dll" $LibpqDir $StageDir
    if ($null -eq $staged) {
        # No dumpbin: fall back to the DLLs an EDB build of libpq is known to
        # pull in. Anything absent is simply not part of that build.
        Write-Host "dumpbin unavailable — falling back to a fixed libpq dependency list"
        $staged = @()
        foreach ($lib in @("libpq.dll", "libssl-3-x64.dll", "libcrypto-3-x64.dll",
                           "libintl-9.dll", "libiconv-2.dll", "libwinpthread-1.dll",
                           "zlib1.dll")) {
            $src = Join-Path $LibpqDir $lib
            if (Test-Path $src) { Copy-Item $src $StageDir -Force; $staged += $lib }
        }
    }
    Write-Host "libpq from ${LibpqDir}: $($staged -join ', ')"
}

# ── MySQL / MariaDB ──────────────────────────────────────────────────────────
# Qt's official Windows binaries carry no qsqlmysql plugin, so there is nothing
# for a client library to serve. The check is kept so that a Qt build that does
# ship one does not silently repeat the libpq mistake.
if (-not $SkipClientLibs -and $Drivers -contains "qsqlmysql.dll") {
    $MysqlLib = @("libmariadb.dll", "libmysql.dll") |
                ForEach-Object { Find-OnPath $_ } |
                Where-Object { $_ } | Select-Object -First 1
    if (-not $MysqlLib) {
        throw "qsqlmysql.dll was deployed but neither libmariadb.dll nor libmysql.dll was found on PATH"
    }
    $staged = Copy-RuntimeClosure ([IO.Path]::GetFileName($MysqlLib)) (Split-Path $MysqlLib) $StageDir
    if ($null -eq $staged) { Copy-Item $MysqlLib $StageDir -Force }
    Write-Host "MySQL client: $MysqlLib"
}

# Oracle (qsqloci), Firebird (qsqlibase) and Mimer (qsqlmimer) are deliberately
# left to the user. Their clients are either not redistributable or a separate
# vendor install, so the plugin ships and finds its client on PATH if the user
# has one. ODBC needs nothing: the driver manager is part of Windows.

# ── Verify every deployed driver can actually load ───────────────────────────
# The failure this guards against is silent by construction: a driver plugin
# whose client library is absent still installs, still appears in the connection
# dialog, and only fails on the user's machine with "Driver not loaded". So each
# plugin's imports are resolved here against what is in the package plus what
# Windows itself provides, and anything left over is reported by name.
#
# SQLite, PostgreSQL and ODBC are what qub claims to support out of the box on
# Windows, so a gap in those fails the build. The rest ship on the understanding
# that the user brings the vendor client, which is exactly an unresolved import.
$SupportedOutOfTheBox = @("qsqlite.dll", "qsqlpsql.dll", "qsqlodbc.dll")
$System32 = Join-Path $env:SystemRoot "System32"
$Broken   = @()

foreach ($drv in $Drivers) {
    $imports = Get-DllImports (Join-Path $DriverDir $drv)
    if ($null -eq $imports) {
        Write-Warning "dumpbin unavailable — cannot verify $drv"
        continue
    }
    $missing = Get-UnresolvedImports $imports @($StageDir, $System32, $DriverDir)
    if ($missing.Count -eq 0) {
        Write-Host "  $drv — ok"
    } elseif ($SupportedOutOfTheBox -contains $drv) {
        $Broken += "$drv needs $($missing -join ', ')"
    } else {
        Write-Host "  $drv — needs a vendor client at runtime: $($missing -join ', ')"
    }
}

if ($Broken.Count -gt 0) {
    $detail = "These drivers would ship unloadable:`n  " + ($Broken -join "`n  ")
    if ($SkipClientLibs) { Write-Warning $detail } else { throw $detail }
}

# ── Compile Inno Setup installer ─────────────────────────────────────────────
$iss = (Get-Content packaging\windows\installer.iss -Raw) `
    -replace "__VERSION__", $Version `
    -replace "__STAGE__",   $StageDir.Replace("\", "\\") `
    -replace "__ICON__",    (Get-Item assets\qub.ico).FullName.Replace("\", "\\")
$tmpIss = "$env:TEMP\qub-installer.iss"
Set-Content -Path $tmpIss -Value $iss

& iscc $tmpIss "/O$((Get-Item $OutDir).FullName)"
if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed" }

Write-Host "Installer written to $OutDir"
