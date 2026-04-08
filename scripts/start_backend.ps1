$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$backendDir = Join-Path $repoRoot "backend"
$logDir = Join-Path $repoRoot "output"
$stdoutLog = Join-Path $logDir "backend.stdout.log"
$stderrLog = Join-Path $logDir "backend.stderr.log"
$port = 21080

New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$listener = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
if ($listener) {
    $processIds = $listener | Select-Object -ExpandProperty OwningProcess -Unique
    foreach ($processId in $processIds) {
        try {
            Stop-Process -Id $processId -Force -ErrorAction Stop
            Write-Host "Stopped existing process on port $port (PID $processId)."
        } catch {
            Write-Warning "Failed to stop PID $processId on port ${port}: $($_.Exception.Message)"
        }
    }
    Start-Sleep -Seconds 1
}

Push-Location $backendDir
try {
    if (-not (Test-Path ".env")) {
        throw "backend/.env is missing. Copy backend/.env.example and configure OPENAI_API_KEY first."
    }

    npm install
    npm run build

    if (Test-Path $stdoutLog) { Clear-Content $stdoutLog }
    if (Test-Path $stderrLog) { Clear-Content $stderrLog }

    $process = Start-Process -FilePath "node" `
        -ArgumentList "dist/index.js" `
        -WorkingDirectory $backendDir `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog `
        -PassThru

    Write-Host "Backend started. PID=$($process.Id)"
    Write-Host "Health: http://127.0.0.1:$port/health"
    Write-Host "Demo:   http://127.0.0.1:$port/"
    Write-Host "Trace:  http://127.0.0.1:$port/debug.html"
    Write-Host "Logs:   $stdoutLog"
    Write-Host "Errors: $stderrLog"
} finally {
    Pop-Location
}
