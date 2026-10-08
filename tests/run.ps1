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
    call_cpp_exception = -529697949; call_stack_overflow = -1073741571; hook = 0; heap = 0; guard = 0; frame = 0; hooked_code = 0; bench = 0
    file_edit = 0; file_edit_sites = 0; file_edit_off = 0; file_edit_saved_off = 0
    fault_report = $crash; fault_report_no_log = $crash; fault_report_off = $crash; fault_report_in_callback = $crash
    fault_report_stale = $crash; fault_report_thread = $crash; fault_report_native_thread = $crash; fault_report_overflow = -1073741571
    fault_report_cpp = -529697949; fault_report_fallback = $crash; fault_report_clues = $crash
    fault_report_two_threads = $crash; fault_report_worker_stuck = $crash; fault_report_worker_waits = $crash
    fault_report_worker_blocked = $crash; fault_report_worker_dead = $crash; fault_report_move_retry = $crash; fault_report_move_fails = $crash
    exit_report = 7; exit_report_terminate = 8; exit_report_crt = 9; exit_report_quiet = 0; exit_report_off = 7
    runtime_report = 0; runtime_report_reports_off = 0; runtime_report_no_folder = 0; runtime_report_write_fails = 0
    runtime_report_then_crash = $crash; settings_cut = $crash; settings_none = $crash
    report_snapshot = 0; report_native = 0; report_lua_only = 0; report_loader = 0
}
$reports = @{
    fault_report = '010203_0405'; fault_report_no_log = 'started'; fault_report_off = 'none'; fault_report_in_callback = 'started'
    fault_report_stale = 'started'; fault_report_thread = 'started'; fault_report_native_thread = 'started'; fault_report_overflow = 'started'
    fault_report_cpp = 'started'; fault_report_fallback = 'started'; fault_report_clues = 'started'
    fault_report_two_threads = 'started'; fault_report_worker_stuck = 'none'; fault_report_worker_waits = 'started'
    fault_report_worker_blocked = 'none'; fault_report_worker_dead = 'none'; fault_report_move_retry = 'started'; fault_report_move_fails = 'started'
    exit_report = 'started'; exit_report_terminate = 'started'; exit_report_crt = 'started'; exit_report_quiet = 'none'; exit_report_off = 'none'
    runtime_report = 'none'; runtime_report_reports_off = 'none'; runtime_report_no_folder = 'none'; runtime_report_write_fails = 'none'
    runtime_report_then_crash = 'started'; settings_cut = 'started'; settings_none = 'started'; report_native = 'none'
}
$runtimeCounts = @{
    runtime_report = 1; runtime_report_reports_off = 1; runtime_report_no_folder = 0; runtime_report_write_fails = 0; runtime_report_then_crash = 1; report_native = 1
}
$readOfNull = @('exception 0xc0000005 (access violation)', 'read of 0000000000000010 (a NULL pointer + 0x10)')
$faultNeedles = @{
    fault_report = $readOfNull; fault_report_no_log = @('exception 0xc0000005 (access violation)', 'execution of'); fault_report_in_callback = $readOfNull
    fault_report_stale = $readOfNull; fault_report_thread = $readOfNull; fault_report_native_thread = $readOfNull
    fault_report_overflow = @('exception 0xc00000fd (stack overflow)'); fault_report_cpp = @('exception 0xe06d7363 (C++ exception, type .H)')
    fault_report_fallback = $readOfNull; fault_report_clues = @('exception 0xc0000005 (access violation)')
    fault_report_two_threads = $readOfNull; fault_report_worker_waits = $readOfNull; fault_report_move_retry = $readOfNull
    fault_report_move_fails = $readOfNull; runtime_report_then_crash = $readOfNull; settings_cut = $readOfNull; settings_none = $readOfNull
}
$nativeNeedles = @(
    'Game running for ', 'Memory: game ', 'Native stack of the crashing thread, innermost first:', '  #0 ', ', offset +0x',
    'Registers of the crashing thread:', '  rip ', 'memreader Plus hooks: ', "Other programs' DLLs loaded: "
)
$exitScenarios = @('exit_report', 'exit_report_terminate', 'exit_report_crt')
$exitNeedles = @(
    'Game running for ', 'Memory: game ', 'Native stack of the thread that ended the game, innermost first:', '  #0 ', ', offset +0x',
    'Warhammer3.exe+0x', 'memreader Plus hooks: ', "Other programs' DLLs loaded: "
)
$exitAbsent = @('report_me', "The game's crash handler caught it", 'Lua stack', '  #0 memreader_plus', 'Registers of the crashing thread:')
$offScriptThread = @('fault_report_native_thread', 'fault_report_two_threads', 'fault_report_worker_waits')
$timeLimits = @{
    fault_report_worker_stuck = 4, 9; fault_report_worker_waits = 4, 9; fault_report_worker_blocked = 9, 15; fault_report_worker_dead = 0, 3
}
$moveCalls = @{ fault_report_move_retry = '4'; fault_report_move_fails = '5' }
$staleTemporary = 'memreader_crash_report_010101_0000.txt.1.tmp'
$otherDll = 'fake_overlay64.dll'
$otherDllCount = "Other programs' DLLs loaded: [1-9]"
$hookerDll = 'fake_speedhack64.dll'
$noTimingHooks = "No other program's DLL hooks the game's timing functions"
$steamScenario = 'fault_report_cpp'
$steamCommandLine = '<Steam library>\steamapps\common\game\Warhammer3.exe'
$eventNeedles = @(
    '  faction turn: wh_c', 'Recent script events, newest first:', '  CharacterTurnStart x3, last ', '  FactionTurnStart x1, last ',
    'Recent memory writes by mods, newest first:', '  write x2 at '
)
$scenarioNeedles = @{
    fault_report = @(
        '  relocate_field x40 at ', ', 4 bytes, from ', '  patch at ', '[string "later_patch"]:1', '[string "filler_patch_29"]:1',
        '  ... 6 more patches not listed', '[string "newest_patch"]:1'
    )
    fault_report_in_callback = @('RUNNING (on the stack)', ', callback ')
    fault_report_native_thread = @('not the script thread', 'paused while the other thread crashed', 'Native stack of the script thread at the time')
    fault_report_two_threads = @('not the script thread', 'paused while the other thread crashed', 'Native stack of the script thread at the time')
    fault_report_worker_waits = @('not the script thread', 'paused while the other thread crashed', 'Native stack of the script thread at the time')
    exit_report = @('the game ended itself with exit code 7 (0x00000007) through ExitProcess', 'Thread: the script thread')
    exit_report_terminate = @('the game ended itself with exit code 8 (0x00000008) through TerminateProcess', 'not the script thread')
    exit_report_crt = @('the game ended itself with exit code 9 (0x00000009) through ExitProcess', 'Thread: the script thread')
    fault_report_fallback = @("Written when the fault happened: the game's crash handler was not found (its pattern matched nothing)")
    fault_report_clues = @(
        "This fault is in the game's memory allocator: memory was damaged earlier, and the code on this stack only found it",
        'not readable, text "a to"', 'Memory around rcx+16, which holds the bad value of rax:', '  a toolti', '  p text o',
        "Other programs' DLLs that hook timing functions the game uses:", "  $hookerDll hooks QueryPerformanceCounter",
        "  $hookerDll hooks timeGetTime"
    )
}
$contextNeedles = @(
    'Game context set by script at safe moments:', '  mode: campaign', '  campaign: main_warhammer', '  campaign type: sp', '  difficulty: hard',
    '  turn: 42', '  player: wh_a', '  humans: wh_a, wh_b', '  note: first second', '  phase: quitting'
)
$contextAbsent = @('  temp: ', '  multiplayer: ')
$settingsHeader = 'MCT settings of the mods in this game ('
$settingsNeedles = @(
    $settingsHeader, ' seconds before this report):', '[alpha_mod] Alpha Mod', '  enabled = true', '  strength = 2.5', '[beta_mod] Beta Mod',
    '  note = tab and return', '[gamma_mod] Gamma Mod', '  hours = 12'
)
$settingsNone = 'MCT settings: none recorded (MCT is not installed or has not loaded yet)'
$settingsCutNeedles = @($settingsHeader, '[big_mod] Big Mod', '  option_0001 = value', '... cut: the settings list reached its size limit')
$reportLimit = 48 * 1024
$runtimePrefix = 'memreader_runtime_report_'
$runtimeNeedles = @(
    ' runtime report', 'written on request, nothing crashed', 'Thread: the script thread', 'Script logging is off', 'Game running for ',
    'Memory: game ', 'memreader Plus hooks: ', "Other programs' DLLs loaded: "
)
$runtimeAbsent = @('Lua stack', 'Registers of the crashing thread:', 'Native stack of', "The game's crash handler caught it", 'exception 0x')
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
        $runExe = $exe
        if ($reports.Contains($scenario)) {
            New-ModFile $work
            New-Item -ItemType Directory (Join-Path $work 'crash_report') | Out-Null
            Copy-Item (Join-Path $env:SystemRoot 'System32\version.dll') (Join-Path $work $otherDll)
            Set-Content (Join-Path $work $staleTemporary) 'left by a crash' -NoNewline
            if ($scenario -eq 'fault_report_clues') { Copy-Item (Join-Path $env:SystemRoot 'System32\version.dll') (Join-Path $work $hookerDll) }
            $extra = @('mods.txt;', 'appdata_folder', "$work;")
            if ($scenario -eq 'fault_report_no_log') { $extra += 'x' * ($commandLineBuffer + 100) }
            if ($scenario -eq $steamScenario) {
                $gameDir = New-Item -ItemType Directory (Join-Path $work 'library\steamapps\common\game')
                Copy-Item $exe $gameDir
                $runExe = Join-Path $gameDir 'Warhammer3.exe'
            }
        }
        $before = Get-Date -Format 'ddMMyy_HHmm'
        $hostArguments = @((Join-Path $PSScriptRoot 'offline.lua'), ($root -replace '\\', '/'), $scenario) + $extra
        $clock = [Diagnostics.Stopwatch]::StartNew()
        if ($timeLimits.Contains($scenario)) {
            $process = Start-Process $runExe -ArgumentList $hostArguments -NoNewWindow -PassThru
            $null = $process.Handle
            if (-not $process.WaitForExit($timeLimits[$scenario][1] * 1000)) { $process.Kill(); $process.WaitForExit() }
            $exitCode = $process.ExitCode
            $seconds = [math]::Round($clock.Elapsed.TotalSeconds, 1)
            "took $seconds s"
            if ($seconds -lt $timeLimits[$scenario][0] -or $seconds -ge $timeLimits[$scenario][1]) { $failed += "$scenario (took $seconds s, expected $($timeLimits[$scenario] -join ' to ') s)" }
        } else {
            & $runExe @hostArguments
            $exitCode = $LASTEXITCODE
        }
        $after = Get-Date -Format 'ddMMyy_HHmm'
        if ($exitCode -ne $expect[$scenario]) { $failed += $scenario; "exit $exitCode, expected $($expect[$scenario])" }
        elseif ($exitCode) { "crashed as expected (exit $('{0:X8}' -f $exitCode))" }
        if ($moveCalls.Contains($scenario)) {
            $calls = Get-Content -Raw -ErrorAction SilentlyContinue (Join-Path $work 'move_calls.txt')
            if ($calls -ne $moveCalls[$scenario]) { $failed += "$scenario (MoveFileExA called $calls times, expected $($moveCalls[$scenario]))" }
        }
        if ($runtimeCounts.Contains($scenario)) {
            $runtimeWritten = @(Get-ChildItem $work -File -Filter "$runtimePrefix*.txt" | ForEach-Object Name)
            $runtimeLeftovers = @(Get-ChildItem $work -File -Filter "$runtimePrefix*.tmp" | ForEach-Object Name)
            if ($runtimeLeftovers) { $failed += "$scenario (temporary runtime report files left: $runtimeLeftovers)" }
            if ($runtimeWritten.Count -ne $runtimeCounts[$scenario]) { $failed += "$scenario (runtime reports: $runtimeWritten, expected $($runtimeCounts[$scenario]))" }
            elseif ($runtimeWritten.Count) {
                $text = Get-Content -Raw -ErrorAction SilentlyContinue (Join-Path $work $runtimeWritten[0])
                $needles = $runtimeNeedles + $settingsNeedles + $contextNeedles + $eventNeedles + $modNeedles
                $missing = @($needles | Where-Object { -not $text -or -not $text.Contains($_) })
                foreach ($needle in $missing) { $failed += "$scenario (runtime report lacks: $needle)" }
                if ($missing) { $text }
                foreach ($absent in $runtimeAbsent) { if ($text -and $text.Contains($absent)) { $failed += "$scenario (runtime report shows $absent)" } }
                if ($text -and $text.Contains($env:USERPROFILE)) { $failed += "$scenario (runtime report shows the user profile path)" }
                if ($text -and $text.Contains($otherDll)) { $failed += "$scenario (runtime report names another program's DLL)" }
            }
        }
        if ($reports.Contains($scenario)) {
            $written = @(Get-ChildItem $work -Filter "$reportPrefix*.txt" | ForEach-Object Name)
            $leftovers = @(Get-ChildItem $work -Filter "$reportPrefix*.tmp" | ForEach-Object Name)
            if ($leftovers) { $failed += "$scenario (temporary report files left: $leftovers)" }
            if ($reports[$scenario] -eq 'none') {
                if ($written.Count) { $failed += "$scenario (reporting was off but wrote $written)" }
                continue
            }
            $stamps = if ($reports[$scenario] -eq 'started') { $before, $after } else { , $reports[$scenario] }
            $report = $written | Where-Object { $stamps -contains ($_ -replace "^$reportPrefix|\.txt$") } | Select-Object -First 1
            if ($written.Count -ne 1 -or -not $report) { Get-ChildItem $work | ForEach-Object { "$($_.Name) created $($_.CreationTimeUtc.ToString('o'))" }; $failed += "$scenario (reports: $written, expected stamp $stamps)"; continue }
            $text = Get-Content -Raw -ErrorAction SilentlyContinue (Join-Path $work $report)
            $logLine = if ($scenario -eq 'fault_report') { 'Script log of this Lua state: script_log_010203_0405.txt' } else { 'Script logging is off' }
            $isExit = $exitScenarios -contains $scenario
            if ($isExit) {
                $needles = @($logLine) + $exitNeedles + $modNeedles
                foreach ($absent in $exitAbsent) { if ($text -and $text.Contains($absent)) { $failed += "$scenario (exit report shows $absent)" } }
            } else {
                $needles = @('report_me', 'marker = "event-under-test"', $logLine) + $faultNeedles[$scenario] + $modNeedles + $nativeNeedles
            }
            if ($scenario -ne 'fault_report_stale') { $needles += $contextNeedles + $eventNeedles }
            if ($scenario -eq 'settings_cut') { $needles += $settingsCutNeedles }
            elseif ($scenario -eq 'settings_none' -or $scenario -eq 'fault_report_stale') { $needles += $settingsNone }
            else { $needles += $settingsNeedles }
            if ($scenario -ne 'fault_report_fallback' -and -not $isExit) { $needles += $gameFilesNote; $needles += "The game's crash handler caught it" }
            if ($offScriptThread -notcontains $scenario -and -not $isExit) { $needles += 'Thread: the script thread'; $needles += 'Code at rip:' }
            if ($scenario -eq 'fault_report_thread') { $needles += 'Lua thread ' }
            if ($scenarioNeedles.Contains($scenario)) { $needles += $scenarioNeedles[$scenario] }
            if ($scenario -ne 'fault_report_clues') { $needles += $noTimingHooks }
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
            if ($scenario -eq 'settings_none' -and $text -and $text.Contains($settingsHeader)) { $failed += "$scenario (report shows a settings block)" }
            if ($scenario -eq 'settings_cut') {
                $size = (Get-Item (Join-Path $work $report)).Length
                if ($size -gt $reportLimit) { $failed += "$scenario (report is $size bytes, over $reportLimit)" }
                if ($text -and $text.Contains('  option_2000 = value')) { $failed += "$scenario (the settings list was not cut)" }
                foreach ($early in @('this part stopped early', 'the report was cut here')) { if ($text -and $text.Contains($early)) { $failed += "$scenario (report shows: $early)" } }
            }
            if ($text -and $text.Contains($env:USERPROFILE)) { $failed += "$scenario (report shows the user profile path)" }
            if ($text -and $text.Contains($otherDll)) { $failed += "$scenario (report names another program's DLL)" }
            if ($text -notmatch $otherDllCount) { $failed += "$scenario (report lacks the count of other programs' DLLs)" }
            if ($scenario -eq $steamScenario) {
                if (-not $text.Contains($steamCommandLine)) { $failed += "$scenario (report lacks: $steamCommandLine)" }
                if ($text.Contains((Join-Path $work 'library'))) { $failed += "$scenario (report shows the Steam library path)" }
            }
            if ($text -and $text.Contains('\\')) { $failed += "$scenario (report has a doubled backslash)" }
        }
    } finally { Pop-Location }
}
if (Test-Path $profilePacks) { Remove-Item -Recurse -Force $profilePacks }
if ($failed) { throw "failed: $($failed -join ', ')" }
if ($skipped) { "all other scenarios passed; skipped: $($skipped -join ', ')" } else { 'all scenarios passed' }
