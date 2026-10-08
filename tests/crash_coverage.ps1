param([string[]]$Only)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $root 'build\host\Release\Warhammer3.exe'
$out = Join-Path $root 'build\crash_coverage'
$cases = [ordered]@{
    av_script = 'av'; av_worker = 'av_thread'; overflow_script = 'overflow'; overflow_worker = 'overflow_thread'
    fastfail_script = 'fastfail'; fastfail_worker = 'fastfail_thread'; abort_script = 'abort'; abort_worker = 'abort_thread'
    cpp_script = 'cpp'; cpp_worker = 'cpp_thread'; heap_double_free_script = 'heap_double_free'
    heap_double_free_worker = 'heap_double_free_thread'; heap_overrun_script = 'heap_overrun'; exit_process_script = 'exit_process'
    exit_process_worker = 'exit_process_thread'; terminate_process_script = 'terminate_process'; crt_exit_script = 'crt_exit'
    divide_script = 'divide'; divide_worker = 'divide_thread'; ud2_script = 'ud2'; ud2_worker = 'ud2_thread'
    second_fault_script = 'second'; two_threads_script = 'two_threads'; worker_stuck_script = 'worker_stuck'
}
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory $out | Out-Null
foreach ($name in $cases.Keys) {
    if ($Only -and $Only -notcontains $name) { continue }
    $work = New-Item -ItemType Directory (Join-Path $out $name)
    New-Item -ItemType Directory (Join-Path $work 'crash_report') | Out-Null
    $arguments = @((Join-Path $PSScriptRoot 'crash_coverage.lua'), ($root -replace '\\', '/'), "crash_coverage_$($cases[$name])", 'appdata_folder', "$work;")
    $started = Get-Date
    $process = Start-Process $exe -ArgumentList ($arguments | ForEach-Object { "`"$_`"" }) -WorkingDirectory $work -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $work 'stdout.txt') -RedirectStandardError (Join-Path $work 'stderr.txt')
    $finished = $process.WaitForExit(60000)
    if (-not $finished) { $process.Kill(); $process.WaitForExit() }
    $seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
    $report = Get-ChildItem $work -Filter 'memreader_crash_report_*.txt' | Select-Object -First 1
    $dumps = @(Get-ChildItem (Join-Path $work 'crash_report') -ErrorAction SilentlyContinue).Count
    $code = if ($finished) { '0x{0:X8}' -f $process.ExitCode } else { 'timeout' }
    "== $name exit $code, report $([bool]$report), game crash files $dumps, $seconds s"
    if ($report) { Get-Content $report.FullName -TotalCount 20 | ForEach-Object { "   $_" } }
}
