param([switch]$NoPack)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$build = Join-Path $root 'build'
$dist = Join-Path $root 'dist'
$stage = Join-Path $dist 'pack'
$pack = Join-Path (Split-Path $root -Parent) 'memreader_plus.pack'

cmake -S $root -B $build -G 'Visual Studio 17 2022' -A x64 | Out-Null
if ($LASTEXITCODE) { throw 'cmake configure failed' }
cmake --build $build --config Release | Out-Null
if ($LASTEXITCODE) { throw 'cmake build failed (run: cmake --build build --config Release)' }
$dll = Join-Path $build 'Release\memreader_plus.dll'

if (Test-Path $dist) { Remove-Item -Recurse -Force $dist }
New-Item -ItemType Directory $stage | Out-Null
$release = python (Join-Path $root 'tools\stage_release.py') $stage | Select-Object -Last 1
if ($LASTEXITCODE) { throw 'stage_release failed' }
$plus = "script\memreader_plus"
$required = @(
    'script\_lib\mod\!memreader_plus_boot.lua', 'script\_lib\mod\memreader.lua', 'script\_lib\mod\memreader_plus.lua',
    'script\_lib\mod\memreader_plus_context.lua', 'script\_lib\mod\memreader_plus_report.lua',
    "$plus\loader.lua", "$plus\releases\$release.lua"
)
foreach ($name in 'loader', 'agree', 'sites', 'twui', 'file_edit_switch', 'locale_guard') { $required += "$plus\$release\$name.lua" }
foreach ($name in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $stage $name))) { throw "$name is missing from the pack folder" }
}
foreach ($name in 'agree', 'sites', 'twui', 'file_edit_switch', 'locale_guard', 'bin') {
    if (Test-Path -LiteralPath (Join-Path $stage "$plus\$name.lua")) { throw "$plus\$name.lua must live in the release folder only" }
}
$licenses = @(
    Get-Content -Raw (Join-Path $root 'LICENSE.md')
    Get-Content -Raw (Join-Path $root 'vendor\minhook\LICENSE.txt')
    "Zydis 4.1.1, https://github.com/zyantific/zydis`r`n`r`n" + (Get-Content -Raw (Join-Path $root 'vendor\zydis\LICENSE'))
    "Zycore, https://github.com/zyantific/zycore-c`r`n`r`n" + (Get-Content -Raw (Join-Path $root 'vendor\zycore\LICENSE'))
)
Set-Content -Encoding utf8 (Join-Path $stage "$plus\third_party_licenses.txt") ($licenses -join "`r`n`r`n")
Copy-Item $dll $dist
python (Join-Path $root 'tools\dll_to_lua.py') $dll --out (Join-Path $stage "$plus\$release\bin.lua")
if ($LASTEXITCODE) { throw 'dll_to_lua failed' }
python (Join-Path $root 'tools\stage_release.py') $stage --check-published
if ($LASTEXITCODE) { throw 'the release id is already published with other bytes' }

if (-not $NoPack) {
    python (Join-Path $root 'tools\build_pack.py') $stage $pack
    if ($LASTEXITCODE) { throw 'build_pack failed' }
}
