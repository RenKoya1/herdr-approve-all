$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('herdr-approve-test-' + [guid]::NewGuid())
$null = New-Item -ItemType Directory -Path $tmp
$workerPid = $null
function Wait-Until([scriptblock]$Condition, [string]$Message) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $Condition)) {
        if ($watch.Elapsed.TotalSeconds -gt 45) { throw $Message }
        Start-Sleep -Milliseconds 100
    }
}
function Send-Count {
    if (Test-Path (Join-Path $tmp 'sent')) { return @(Get-Content (Join-Path $tmp 'sent')).Count }
    return 0
}
try {
    $env:HERDR_PLUGIN_CONFIG_DIR = $tmp
    $env:HERDR_PLUGIN_STATE_DIR = Join-Path $tmp 'state'
    $env:HERDR_BIN_PATH = Join-Path $tmp 'herdr.cmd'
    $env:MOCK_HERDR_DIR = $tmp
    $env:APPROVE_AUTO_POLL_SEC = '0.1'
    $env:APPROVE_SETTLE_SEC = '0.01'
    $mock = @'
@echo off
if "%1 %2"=="agent list" echo {"result":{"agents":[{"pane_id":"pane-1","agent":"codex"}]}}
if "%1 %2"=="agent get" if exist "%MOCK_HERDR_DIR%\pending" echo {"result":{"agent":{"agent_status":"blocked"}}}
if "%1 %2"=="agent get" if not exist "%MOCK_HERDR_DIR%\pending" echo {"result":{"agent":{"agent_status":"working"}}}
if "%1 %2"=="agent read" if exist "%MOCK_HERDR_DIR%\fallback" echo 1. Yes - enter to confirm - esc to cancel
if "%1 %2"=="agent send-keys" goto send
exit /b 0
:send
echo %4 %5>>"%MOCK_HERDR_DIR%\sent"
if exist "%MOCK_HERDR_DIR%\queued" goto stacked
if exist "%MOCK_HERDR_DIR%\pending" del "%MOCK_HERDR_DIR%\pending"
if exist "%MOCK_HERDR_DIR%\fallback" del "%MOCK_HERDR_DIR%\fallback"
exit /b 0
:stacked
del "%MOCK_HERDR_DIR%\queued"
exit /b 0
'@
    [IO.File]::WriteAllText($env:HERDR_BIN_PATH, $mock, [Text.Encoding]::ASCII)
    $script = Join-Path $root 'scripts/approve-windows.ps1'
    Set-Content (Join-Path $tmp 'keys.conf') 'codex=y enter'
    Set-Content (Join-Path $tmp 'pending') ''
    Set-Content (Join-Path $tmp 'queued') ''
    & $script sweep
    if ((Send-Count) -ne 2) { throw 'sweep did not drain stacked prompts' }
    if ((Get-Content (Join-Path $tmp 'sent') | Select-Object -First 1).Trim() -ne 'y enter') { throw 'sweep did not send configured keys' }
    & $script on
    if (-not (Test-Path (Join-Path $tmp 'auto-approve'))) { throw 'on did not create flag' }
    $pidFile = Join-Path $env:HERDR_PLUGIN_STATE_DIR 'monitor.pid'
    Wait-Until { Test-Path $pidFile } 'monitor did not start'
    $workerPid = [int](Get-Content $pidFile)
    # No event is dispatched for any of these prompts, including a prompt whose
    # semantic status stays working. The same worker must handle every wave.
    Set-Content (Join-Path $tmp 'pending') ''
    Wait-Until { (Send-Count) -ge 3 } 'first automatic prompt was missed'
    Wait-Until { -not (Test-Path (Join-Path $tmp 'pending')) } 'first prompt did not settle'
    Set-Content (Join-Path $tmp 'pending') ''
    Wait-Until { (Send-Count) -ge 4 } 'second automatic prompt was missed'
    Wait-Until { -not (Test-Path (Join-Path $tmp 'pending')) } 'second prompt did not settle'
    Set-Content (Join-Path $tmp 'fallback') ''
    Wait-Until { (Send-Count) -ge 5 } 'prompt reported as working was missed'
    & $script startup
    if ([int](Get-Content $pidFile) -ne $workerPid) { throw 'startup replaced an active monitor' }
    & $script off
    if (Test-Path (Join-Path $tmp 'auto-approve')) { throw 'off did not remove flag' }
    Wait-Until { -not (Test-Path $pidFile) } 'monitor did not stop after off'
    $count = Send-Count
    Set-Content (Join-Path $tmp 'pending') ''
    $env:HERDR_PLUGIN_EVENT_JSON = '{"data":{"agent_status":"blocked","pane_id":"pane-1","agent":"codex"}}'
    & $script event
    if ((Send-Count) -ne $count) { throw 'disabled auto mode sent keys' }
    # Restore a persisted ON toggle at startup without calling the ON action.
    Set-Content (Join-Path $tmp 'auto-approve') ''
    & $script startup
    Wait-Until { (Send-Count) -gt $count } 'startup did not restore persisted auto mode'
    Wait-Until { Test-Path $pidFile } 'restored monitor did not write PID'
    $workerPid = [int](Get-Content $pidFile)
    & $script off
    Wait-Until { -not (Test-Path $pidFile) } 'restored monitor did not stop'
    'Windows smoke test passed'
} finally {
    Remove-Item -LiteralPath (Join-Path $tmp 'auto-approve') -Force -ErrorAction SilentlyContinue
    if ($workerPid) {
        # This PID came from the worker spawned with this test's unique config.
        $worker = Get-Process -Id $workerPid -ErrorAction SilentlyContinue
        if ($worker -and $worker.ProcessName -eq 'powershell') { $worker | Stop-Process -Force }
    }
    Remove-Item -LiteralPath $tmp -Recurse -Force
}
