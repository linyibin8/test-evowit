param(
    [string]$RemoteUser = "gray",
    [string]$RemoteHost = "192.168.0.124",
    [int]$LocalPort = 23081,
    [int]$RemotePort = 23081
)

$ErrorActionPreference = "Stop"

$pattern = "127.0.0.1:$LocalPort`:127.0.0.1:$RemotePort"
$existing = Get-CimInstance Win32_Process |
    Where-Object {
        $_.Name -eq "ssh.exe" -and
        $_.CommandLine -like "*$pattern*"
    }

foreach ($process in $existing) {
    try {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        Write-Host "Stopped existing layout tunnel PID=$($process.ProcessId)"
    } catch {
        Write-Warning "Failed to stop existing tunnel PID=$($process.ProcessId): $($_.Exception.Message)"
    }
}

$arguments = @(
    "-N",
    "-o", "ExitOnForwardFailure=yes",
    "-o", "ServerAliveInterval=30",
    "-o", "ServerAliveCountMax=3",
    "-L", "127.0.0.1:$LocalPort`:127.0.0.1:$RemotePort",
    "$RemoteUser@$RemoteHost"
)

$process = Start-Process -FilePath "ssh" -ArgumentList $arguments -PassThru
Start-Sleep -Seconds 2

if (-not (Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue)) {
    throw "Layout tunnel failed to start on 127.0.0.1:$LocalPort"
}

Write-Host "Layout tunnel started. PID=$($process.Id)"
Write-Host "Health: http://127.0.0.1:$LocalPort/health"
