$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$backendDir = Join-Path $repoRoot "backend"
$logDir = Join-Path $repoRoot "output"
$stdoutLog = Join-Path $logDir "backend.stdout.log"
$stderrLog = Join-Path $logDir "backend.stderr.log"

New-Item -ItemType Directory -Force -Path $logDir | Out-Null

Push-Location $backendDir
try {
    if (-not (Test-Path ".env")) {
        throw "backend/.env is missing. Copy backend/.env.example and configure OPENAI_API_KEY first."
    }

    npm install
    npm run build

    Start-Process -FilePath "node" `
        -ArgumentList "dist/index.js" `
        -WorkingDirectory $backendDir `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog
} finally {
    Pop-Location
}
