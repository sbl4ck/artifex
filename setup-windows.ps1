<#
.SYNOPSIS
  Installs ARTIFEX on Windows, ready to use, with a local AI model (no API key needed).

.DESCRIPTION
  ARTIFEX's agents run Linux shell commands, so on Windows it runs inside WSL2 (a Linux
  environment built into Windows). This script:

    1. Installs WSL2 if needed (asks for administrator rights once; may need a restart,
       after which setup continues by itself when you sign in).
    2. Creates a separate Linux environment named "ARTIFEX" that is locked down: it cannot
       see your Windows drives and cannot start Windows programs, so the agents' commands
       stay inside it.
    3. Copies this folder into it and runs setup.sh there, which installs PostgreSQL,
       Ollama with a local model, the agents' tools, builds ARTIFEX, sets the admin
       password and connects the model.
    4. Starts ARTIFEX now and every time you sign in to Windows, and puts an "ARTIFEX"
       shortcut on your desktop.

  When it finishes, open http://127.0.0.1:8787 and sign in. The password is shown at the
  end and saved in %LOCALAPPDATA%\ARTIFEX\credentials.txt.

.EXAMPLE
  .\setup-windows.cmd
  Install with the default local model (qwen3:8b).

.EXAMPLE
  .\setup-windows.cmd -Model qwen3:14b
  Use a larger local model (better agent, needs about 10 GB of free memory).

.EXAMPLE
  .\setup-windows.cmd -Status
  .\setup-windows.cmd -Stop
  .\setup-windows.cmd -Start
  .\setup-windows.cmd -Logs
  .\setup-windows.cmd -Uninstall
#>
[CmdletBinding()]
param(
  # Ollama model to download and use. Bigger is smarter but needs more memory.
  [string]$Model = 'qwen3:8b',
  # Context window in tokens given to the model.
  [int]$Context = 32768,
  # Admin password for the console (default: generated).
  [string]$AdminPassword = '',
  # Optional: use a cloud model instead of a local one.
  [string]$AnthropicKey = '',
  [string]$OpenAIKey = '',
  # Don't start ARTIFEX when you sign in to Windows.
  [switch]$NoAutostart,
  # Don't open the browser at the end.
  [switch]$NoBrowser,
  # Management actions for an existing install.
  [switch]$Status,
  [switch]$Start,
  [switch]$Stop,
  [switch]$Logs,
  [switch]$Uninstall,
  # Internal: set when setup resumes after the restart that installing WSL may need.
  [switch]$Resumed
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Distro      = 'ARTIFEX'
$LinuxUser   = 'artifex'
$AppDir      = "/home/$LinuxUser/artifex"
$Url         = 'http://127.0.0.1:8787'
$RepoDir     = $PSScriptRoot
$DataRoot    = Join-Path $env:LOCALAPPDATA 'ARTIFEX'
$CredFile    = Join-Path $DataRoot 'credentials.txt'
$StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'ARTIFEX.lnk'
$DesktopLink = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ARTIFEX.url'

# wsl.exe prints UTF-16 unless told otherwise.
$env:WSL_UTF8 = '1'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

function Info([string]$m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Step([string]$m) { Write-Host ''; Write-Host "== $m ==" -ForegroundColor White }
function Fail([string]$m) {
  Write-Host "[x] $m" -ForegroundColor Red
  if ($Resumed) { Read-Host 'Press Enter to close' | Out-Null }
  exit 1
}

# Run a native command silently and return its exit code. PowerShell 5.1 turns redirected
# stderr from native programs into terminating errors when ErrorActionPreference is Stop.
function Quiet {
  $exe = $args[0]; $rest = @($args | Select-Object -Skip 1)
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { & $exe @rest *> $null } finally { $ErrorActionPreference = $old }
  return $LASTEXITCODE
}

# Quote a value for a bash single-quoted string.
function ShQuote([string]$s) { return "'" + $s.Replace("'", "'\''") + "'" }

# Run a bash script inside the distro and return its exit code. The script goes through a
# temp file with Unix line endings and cmd.exe redirection, which passes bytes unchanged
# (PowerShell 5 pipes don't). Output goes to the screen, or nowhere with -Silent; it must not
# reach the function's output, or callers would get it mixed into the exit code.
function Invoke-WslScript([string]$User, [string]$Script, [switch]$Silent) {
  $tmp = [IO.Path]::GetTempFileName()
  try {
    $text = "set -euo pipefail`n" + ($Script -replace "`r`n", "`n")
    [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding $false))
    $cmd = "wsl.exe -d $Distro -u $User --cd ~ -- bash -s < `"$tmp`""
    if ($Silent) { & cmd.exe /d /c "$cmd >nul 2>&1" } else { & cmd.exe /d /c $cmd | Out-Host }
    return $LASTEXITCODE
  } finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  }
}

function Test-Console {
  try {
    $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 -Uri "$Url/api/health"
    return ($r.Content -match '"ok":\s*true')
  } catch { return $false }
}

function Test-DistroExists {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $names = & wsl.exe -l -q 2>$null } finally { $ErrorActionPreference = $old }
  if ($LASTEXITCODE -ne 0 -or -not $names) { return $false }
  foreach ($n in $names) { if ($n.Trim([char]0, ' ') -eq $Distro) { return $true } }
  return $false
}

function Start-Artifex {
  # A hidden wsl.exe keeps the Linux environment running; setup.sh run supervises the app.
  Start-Process -FilePath 'wsl.exe' -WindowStyle Hidden `
    -ArgumentList @('-d', $Distro, '-u', $LinuxUser, '--cd', $AppDir, '--', './setup.sh', 'run')
}

function Wait-Console([int]$Seconds = 180) {
  Info "Waiting for ARTIFEX at $Url"
  for ($i = 0; $i -lt $Seconds; $i++) {
    if (Test-Console) { Ok 'ARTIFEX is up'; return $true }
    Start-Sleep -Seconds 1
  }
  return $false
}

function Stop-Artifex {
  if (Test-DistroExists) {
    Invoke-WslScript $LinuxUser "cd $AppDir && ./setup.sh stop || true" -Silent | Out-Null
    & wsl.exe --terminate $Distro | Out-Null
  }
}

# --- management actions ---
if ($Status -or $Start -or $Stop -or $Logs -or $Uninstall) {
  if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue) -or -not (Test-DistroExists)) {
    Fail "ARTIFEX is not installed. Run setup-windows.cmd first."
  }
  if ($Status) {
    if (Test-Console) { Ok "Running at $Url" } else { Warn "Not answering at $Url"; exit 1 }
  }
  elseif ($Start) {
    if (Test-Console) { Ok "Already running at $Url" }
    else { Start-Artifex; if (-not (Wait-Console)) { Fail 'ARTIFEX did not start. See: setup-windows.cmd -Logs' } }
  }
  elseif ($Stop) {
    Stop-Artifex
    Ok 'Stopped (the Linux environment was shut down to free memory)'
  }
  elseif ($Logs) {
    Invoke-WslScript $LinuxUser "cd $AppDir && ./setup.sh logs" | Out-Null
  }
  elseif ($Uninstall) {
    Write-Host 'This deletes the ARTIFEX Linux environment with its database, findings, models and settings.'
    if ((Read-Host 'Type yes to continue') -ne 'yes') { Write-Host 'Cancelled.'; exit 0 }
    Stop-Artifex
    & wsl.exe --unregister $Distro | Out-Null
    Remove-Item $StartupLink, $DesktopLink -Force -ErrorAction SilentlyContinue
    Remove-Item $DataRoot -Recurse -Force -ErrorAction SilentlyContinue
    Ok 'ARTIFEX was removed. WSL itself was left installed.'
  }
  exit 0
}

# --- install ---
Write-Host 'ARTIFEX setup for Windows' -ForegroundColor White
Write-Host 'ARTIFEX runs AI agents that execute commands. They run inside a separate, locked-down'
Write-Host 'Linux environment. Only test systems you own or are authorized to test.'

Step 'Checking this PC'
$build = [Environment]::OSVersion.Version.Build
if (-not [Environment]::Is64BitOperatingSystem) { Fail 'A 64-bit Windows is required.' }
if ($build -lt 19041) { Fail "Windows 10 version 2004 (build 19041) or newer is required; this PC has build $build. Run Windows Update first." }
Ok "Windows build $build"

$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
Ok "$ramGB GB of memory"
if ($AnthropicKey -eq '' -and $OpenAIKey -eq '') {
  # WSL gets half of the PC's memory by default.
  if ($ramGB -lt 12) {
    Warn "Local models need memory. With $ramGB GB, use a small model: -Model qwen3:4b (or qwen3:1.7b)."
  } elseif ($ramGB -lt 16 -and $Model -eq 'qwen3:8b') {
    Warn "With $ramGB GB, qwen3:8b will be tight. If it fails to load, re-run with -Model qwen3:4b."
  }
  $gpus = @(Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name })
  if ($gpus -match 'NVIDIA') {
    Ok "NVIDIA GPU found ($($gpus -match 'NVIDIA' | Select-Object -First 1)). Ollama uses it if the driver is current."
  } else {
    Warn 'No NVIDIA GPU found, so the model runs on the CPU. That works, but agents will be slow.'
  }
}
if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) { Fail 'tar.exe is missing (it ships with Windows 10 1803 and later).' }
if (-not (Test-Path (Join-Path $RepoDir 'setup.sh'))) { Fail "Run this script from the ARTIFEX folder (setup.sh not found in $RepoDir)." }

Step 'WSL'
$wslReady = $false
if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
  $wslReady = ((Quiet wsl.exe --version) -eq 0)
}
if (-not $wslReady) {
  Info 'Installing WSL. Windows will ask for administrator permission.'
  try {
    Start-Process -FilePath 'wsl.exe' -ArgumentList @('--install', '--no-distribution') -Verb RunAs -Wait | Out-Null
  } catch {
    Fail 'Administrator permission is needed once to install WSL. Run setup-windows.cmd again and choose Yes.'
  }
  if ((Quiet wsl.exe --version) -ne 0) {
    # Continue automatically after the restart, without any secrets on the command line.
    $resume = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Resumed -Model `"$Model`" -Context $Context"
    if ($NoAutostart) { $resume += ' -NoAutostart' }
    if ($NoBrowser) { $resume += ' -NoBrowser' }
    New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'ARTIFEX setup' -Value $resume
    Warn 'WSL is installed but Windows needs a restart to finish.'
    Warn 'Restart now. Setup continues by itself when you sign in again.'
    if ($AnthropicKey -or $OpenAIKey -or $AdminPassword) {
      Warn 'Keys and passwords you passed are not saved across the restart; add them in the console later.'
    }
    if ((Read-Host 'Restart now? (y/n)') -eq 'y') { Restart-Computer -Force }
    exit 0
  }
}
Quiet wsl.exe --update | Out-Null   # newer WSL is needed for named installs; harmless if current
Quiet wsl.exe --set-default-version 2 | Out-Null
Ok 'WSL2 is ready'

Step 'Linux environment'
if (Test-DistroExists) {
  Ok "Reusing the existing '$Distro' environment (re-running updates it)"
} else {
  Info "Creating the '$Distro' environment (Ubuntu 24.04, about 1 GB)"
  New-Item -ItemType Directory -Force -Path (Join-Path $DataRoot 'wsl') | Out-Null
  & wsl.exe --install Ubuntu-24.04 --name $Distro --location (Join-Path $DataRoot 'wsl') --no-launch
  if ($LASTEXITCODE -ne 0) {
    Info 'Retrying with a direct download instead of the Microsoft Store'
    & wsl.exe --install Ubuntu-24.04 --name $Distro --location (Join-Path $DataRoot 'wsl') --no-launch --web-download
  }
  if (-not (Test-DistroExists)) {
    Fail "Could not create the Linux environment. Run 'wsl --update' and try again."
  }
  Ok "Created '$Distro'"
}

Info 'Configuring it: dedicated user, no access to Windows drives or programs, systemd on'
$rc = Invoke-WslScript 'root' @"
id -u $LinuxUser >/dev/null 2>&1 || useradd -m -s /bin/bash $LinuxUser
cat > /etc/wsl.conf <<'EOF'
# Written by ARTIFEX setup. Keeps the agents' commands inside this environment.
[boot]
systemd=true
[automount]
enabled=false
mountFsTab=false
[interop]
enabled=false
appendWindowsPath=false
[user]
default=$LinuxUser
EOF
mkdir -p $AppDir && chown ${LinuxUser}: $AppDir
"@
if ($rc -ne 0) { Fail 'Could not configure the Linux environment.' }
& wsl.exe --terminate $Distro | Out-Null   # restart it so the settings apply
Invoke-WslScript 'root' 'systemctl is-system-running --wait >/dev/null 2>&1 || true' -Silent | Out-Null
Ok 'Linux environment configured'

Step 'Copying ARTIFEX into it'
# tar streams the folder over stdin, so no Windows drive has to be mounted inside.
$excludes = @('node_modules', '.next', '.toolchain', '.artifex', './data', './artifex', './artifex.exe',
              './config.json', './server/webui/dist', './web/out', './dist') |
            ForEach-Object { "--exclude=`"$_`"" }
& cmd.exe /d /c "tar.exe -cf - $($excludes -join ' ') -C `"$RepoDir`" . | wsl.exe -d $Distro -u $LinuxUser --cd ~ -- tar --warning=no-unknown-keyword -xf - -C $AppDir"
if ($LASTEXITCODE -ne 0) { Fail 'Copying the files failed.' }
$rc = Invoke-WslScript $LinuxUser @"
cd $AppDir
# Windows checkouts can lose exec bits or gain CRLF line endings on shell scripts.
find . -path ./web/node_modules -prune -o -name '*.sh' -type f -print0 | xargs -0 sed -i 's/\r$//'
find . -path ./web/node_modules -prune -o -name '*.sh' -type f -print0 | xargs -0 chmod +x
"@
if ($rc -ne 0) { Fail 'Preparing the copied files failed.' }
Ok "Copied to $AppDir"

Step 'Running setup inside Linux (builds everything; 10-30 minutes the first time)'
$setupArgs = @('-y', '--mode', 'native', '--db', 'system', '--no-service', '--with-tools')
if ($AnthropicKey) { $setupArgs += @('--anthropic-key', $AnthropicKey) }
elseif ($OpenAIKey) { $setupArgs += @('--openai-key', $OpenAIKey) }
else { $setupArgs += @('--local-model', $Model, '--local-context', "$Context") }
if ($AdminPassword) { $setupArgs += @('--admin-password', $AdminPassword) }
$quoted = ($setupArgs | ForEach-Object { ShQuote $_ }) -join ' '
# setup.sh needs root for packages and services; grant it to the dedicated user only for
# the duration of setup, then take it away again.
Invoke-WslScript 'root' @"
echo '$LinuxUser ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/artifex-setup
chmod 440 /etc/sudoers.d/artifex-setup
"@ -Silent | Out-Null
try {
  $rc = Invoke-WslScript $LinuxUser "cd $AppDir && ./setup.sh $quoted"
} finally {
  Invoke-WslScript 'root' 'rm -f /etc/sudoers.d/artifex-setup' -Silent | Out-Null
}
if ($rc -ne 0) { Fail 'setup.sh failed; see the messages above. Fix the cause and run setup-windows.cmd again.' }
# setup.sh started a temporary instance; hand over to the Windows-managed one.
Invoke-WslScript $LinuxUser "cd $AppDir && ./setup.sh stop" -Silent | Out-Null

Step 'Starting ARTIFEX'
New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
$cred = (& wsl.exe -d $Distro -u $LinuxUser --cd ~ -- cat "$AppDir/.artifex/credentials") -join "`r`n"
if ($cred) { Set-Content -Path $CredFile -Value $cred -Encoding UTF8 }

if (-not $NoAutostart) {
  $shell = New-Object -ComObject WScript.Shell
  $lnk = $shell.CreateShortcut($StartupLink)
  $lnk.TargetPath = 'powershell.exe'
  $lnk.Arguments = "-NoProfile -WindowStyle Hidden -Command `"Start-Process wsl.exe -WindowStyle Hidden -ArgumentList '-d','$Distro','-u','$LinuxUser','--cd','$AppDir','--','./setup.sh','run'`""
  $lnk.WindowStyle = 7
  $lnk.Description = 'Starts ARTIFEX when you sign in'
  $lnk.Save()
  Ok 'ARTIFEX will start when you sign in to Windows'
}
Set-Content -Path $DesktopLink -Value "[InternetShortcut]`r`nURL=$Url/`r`n" -Encoding ASCII
Ok 'Added an ARTIFEX shortcut to the desktop'

Start-Artifex
if (-not (Wait-Console)) { Fail 'ARTIFEX did not start. See: setup-windows.cmd -Logs' }

Write-Host ''
Write-Host 'ARTIFEX is ready.' -ForegroundColor Green
Write-Host ''
Write-Host "  Console    $Url  (desktop shortcut: ARTIFEX)"
if ($cred) {
  Write-Host ($cred -split "`r`n" | Select-Object -Skip 1 | ForEach-Object { "  $_" } | Out-String).TrimEnd()
  Write-Host "  Saved in   $CredFile"
}
Write-Host ''
Write-Host '  Manage it: setup-windows.cmd -Status | -Stop | -Start | -Logs | -Uninstall'
Write-Host '  Next: sign in, set an asset scope, and create a task. See docs\local-guide.md.'
Write-Host '  Only test systems you own or are authorized to test.'
Write-Host ''
if (-not $NoBrowser) { Start-Process $Url }
if ($Resumed) { Read-Host 'Press Enter to close' | Out-Null }
