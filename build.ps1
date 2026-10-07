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
Copy-Item -Recurse (Join-Path $root 'script') $stage
$licenses = @(Get-Content -Raw (Join-Path $root 'LICENSE.md'); Get-Content -Raw (Join-Path $root 'vendor\minhook\LICENSE.txt'))
Set-Content -Encoding utf8 (Join-Path $stage 'script\memreader_plus\third_party_licenses.txt') ($licenses -join "`r`n`r`n")
Copy-Item $dll $dist
python (Join-Path $root 'tools\dll_to_lua.py') $dll
if ($LASTEXITCODE) { throw 'dll_to_lua failed' }

if (-not $NoPack) {
    python (Join-Path $root 'tools\build_pack.py') $stage $pack
    if ($LASTEXITCODE) { throw 'build_pack failed' }
}
