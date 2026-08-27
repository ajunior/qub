# tst_deploy.ps1 — exercise the dependency logic of packaging/windows/deploy.ps1
# with dumpbin faked, so it can run anywhere PowerShell runs rather than only on
# a Windows runner mid-release.
#
# The functions are pulled out of the shipped file by AST: the code under test
# is the code that ships. What the earlier version of this file did not cover
# was the verification step — and that is precisely where 0.44.9-rc.8 failed,
# by treating api-ms-win-* API set contracts as missing DLLs.
$ErrorActionPreference = "Stop"
$src = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) "packaging/windows/deploy.ps1"
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$null)
foreach ($name in @("Get-DllImports", "Copy-RuntimeClosure",
                    "Test-IsApiSet", "Get-UnresolvedImports")) {
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if (-not $fn) { throw "não achei a função $name em $src" }
    Invoke-Expression $fn.Extent.Text
}

$fails = 0
function Check($label, $got, $want) {
    $g = ($got | Sort-Object) -join ','
    $w = ($want | Sort-Object) -join ','
    if ($g -eq $w) { "  ok   $label" }
    else { $script:fails++; "  FALHA $label`n         obteve: [$g]`n         esperava: [$w]" }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("qubtest-" + [guid]::NewGuid())
$src_ = Join-Path $root "pgbin"; $dst = Join-Path $root "stage"
New-Item -ItemType Directory -Force -Path $src_, $dst | Out-Null

# A fake libpq: libpq -> libssl + KERNEL32 (system, absent from the dir)
#                libssl -> libcrypto
#                libcrypto -> (nothing)
# The api-ms-win-* entries are what a real import table looks like: MSVC links
# the CRT through API set contracts, and dumpbin reports them by name.
$graph = @{
    "libpq.dll"           = @("libssl-3-x64.dll", "KERNEL32.dll", "libpq.dll")  # self-ref: must not loop
    "libssl-3-x64.dll"    = @("libcrypto-3-x64.dll", "ADVAPI32.dll")
    "libcrypto-3-x64.dll" = @("KERNEL32.dll")
    "libintl-9.dll"       = @()
    "qsqlite.dll"         = @("Qt6Sql.dll", "api-ms-win-crt-heap-l1-1-0.dll",
                              "api-ms-win-crt-runtime-l1-1-0.dll", "KERNEL32.dll")
    "qsqlpsql.dll"        = @("Qt6Sql.dll", "libpq.dll", "api-ms-win-crt-string-l1-1-0.dll")
    "qsqloci.dll"         = @("Qt6Sql.dll", "oci.dll", "api-ms-win-crt-math-l1-1-0.dll")
}
foreach ($n in $graph.Keys) { Set-Content -Path (Join-Path $src_ $n) -Value "x" }

$script:dumpbinAvailable = $true
function dumpbin {
    if (-not $script:dumpbinAvailable) { $global:LASTEXITCODE = 1; return }
    $file = $args[-1]
    $name = [IO.Path]::GetFileName($file)
    $global:LASTEXITCODE = 0
    "Dump of file $name"
    ""
    "  Image has the following dependencies:"
    ""
    foreach ($d in $graph[$name]) { "    $d" }
    ""
    "  Summary"
    ""
    "        1000 .data"
    "        2000 .rdata"
}

"— fecho transitivo"
$got = Copy-RuntimeClosure "libpq.dll" $src_ $dst
Check "copiou o fecho, parou nas DLLs de sistema" $got @("libpq.dll","libssl-3-x64.dll","libcrypto-3-x64.dll")
Check "só isso chegou ao stage" ((Get-ChildItem $dst).Name) @("libpq.dll","libssl-3-x64.dll","libcrypto-3-x64.dll")
Check "libintl não entrou (ninguém importa)" (@(Get-ChildItem $dst -Filter "libintl*").Count) @(0)

"— parsing do relatório do dumpbin"
$imports = Get-DllImports (Join-Path $src_ "libssl-3-x64.dll")
Check "só nomes de DLL, sem prosa nem seções" $imports @("libcrypto-3-x64.dll","ADVAPI32.dll")

"— dumpbin ausente"
$script:dumpbinAvailable = $false
Remove-Item "$dst/*" -Force
$got = Copy-RuntimeClosure "libpq.dll" $src_ $dst
Check "sinaliza \$null para o chamador cair no fallback" (@($null -eq $got)) @($true)

"— alvo inexistente"
$script:dumpbinAvailable = $true
Remove-Item "$dst/*" -Force
$got = Copy-RuntimeClosure "naoexiste.dll" $src_ $dst
Check "nome ausente não copia nada nem estoura" $got @()

"— verificação de imports (o que derrubou a rc.8)"
# O que o pacote leva mais o que o Windows leva: KERNEL32 e Qt6Sql existem como
# arquivo; os contratos api-ms-win-* não existem em lugar nenhum, por desenho.
$sys = Join-Path $root "system32"; $pkg = Join-Path $root "pkg"
New-Item -ItemType Directory -Force -Path $sys, $pkg | Out-Null
foreach ($n in @("KERNEL32.dll", "ADVAPI32.dll")) { Set-Content -Path (Join-Path $sys $n) -Value "x" }
foreach ($n in @("Qt6Sql.dll", "libpq.dll")) { Set-Content -Path (Join-Path $pkg $n) -Value "x" }

Check "api-ms-win-* não conta como faltando" `
      (Get-UnresolvedImports (Get-DllImports (Join-Path $src_ "qsqlite.dll")) @($pkg, $sys)) @()
Check "ext-ms-* também não" (Get-UnresolvedImports @("ext-ms-win-foo-l1-1-0.dll") @($pkg)) @()
Check "driver com cliente presente passa" `
      (Get-UnresolvedImports (Get-DllImports (Join-Path $src_ "qsqlpsql.dll")) @($pkg, $sys)) @()
Check "cliente de fornecedor ausente é nomeado" `
      (Get-UnresolvedImports (Get-DllImports (Join-Path $src_ "qsqloci.dll")) @($pkg, $sys)) @("oci.dll")
Check "Test-IsApiSet não engole DLL comum" (@(Test-IsApiSet "libpq.dll")) @($false)

Remove-Item -Recurse -Force $root
if ($fails -gt 0) { "`n$fails falha(s)"; exit 1 } else { "`ntudo passou"; exit 0 }
