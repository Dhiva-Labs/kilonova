# Starts the app and waits for its window and for the wallet folder that the
# Dart start-up code creates through the Rust library. Seeing both proves the
# release build's Dart code ran and loaded kn_ffi.dll on this machine; the
# window alone would only prove the native runner started.
#
#   tools/ci/smoke-windows.ps1 -Exe <path to kilonova.exe>
param([Parameter(Mandatory)][string]$Exe)
$ErrorActionPreference = 'Stop'

# CompanyName and ProductName in windows/runner/Runner.rc give this path.
$dataDir = Join-Path $env:APPDATA 'Dhiva Labs\Kilonova'
if (Test-Path $dataDir) { Remove-Item -Recurse -Force $dataDir }

$p = Start-Process -FilePath $Exe -PassThru
$up = $false
for ($i = 1; $i -le 90; $i++) {
    Start-Sleep -Seconds 1
    $p.Refresh()
    if ($p.HasExited) { throw "$Exe exited early with code $($p.ExitCode)" }
    if ($p.MainWindowHandle -ne 0 -and (Test-Path (Join-Path $dataDir 'wallets'))) {
        "window '$($p.MainWindowTitle)' and $dataDir\wallets are up after ${i}s"
        $up = $true
        break
    }
}
if (-not $up) {
    Stop-Process -Id $p.Id -Force
    throw "no window or wallet folder after 90 s (window handle $($p.MainWindowHandle), folder exists: $(Test-Path (Join-Path $dataDir 'wallets')))"
}
Start-Sleep -Seconds 5
$p.Refresh()
if ($p.HasExited) { throw "$Exe died after showing its window (code $($p.ExitCode))" }
Stop-Process -Id $p.Id -Force
