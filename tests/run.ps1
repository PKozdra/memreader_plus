$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$hostBuild = Join-Path $root 'build\host'
cmake -S (Join-Path $PSScriptRoot 'host') -B $hostBuild -G 'Visual Studio 17 2022' -A x64 | Out-Null
cmake --build $hostBuild --config Release | Out-Null
if ($LASTEXITCODE) { throw 'test host build failed' }
$exe = Join-Path $hostBuild 'Release\Warhammer3.exe'
$crash = -1073741819
$reportPrefix = 'memreader_crash_report_'

$failed = @()
$skipped = @()
$expect = [ordered]@{
    api = 0; api_cases = 0; plus_first = 0; cpecific_first = 0; cpecific_bigread = $crash
    call_cpp_exception = -1073740791; call_stack_overflow = -1073741571; hook = 0
    fault_report = $crash; fault_report_no_log = $crash; fault_report_off = $crash; fault_report_in_callback = $crash
}
$reports = @{ fault_report = '010203_0405'; fault_report_no_log = 'started'; fault_report_off = 'none'; fault_report_in_callback = 'started' }
$profilePacks = Join-Path $env:TEMP 'memreader_plus_test_packs'
$cpecificDir = [IO.Path]::GetFullPath((Join-Path $root '..\..\workshop\2789863945_twwh3-memreader'))
$needsCpecific = @('plus_first', 'cpecific_first', 'cpecific_bigread')

function New-ModFile($work) {
    $packs = New-Item -ItemType Directory (Join-Path $work 'packs')
    $other = New-Item -ItemType Directory (Join-Path $work 'other')
    if (Test-Path $profilePacks) { Remove-Item -Recurse -Force $profilePacks }
    New-Item -ItemType Directory $profilePacks | Out-Null
    Set-Content (Join-Path $packs 'first.pack') 'abc' -NoNewline
    Set-Content (Join-Path $packs 'second.pack') 'abcdef' -NoNewline
    Set-Content (Join-Path $other 'second.pack') 'x' -NoNewline
    Set-Content (Join-Path $profilePacks 'third.pack') 'ab' -NoNewline
    $lines = @(
        "add_working_directory `"$packs\`";", "add_working_directory `"$other`";", "add_working_directory `"$profilePacks`";",
        '# a comment', 'mod "first.pack";', 'mod "second.pack"; mod "third.pack";', 'mod "missing.pack";'
    )
    Set-Content (Join-Path $work 'mods.txt') $lines
}

$modNeedles = @(
    'Mods in load order (4, from the mod file on the command line)', '1. first.pack  3 bytes', '2. second.pack  6 bytes',
    '3. third.pack  2 bytes', '%USERPROFILE%', '4. missing.pack  not found in any search path',
    'Same name in a later search path, not loaded:', 'Command line: ', 'Game crash folder: ', 'Game: Warhammer3.exe '
)

foreach ($scenario in $expect.Keys) {
    if ($needsCpecific -contains $scenario -and -not (Test-Path $cpecificDir)) {
        "== $scenario"
        "skipped: Cpecific's files not found at $cpecificDir"
        $skipped += $scenario
        continue
    }
    $work = Join-Path $root "build\test_$scenario"
    if (Test-Path $work) { Remove-Item -Recurse -Force $work }
    New-Item -ItemType Directory $work | Out-Null
    Push-Location $work
    try {
        "== $scenario"
        if ($scenario -eq 'fault_report') {
            $old = New-Item (Join-Path $work 'script_log_311299_2359.txt')
            $old.CreationTime = (Get-Date).AddDays(-1)
        }
        $extra = @()
        if ($reports.Contains($scenario)) {
            New-ModFile $work
            $extra = @('mods.txt;')
        }
        $before = Get-Date -Format 'ddMMyy_HHmm'
        & $exe (Join-Path $PSScriptRoot 'offline.lua') ($root -replace '\\', '/') $scenario @extra
        $after = Get-Date -Format 'ddMMyy_HHmm'
        if ($LASTEXITCODE -ne $expect[$scenario]) { $failed += $scenario; "exit $LASTEXITCODE, expected $($expect[$scenario])" }
        elseif ($LASTEXITCODE) { "crashed as expected (exit $('{0:X8}' -f $LASTEXITCODE))" }
        if ($reports.Contains($scenario)) {
            $written = @(Get-ChildItem $work -Filter "$reportPrefix*.txt" | ForEach-Object Name)
            if ($reports[$scenario] -eq 'none') {
                if ($written.Count) { $failed += "$scenario (reporting was off but wrote $written)" }
                continue
            }
            $stamps = if ($reports[$scenario] -eq 'started') { $before, $after } else { , $reports[$scenario] }
            $report = $written | Where-Object { $stamps -contains ($_ -replace "^$reportPrefix|\.txt$") } | Select-Object -First 1
            if ($written.Count -ne 1 -or -not $report) { $failed += "$scenario (reports: $written, expected stamp $stamps)"; continue }
            $text = Get-Content -Raw -ErrorAction SilentlyContinue (Join-Path $work $report)
            $logLine = if ($scenario -eq 'fault_report') { 'Script log of this Lua state: script_log_010203_0405.txt' } else { 'Script logging is off' }
            foreach ($needle in @('exception 0xc0000005', 'report_me', 'marker = "event-under-test"', $logLine) + $modNeedles) {
                if (-not $text -or -not $text.Contains($needle)) { $failed += "$scenario (report lacks: $needle)" }
            }
            if ($text -and $text.Contains($env:USERPROFILE)) { $failed += "$scenario (report shows the user profile path)" }
            if ($text -and $text.Contains('\\')) { $failed += "$scenario (report has a doubled backslash)" }
        }
    } finally { Pop-Location }
}
if (Test-Path $profilePacks) { Remove-Item -Recurse -Force $profilePacks }
if ($failed) { throw "failed: $($failed -join ', ')" }
if ($skipped) { "all other scenarios passed; skipped: $($skipped -join ', ')" } else { 'all scenarios passed' }
