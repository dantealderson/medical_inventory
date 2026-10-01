# Puts this PC's server online for testing, free: the database (Docker), the
# server with the admin website at "/", and an ngrok tunnel to your fixed
# ngrok address. Close the window (or press Ctrl+C) to go offline.
#
# It uses its own database, medinv_online, filled with the demo data, so the
# development database is never touched. Settings asked on the first run are
# kept in online.local.json at the repository root (not committed).
#
#   start-online.cmd              everything
#   start-online.cmd -NoTunnel    the server only, at http://localhost:3000
param([switch]$NoTunnel)

$ErrorActionPreference = 'Continue'
$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
$backend = Join-Path $repo 'backend'
$admin = Join-Path $repo 'admin'
$configPath = Join-Path $repo 'online.local.json'
$logPath = Join-Path $repo 'online-server.log'
$ngrok = Join-Path $env:LOCALAPPDATA 'ngrok\ngrok.exe'
$ngrokConfig = Join-Path $env:LOCALAPPDATA 'ngrok\ngrok.yml'
$dockerBin = Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\resources\bin'
if (Test-Path $dockerBin) { $env:Path = "$dockerBin;$env:Path" }

function Say($text) { Write-Host ''; Write-Host "== $text" -ForegroundColor Cyan }
function Fail($text) { Write-Host ''; Write-Host "!! $text" -ForegroundColor Red; exit 1 }
function Must($what) { if ($LASTEXITCODE -ne 0) { Fail "$what failed (exit code $LASTEXITCODE)." } }

# --- Settings, asked once -------------------------------------------------
$cfg = if (Test-Path $configPath) { Get-Content $configPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
foreach ($name in 'domain', 'demoPassword', 'firebaseKey') {
  if (-not ($cfg.PSObject.Properties.Name -contains $name)) { $cfg | Add-Member $name '' }
}
if (-not $NoTunnel -and -not $cfg.domain) {
  $cfg.domain = ((Read-Host 'Your ngrok domain, from the ngrok dashboard (e.g. xxxx.ngrok-free.dev)').Trim() -replace '^https?://', '' -replace '/.*$', '')
}
while ($cfg.demoPassword.Length -lt 8) {
  $cfg.demoPassword = (Read-Host 'A password for the demo clinics (at least 8 characters)').Trim()
}
# The Firebase key: the newest one in Downloads, unless one was set already.
if (-not $cfg.firebaseKey -or -not (Test-Path $cfg.firebaseKey)) {
  $found = Get-ChildItem (Join-Path $env:USERPROFILE 'Downloads') -Filter '*firebase-adminsdk*.json' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $cfg.firebaseKey = if ($found) { $found.FullName } else { '' }
}
$cfg | ConvertTo-Json | Set-Content -Encoding UTF8 $configPath

if (-not $NoTunnel) {
  if (-not (Test-Path $ngrok)) { Fail "ngrok is not installed at $ngrok." }
  if (-not ((Test-Path $ngrokConfig) -and (Select-String -Path $ngrokConfig -Pattern 'authtoken' -Quiet))) {
    Fail ("ngrok has no authtoken yet. Copy the command from the ngrok dashboard ('Your Authtoken') " +
      "and run it in a Command Prompt, using `"$ngrok`" in place of 'ngrok'. Then start this again.")
  }
}

# --- The database ---------------------------------------------------------
Say 'Starting the database (Docker)'
docker info *> $null
if ($LASTEXITCODE -ne 0) {
  $desktop = Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\Docker Desktop.exe'
  if (Test-Path $desktop) { Start-Process $desktop }
  Write-Host 'Waiting for Docker Desktop to start...'
  for ($i = 0; $i -lt 60; $i++) { Start-Sleep 3; docker info *> $null; if ($LASTEXITCODE -eq 0) { break } }
  docker info *> $null; Must 'Starting Docker'
}
docker compose -f (Join-Path $repo 'docker-compose.yml') up -d; Must 'Starting the database container'
for ($i = 0; $i -lt 40; $i++) {
  if ((docker inspect -f '{{.State.Health.Status}}' medinv_postgres) -eq 'healthy') { break }
  Start-Sleep 2
}
$exists = docker exec medinv_postgres psql -U medinv -d medinv -tAc "SELECT 1 FROM pg_database WHERE datname='medinv_online'"
if ("$exists".Trim() -ne '1') {
  docker exec medinv_postgres createdb -U medinv medinv_online; Must 'Creating the medinv_online database'
}

# --- The server's settings: backend\.env, with these on top --------------
$env:DATABASE_URL = 'postgresql://medinv:medinv_dev@localhost:5433/medinv_online?schema=public'
$env:NODE_ENV = 'production'
$env:PORT = '3000'
$env:CORS_ORIGINS = 'https://dantealderson.github.io'
$env:ADMIN_WEB_DIR = Join-Path $admin 'build\web'
$env:DEMO_CLINIC_PASSWORD = $cfg.demoPassword
$env:JOBS_ENABLED = 'true'
if ($cfg.firebaseKey) {
  $env:FIREBASE_SERVICE_ACCOUNT_JSON = (Get-Content $cfg.firebaseKey -Raw).Trim()
  Write-Host "Push notifications: on ($($cfg.firebaseKey))"
} else {
  Write-Host 'Push notifications: off (no Firebase key found in Downloads)'
}

# --- Build and prepare ----------------------------------------------------
Push-Location $backend
Say 'Updating the database'
npx prisma migrate deploy; Must 'Updating the database'
npm run db:seed; Must 'Creating the admin account'
Say 'Building the server'
npm run build; Must 'Building the server'
node dist/demo/seed-demo.js
if ($LASTEXITCODE -ne 0) { Write-Host 'Demo data already there.' }
Pop-Location

# The admin website: rebuilt only when its code is newer than the last build.
$builtJs = Join-Path $admin 'build\web\main.dart.js'
$sources = @(Join-Path $admin 'lib') + (Get-ChildItem (Join-Path $repo 'packages') -Directory | ForEach-Object { Join-Path $_.FullName 'lib' })
$newest = Get-ChildItem $sources -Recurse -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not (Test-Path $builtJs) -or $newest.LastWriteTime -gt (Get-Item $builtJs).LastWriteTime) {
  Say 'Building the admin website (a minute or two)'
  Push-Location $admin
  flutter build web --release --dart-define=API_BASE_URL=same-origin; Must 'Building the admin website'
  Pop-Location
}

# --- Run ------------------------------------------------------------------
if (Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue) {
  Fail 'Something is already using port 3000 (a development server?). Stop it and start this again.'
}
Say 'Starting the server'
$server = Start-Process node -ArgumentList 'dist/main' -WorkingDirectory $backend -NoNewWindow -PassThru `
  -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.err"
$up = $false
for ($i = 0; $i -lt 60; $i++) {
  Start-Sleep 1
  try { if ((Invoke-WebRequest 'http://localhost:3000/api/v1/health' -UseBasicParsing -TimeoutSec 3).StatusCode -eq 200) { $up = $true; break } } catch {}
  if ($server.HasExited) { break }
}
if (-not $up) { Get-Content "$logPath.err" -Tail 20; Fail "The server did not start. Its messages are in $logPath and $logPath.err." }

try {
  if ($NoTunnel) {
    Say 'Running at http://localhost:3000 (admin website) - press Ctrl+C to stop'
    Wait-Process -Id $server.Id
  } else {
    Say "ONLINE - admin website: https://$($cfg.domain)/   app: https://$($cfg.domain)/api/v1"
    Write-Host 'Keep this window open while testing. Close it to go offline.' -ForegroundColor Yellow
    & $ngrok http 3000 --url="https://$($cfg.domain)" --log=stdout --log-level=warn
  }
} finally {
  if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force }
}
