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
    call_cpp_exception = -529697949; call_stack_overflow = -1073741571; hook = 0; heap = 0; guard = 0; frame = 0; bench = 0
    fault_report = $crash; fault_report_no_log = $crash; fault_report_off = $crash; fault_report_in_callback = $crash
    fault_report_stale = $crash; fault_report_thread = $crash; fault_report_native_thread = $crash; fault_report_overflow = -1073741571
    fault_report_cpp = -529697949; fault_report_fallback = $crash
}
$reports = @{
    fault_report = '010203_0405'; fault_report_no_log = 'started'; fault_report_off = 'none'; fault_report_in_callback = 'started'
    fault_report_stale = 'started'; fault_report_thread = 'started'; fault_report_native_thread = 'started'; fault_report_overflow = 'started'
    fault_report_cpp = 'started'; fault_report_fallback = 'started'
}
$readOfNull = @('exception 0xc0000005 (access violation)', 'read of 0000000000000010 (a NULL pointer + 0x10)')
$faultNeedles = @{
    fault_report = $readOfNull; fault_report_no_log = @('exception 0xc0000005 (access violation)', 'execution of'); fault_report_in_callback = $readOfNull
    fault_report_stale = $readOfNull; fault_report_thread = $readOfNull; fault_report_native_thread = $readOfNull
    fault_report_overflow = @('exception 0xc00000fd (stack overflow)'); fault_report_cpp = @('exception 0xe06d7363 (C++ exception, type .H)')
    fault_report_fallback = $readOfNull
}
$nativeNeedles = @(
    'Game running for ', 'Memory: game ', 'Native stack of the crashing thread, innermost first:', '  #0 ', ', offset +0x',
    'Registers of the crashing thread:', '  rip ', 'memreader Plus hooks: ', 'DLLs from outside Windows and the game folder:'
)
$eventNeedles = @(
    '  faction turn: wh_c', 'Recent script events, newest first:', '  CharacterTurnStart x3, last ', '  FactionTurnStart x1, last ',
    'Recent memory writes by mods, newest first:', '  write x2 at '
)
$scenarioNeedles = @{
    fault_report_in_callback = @('RUNNING (on the stack)', ', callback ')
    fault_report_native_thread = @('not the script thread', 'paused while the other thread crashed', 'Native stack of the script thread at the time')
    fault_report_fallback = @('Written when the fault happened')
}
$contextNeedles = @(
    'Game context set by script at safe moments:', '  mode: campaign', '  campaign: main_warhammer', '  campaign type: sp', '  difficulty: hard',
    '  turn: 42', '  player: wh_a', '  humans: wh_a, wh_b', '  note: first second'
)
$contextAbsent = @('  temp: ', '  multiplayer: ')
$gameFilesNote = "The game's own crash files for this crash, in the game crash folder: D"
$commandLineStart = 'Command line: '
$commandLineBuffer = 1039
$profilePacks = Join-Path $env:LOCALAPPDATA 'Temp\memreader_plus_test_packs'
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
            New-Item -ItemType Directory (Join-Path $work 'crash_report') | Out-Null
            $extra = @('mods.txt;', 'appdata_folder', "$work;")
            if ($scenario -eq 'fault_report_no_log') { $extra += 'x' * ($commandLineBuffer + 100) }
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
            if ($written.Count -ne 1 -or -not $report) { Get-ChildItem $work | ForEach-Object { "$($_.Name) created $($_.CreationTimeUtc.ToString('o'))" }; $failed += "$scenario (reports: $written, expected stamp $stamps)"; continue }
            $text = Get-Content -Raw -ErrorAction SilentlyContinue (Join-Path $work $report)
            $logLine = if ($scenario -eq 'fault_report') { 'Script log of this Lua state: script_log_010203_0405.txt' } else { 'Script logging is off' }
            $needles = @('report_me', 'marker = "event-under-test"', $logLine) + $faultNeedles[$scenario] + $modNeedles + $nativeNeedles
            if ($scenario -ne 'fault_report_stale') { $needles += $contextNeedles + $eventNeedles }
            if ($scenario -ne 'fault_report_fallback') { $needles += $gameFilesNote; $needles += "The game's crash handler caught it" }
            if ($scenario -ne 'fault_report_native_thread') { $needles += 'Thread: the script thread'; $needles += 'Code at rip:' }
            if ($scenario -eq 'fault_report_thread') { $needles += 'Lua thread ' }
            if ($scenarioNeedles.Contains($scenario)) { $needles += $scenarioNeedles[$scenario] }
            $missing = @($needles | Where-Object { -not $text -or -not $text.Contains($_) })
            foreach ($needle in $missing) { $failed += "$scenario (report lacks: $needle)" }
            if ($missing) { $text }
            if ($scenario -eq 'fault_report_no_log') {
                $line = $text -split "`n" | Where-Object { $_.StartsWith($commandLineStart) }
                if (-not $line -or $line.Length -gt $commandLineStart.Length + $commandLineBuffer -or -not $line.EndsWith('x')) { $failed += "$scenario (long command line not cut at its buffer: $($line.Length) characters)" }
            }
            if ($scenario -ne 'fault_report_stale') {
                foreach ($absent in $contextAbsent) { if ($text -and $text.Contains($absent)) { $failed += "$scenario (report shows $absent)" } }
            }
            if ($text -and $text.Contains($env:USERPROFILE)) { $failed += "$scenario (report shows the user profile path)" }
            if ($text -and $text.Contains('\\')) { $failed += "$scenario (report has a doubled backslash)" }
        }
    } finally { Pop-Location }
}
if (Test-Path $profilePacks) { Remove-Item -Recurse -Force $profilePacks }
if ($failed) { throw "failed: $($failed -join ', ')" }
if ($skipped) { "all other scenarios passed; skipped: $($skipped -join ', ')" } else { 'all scenarios passed' }
