# Runs the client app on an Android phone plugged in by USB, on any network.
#
# The phone reaches the backend on this PC through the cable ("adb reverse"),
# so it can stay on mobile data. The forwarding drops when the cable is
# re-plugged or adb restarts, so a background loop puts it back every few
# seconds for as long as the app runs.
#
# Start it with run-on-phone.cmd (double-click, or from any terminal).
# Extra arguments go to "flutter run", for example: run-on-phone.cmd -d <device-id>

$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (-not (Test-Path $adb)) {
  Write-Host "adb was not found at $adb. Install the Android SDK platform-tools from Android Studio."
  exit 1
}

$keeper = Start-Job -ArgumentList $adb -ScriptBlock {
  param($adb)
  while ($true) {
    $forwarded = & $adb reverse --list 2>$null
    if (-not ($forwarded -match 'tcp:3000')) {
      & $adb reverse tcp:3000 tcp:3000 2>$null | Out-Null
    }
    Start-Sleep -Seconds 3
  }
}

try {
  Set-Location (Split-Path $PSScriptRoot -Parent)
  flutter run --dart-define=API_BASE_URL=http://127.0.0.1:3000/api/v1 @args
  $code = $LASTEXITCODE
} finally {
  Stop-Job $keeper
  Remove-Job $keeper
}
exit $code
