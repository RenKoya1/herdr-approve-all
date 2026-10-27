param([Parameter(Mandatory=$true)][ValidateSet('sweep','on','off','event','startup','monitor')][string]$Mode)
$ErrorActionPreference = 'Stop'
$herdr = if ($env:HERDR_BIN_PATH) { $env:HERDR_BIN_PATH } else { 'herdr' }
$config = $env:HERDR_PLUGIN_CONFIG_DIR
if (-not $config) { throw 'HERDR_PLUGIN_CONFIG_DIR is required' }
$flag = Join-Path $config 'auto-approve'
$state = if ($env:HERDR_PLUGIN_STATE_DIR) { $env:HERDR_PLUGIN_STATE_DIR } else { Join-Path $config 'state' }
$automatic = $Mode -in @('event', 'monitor')

function Invoke-Herdr([string[]]$Arguments) {
    $output = & $herdr @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { throw "herdr command failed: $($Arguments -join ' ')" }
    return ($output -join "`n")
}
function Notify([string]$Message) {
    try { $null = Invoke-Herdr @('notification','show',$Message,'--sound','none') } catch { }
}
function Number-Setting([string]$Name, [double]$Default) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    $parsed = 0.0
    if ($value -and [double]::TryParse($value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and $parsed -ge 0) { return $parsed }
    return $Default
}
function New-PluginMutex([string]$Name) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$config/$Name"))).Replace('-','') } finally { $sha.Dispose() }
    return [Threading.Mutex]::new($false, "Local\herdr-approve-all-$hash")
}
function Lock-Mutex($Mutex, [int]$Timeout = 0) {
    try { return $Mutex.WaitOne($Timeout) } catch [Threading.AbandonedMutexException] { return $true }
}
function Start-Monitor {
    # Probe the same mutex as the worker, rather than trusting a reusable PID.
    $mutex = New-PluginMutex 'monitor'
    $locked = $false
    try {
        $locked = Lock-Mutex $mutex
        if (-not $locked) { return }
    } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
    $null = New-Item -ItemType Directory -Path $state -Force
    $workerArguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" monitor'
    # A detached worker is independent of Herdr's short-lived action/event jobs.
    # It inherits HERDR_BIN_PATH and the socket/named-pipe invocation context.
    $null = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $workerArguments -WindowStyle Hidden
}
function Needs-Approval([string]$Pane) {
    try {
        $status = (Invoke-Herdr @('agent','get',$Pane) | ConvertFrom-Json).result.agent.agent_status
        if ($status -eq 'blocked') { return $true }
        if ($env:APPROVE_SCRAPE_FALLBACK -eq '0') { return $false }
        $screen = Invoke-Herdr @('agent','read',$Pane,'--source','visible','--lines','24')
        $choicePattern = '(?im)^\s*(?:' + [char]0x276f + '\s*)?\d+\.\s|enter to (confirm|select)'
        return ($screen -match '(?i)esc to cancel' -and $screen -match $choicePattern)
    } catch { Write-Warning "Could not inspect pane ${Pane}: $_"; return $false }
}
function Approve-Pane([string]$Pane, [string]$Agent) {
    $mutex = New-PluginMutex "pane/$Pane"
    $locked = $false
    try {
        $locked = Lock-Mutex $mutex
        if (-not $locked) { return '-' }
        $keys = @('enter')
        $keyfile = Join-Path $config 'keys.conf'
        if (Test-Path -LiteralPath $keyfile) {
            foreach ($line in Get-Content -LiteralPath $keyfile) {
                if ($line.StartsWith("$Agent=")) { $keys = @($line.Substring($Agent.Length + 1).Trim() -split '\s+' | Where-Object { $_ }); break }
            }
        }
        $sent = 0
        $max = [int](Number-Setting 'APPROVE_MAX_SENDS' 5)
        while ($sent -lt $max -and (Needs-Approval $Pane) -and $keys.Count -gt 0) {
            if ($automatic -and -not (Test-Path -LiteralPath $flag)) { break }
            try { $null = Invoke-Herdr (@('agent','send-keys',$Pane) + $keys) } catch { break }
            $sent++
            $timeout = [int](Number-Setting 'APPROVE_LEAVE_TIMEOUT_MS' 1200)
            try { $null = Invoke-Herdr @('agent','wait',$Pane,'--until','idle','--until','working','--until','done','--timeout',"$timeout") } catch { }
            Start-Sleep -Milliseconds ([int](1000 * (Number-Setting 'APPROVE_SETTLE_SEC' 0.15)))
        }
        if ($sent -eq 0) { return '-' }
        if (Needs-Approval $Pane) { return '0' }
        return '1'
    } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

switch ($Mode) {
    'on' {
        $null = New-Item -ItemType Directory -Path $config -Force
        $null = New-Item -ItemType File -Path $flag -Force
        Start-Monitor
        Notify 'Auto-approve ON'
    }
    'off' {
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
        Notify 'Auto-approve OFF'
    }
    'event' {
        if (-not (Test-Path -LiteralPath $flag) -or -not $env:HERDR_PLUGIN_EVENT_JSON) { return }
        Start-Monitor
        $eventData = ($env:HERDR_PLUGIN_EVENT_JSON | ConvertFrom-Json).data
        if ($eventData.agent_status -eq 'blocked' -and $eventData.pane_id) { $null = Approve-Pane ([string]$eventData.pane_id) ([string]$eventData.agent) }
    }
    'startup' {
        if (Test-Path -LiteralPath $flag) { Start-Monitor }
    }
    'monitor' {
        $mutex = New-PluginMutex 'monitor'
        $locked = $false
        $pidFile = Join-Path $state 'monitor.pid'
        $logFile = Join-Path $state 'monitor.log'
        try {
            # Allow an exiting worker to release the lock after a rapid OFF/ON.
            $locked = Lock-Mutex $mutex 10000
            if (-not $locked) { return }
            $null = New-Item -ItemType Directory -Path $state -Force
            Set-Content -LiteralPath $pidFile -Value $PID -Encoding ASCII
            while (Test-Path -LiteralPath $flag) {
                try {
                    # Status events are only hints: stacked or misdetected prompts
                    # may never produce another blocked transition.
                    $agents = (Invoke-Herdr @('agent','list') | ConvertFrom-Json).result.agents
                    foreach ($agent in $agents) {
                        if (-not (Test-Path -LiteralPath $flag)) { break }
                        $result = Approve-Pane ([string]$agent.pane_id) ([string]$agent.agent)
                        if ($result -eq '1' -or $result -eq '0') {
                            Set-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) pane=$($agent.pane_id) result=$result"
                        }
                    }
                } catch {
                    # Herdr may be restarting. Keep the persisted toggle and retry.
                    Set-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) $_"
                }
                Start-Sleep -Milliseconds ([Math]::Max(100, [int](1000 * (Number-Setting 'APPROVE_AUTO_POLL_SEC' 1))))
            }
        } finally {
            if ($locked) { Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue; $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    }
    'sweep' {
        $mutex = New-PluginMutex 'sweep'
        $locked = $false
        try {
            try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
            if (-not $locked) { return }
            $agents = (Invoke-Herdr @('agent','list') | ConvertFrom-Json).result.agents
            $approved = 0; $stuck = 0
            foreach ($agent in $agents) {
                $result = Approve-Pane ([string]$agent.pane_id) ([string]$agent.agent)
                if ($result -eq '1') { $approved++ } elseif ($result -eq '0') { $stuck++ }
            }
            if ($approved -or $stuck) { Notify "Approved $approved agents; $stuck still blocked" }
        } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
    }
}
