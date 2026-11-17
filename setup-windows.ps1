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
    3. Sets up the local model with Ollama, where your GPU can use it:
         - NVIDIA: Ollama runs inside WSL, which reaches NVIDIA GPUs through the driver.
         - AMD Radeon or Intel Arc: Ollama runs on Windows (WSL can't use these GPUs), and
           WSL is switched to "mirrored" networking so ARTIFEX reaches it at 127.0.0.1.
         - No GPU: Ollama runs inside WSL on the CPU.
       With 16 GB or more of video memory it picks qwen3:14b, otherwise qwen3:8b.
    4. Copies this folder into the Linux environment and runs setup.sh there, which
       installs PostgreSQL, the agents' tools, builds ARTIFEX, sets the admin password
       and connects the model.
    5. Starts ARTIFEX now and every time you sign in to Windows, and puts an "ARTIFEX"
       shortcut on your desktop.

  When it finishes, open http://127.0.0.1:8787 and sign in. The password is shown at the
  end and saved in %LOCALAPPDATA%\ARTIFEX\credentials.txt.

.EXAMPLE
  .\setup-windows.cmd
  Install with a local model chosen for this PC's GPU.

.EXAMPLE
  .\setup-windows.cmd -Model qwen3:8b
  Choose the model yourself (smaller is faster, bigger is a better agent).

.EXAMPLE
  .\setup-windows.cmd -Status
  .\setup-windows.cmd -Stop
  .\setup-windows.cmd -Start
  .\setup-windows.cmd -Logs
  .\setup-windows.cmd -Uninstall
#>
[CmdletBinding()]
param(
  # Ollama model to download and use. Default: chosen from the GPU's video memory.
  [string]$Model = 'qwen3:8b',
  # Where Ollama runs. Auto: Windows for AMD/Intel GPUs, inside WSL otherwise.
  [ValidateSet('Auto', 'Windows', 'Wsl')]
  [string]$OllamaLocation = 'Auto',
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
$OllamaUrl   = 'http://127.0.0.1:11434'
$OllamaDir   = Join-Path $env:LOCALAPPDATA 'Programs\Ollama'
$WslConfig   = Join-Path $env:USERPROFILE '.wslconfig'
$WinOllamaMarker = Join-Path $DataRoot 'uses-windows-ollama'
$LogFile     = Join-Path $DataRoot 'setup.log'

# Any unexpected error: say what and where, point at the log, and keep the window readable.
trap {
  Write-Host ''
  Write-Host '[x] Setup stopped on an unexpected error:' -ForegroundColor Red
  Write-Host "    $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "    (setup-windows.ps1 line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim()))" -ForegroundColor Red
  Write-Host "    Full log: $LogFile"
  try { Stop-Transcript | Out-Null } catch { }
  if ($Resumed) { Read-Host 'Press Enter to close' | Out-Null }
  exit 1
}

# wsl.exe prints UTF-16 unless told otherwise.
$env:WSL_UTF8 = '1'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

function Info([string]$m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Step([string]$m) { Write-Host ''; Write-Host "== $m ==" -ForegroundColor White }
function Fail([string]$m) {
  Write-Host "[x] $m" -ForegroundColor Red
  Write-Host "    Full log: $LogFile"
  try { Stop-Transcript | Out-Null } catch { }
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

# Largest real GPU, with its true video memory. Win32_VideoController caps memory at 4 GB,
# so read the driver's 64-bit value from the registry instead.
function Get-Gpu {
  $found = @()
  $class = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
  foreach ($key in @(Get-ChildItem $class -ErrorAction SilentlyContinue)) {
    if ($key.PSChildName -notmatch '^\d{4}$') { continue }
    $p = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
    if (-not $p -or -not $p.PSObject.Properties['DriverDesc']) { continue }
    $name = [string]$p.DriverDesc
    if ($name -notmatch 'NVIDIA|AMD|Radeon|Intel\(R\) Arc') { continue }
    $bytes = 0
    try {
      $v = $p.'HardwareInformation.qwMemorySize'
      if ($v -is [byte[]]) { $bytes = [BitConverter]::ToInt64($v, 0) } else { $bytes = [int64]$v }
    } catch { }
    $found += New-Object PSObject -Property @{ Name = $name; VramGB = [math]::Round($bytes / 1GB) }
  }
  return ($found | Sort-Object VramGB -Descending | Select-Object -First 1)
}

function Test-Ollama {
  try { Invoke-RestMethod -Uri "$OllamaUrl/api/version" -TimeoutSec 3 | Out-Null; return $true }
  catch { return $false }
}

function Get-OllamaExe {
  $exe = Join-Path $OllamaDir 'ollama.exe'
  if (Test-Path $exe) { return $exe }
  $cmd = Get-Command ollama.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Start-WindowsOllama {
  if (Test-Ollama) { return }
  $exe = Get-OllamaExe
  if (-not $exe) { return }
  # The server only, hidden. The Ollama app also starts it by itself when you sign in.
  Start-Process -FilePath $exe -ArgumentList 'serve' -WindowStyle Hidden
  for ($i = 0; $i -lt 60; $i++) { if (Test-Ollama) { return }; Start-Sleep -Seconds 1 }
}

function Install-WindowsOllama {
  if (-not (Get-OllamaExe)) {
    Info 'Installing Ollama for Windows'
    $installed = $false
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
      $installed = ((Quiet winget.exe install --id Ollama.Ollama -e --silent --accept-package-agreements --accept-source-agreements) -eq 0)
    }
    if (-not $installed -or -not (Get-OllamaExe)) {
      $setup = Join-Path $env:TEMP 'OllamaSetup.exe'
      $oldPP = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
      try { Invoke-WebRequest -UseBasicParsing -Uri 'https://ollama.com/download/OllamaSetup.exe' -OutFile $setup }
      finally { $ProgressPreference = $oldPP }
      $sig = Get-AuthenticodeSignature $setup
      if ($sig.Status -ne 'Valid') { Fail "The downloaded Ollama installer has no valid signature ($($sig.Status)); not running it." }
      Info "Installer signed by: $($sig.SignerCertificate.Subject)"
      Start-Process -FilePath $setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait
      Remove-Item $setup -Force -ErrorAction SilentlyContinue
    }
    if (-not (Get-OllamaExe)) { Fail 'Ollama for Windows did not install. Install it from https://ollama.com/download and run setup again.' }
    Ok 'Ollama for Windows installed'
    # The installer opens Ollama's own window, which looks like setup has finished. Close it;
    # the server is started hidden below, and the Ollama app comes back by itself at sign-in.
    Start-Sleep -Seconds 3
    Stop-Process -Name 'ollama app', 'ollama' -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
  } else {
    Ok 'Ollama for Windows is already installed'
  }
  Start-WindowsOllama
  if (-not (Test-Ollama)) { Fail "Ollama for Windows is installed but not answering at $OllamaUrl." }
}

function Restart-WindowsOllama {
  Stop-Process -Name 'ollama app', 'ollama' -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  Start-WindowsOllama
}

# Mirrored networking shares 127.0.0.1 between Windows and WSL, so ARTIFEX inside WSL can
# reach Ollama on Windows without Ollama listening on the network. Returns $true if changed.
function Enable-MirroredNetworking {
  $lines = @()
  if (Test-Path $WslConfig) { $lines = @(Get-Content $WslConfig) }
  if (@($lines | Where-Object { $_ -match '^\s*networkingMode\s*=\s*mirrored\s*$' }).Count -gt 0) { return $false }
  $out = New-Object System.Collections.Generic.List[string]
  $inWsl2 = $false; $written = $false; $hasSection = $false
  foreach ($l in $lines) {
    if ($l -match '^\s*\[(.+)\]\s*$') {
      if ($inWsl2 -and -not $written) { $out.Add('networkingMode=mirrored'); $written = $true }
      $inWsl2 = ($Matches[1].Trim() -ieq 'wsl2')
      if ($inWsl2) { $hasSection = $true }
      $out.Add($l); continue
    }
    if ($inWsl2 -and $l -match '^\s*networkingMode\s*=') {
      if (-not $written) { $out.Add('networkingMode=mirrored'); $written = $true }
      continue
    }
    $out.Add($l)
  }
  if ($inWsl2 -and -not $written) { $out.Add('networkingMode=mirrored'); $written = $true }
  if (-not $hasSection) { $out.Add(''); $out.Add('[wsl2]'); $out.Add('networkingMode=mirrored') }
  if (Test-Path $WslConfig) { Copy-Item $WslConfig "$WslConfig.artifex-backup" -Force }
  [IO.File]::WriteAllLines($WslConfig, $out.ToArray(), (New-Object Text.UTF8Encoding $false))
  return $true
}

# Share of the loaded ARTIFEX model that sits in video memory (0-100), or -1 if unknown.
function Get-OllamaGpuShare {
  try {
    $ps = Invoke-RestMethod -Uri "$OllamaUrl/api/ps" -TimeoutSec 5
    $m = @($ps.models | Where-Object { $_.name -like 'artifex-*' }) | Select-Object -First 1
    if (-not $m -or -not $m.size) { return -1 }
    return [int](100 * $m.size_vram / $m.size)
  } catch { return -1 }
}

function Invoke-OllamaWarmup {
  try {
    $tags = Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -TimeoutSec 10
    $name = @($tags.models | Where-Object { $_.name -like 'artifex-*' } | ForEach-Object { $_.name }) | Select-Object -First 1
    if (-not $name) { return }
    $body = @{ model = $name; prompt = ''; keep_alive = '30m' } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Uri "$OllamaUrl/api/generate" -Body $body -ContentType 'application/json' -TimeoutSec 600 | Out-Null
  } catch { }
}

# Ask for a restart and continue setup automatically at the next sign-in. Secrets passed on
# the command line are deliberately not stored in the registry.
function Request-RestartAndResume([string]$Why) {
  $resume = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Resumed -Model `"$Model`" -Context $Context"
  $resume += " -OllamaLocation $OllamaLocation"
  if ($NoAutostart) { $resume += ' -NoAutostart' }
  if ($NoBrowser) { $resume += ' -NoBrowser' }
  New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
  Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'ARTIFEX setup' -Value $resume
  Write-Host ''
  Warn $Why
  Warn 'Restart Windows now. Setup continues by itself when you sign in again.'
  if ($AnthropicKey -or $OpenAIKey -or $AdminPassword) {
    Warn 'Keys and passwords you passed are not kept across the restart; add them in the console later.'
  }
  try { Stop-Transcript | Out-Null } catch { }
  if ((Read-Host 'Restart now? (y/n)') -eq 'y') { Restart-Computer -Force }
  exit 0
}

# Create the distro from Ubuntu's official WSL image, checksum-verified. Returns $true on success.
function New-DistroFromImage([string]$Dir) {
  $base = 'https://cloud-images.ubuntu.com/wsl/releases/24.04/current'
  $arch = 'amd64'; if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $arch = 'arm64' }
  $file = "ubuntu-noble-wsl-$arch-wsl.rootfs.tar.gz"
  $dl = Join-Path $DataRoot 'download'
  New-Item -ItemType Directory -Force -Path $dl | Out-Null
  $tar = Join-Path $dl $file; $sumsFile = Join-Path $dl 'SHA256SUMS'
  $oldPP = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
  try {
    Info "Downloading Ubuntu 24.04 for WSL (about 350 MB)"
    Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile $sumsFile
    Invoke-WebRequest -UseBasicParsing -Uri "$base/$file" -OutFile $tar
  } catch {
    Warn "Download failed: $($_.Exception.Message)"
    return $false
  } finally { $ProgressPreference = $oldPP }
  $line = @(Get-Content $sumsFile | Where-Object { $_ -match ('\s\*?' + [regex]::Escape($file) + '\s*$') }) | Select-Object -First 1
  if (-not $line) { Warn "No checksum listed for $file"; return $false }
  $expected = ($line.Trim() -split '\s+')[0]
  $actual = (Get-FileHash -Path $tar -Algorithm SHA256).Hash
  if ($actual -ne $expected) { Warn 'The Ubuntu image failed its checksum; not using it.'; Remove-Item $tar -Force; return $false }
  Ok 'Checksum verified'
  & wsl.exe --import $Distro $Dir $tar --version 2 | Out-Host
  $ok = ($LASTEXITCODE -eq 0)
  Remove-Item $tar, $sumsFile -Force -ErrorAction SilentlyContinue
  return $ok
}

function Start-Artifex {
  if (Test-Path $WinOllamaMarker) { Start-WindowsOllama }
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
    if (Get-OllamaExe) {
      Info 'Ollama for Windows and its models were left installed. Remove them in Settings > Apps if you like.'
    }
    if (Test-Path "$WslConfig.artifex-backup") {
      Info "Your previous WSL settings are in $WslConfig.artifex-backup if you want to undo mirrored networking."
    }
  }
  exit 0
}

# --- install ---
New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
try { Start-Transcript -Path $LogFile -Append | Out-Null } catch { }
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
$UseWindowsOllama = $false
if ($AnthropicKey -eq '' -and $OpenAIKey -eq '') {
  $gpu = Get-Gpu
  $vendor = 'none'
  if ($gpu) {
    if ($gpu.Name -match 'NVIDIA') { $vendor = 'nvidia' }
    elseif ($gpu.Name -match 'AMD|Radeon') { $vendor = 'amd' }
    else { $vendor = 'intel' }
    Ok "GPU: $($gpu.Name), $($gpu.VramGB) GB of video memory"
  } else {
    Warn 'No supported GPU found, so the model runs on the CPU. That works, but agents will be slow.'
  }
  switch ($OllamaLocation) {
    'Windows' { $UseWindowsOllama = $true }
    'Wsl'     { $UseWindowsOllama = $false }
    default   { $UseWindowsOllama = ($vendor -eq 'amd' -or $vendor -eq 'intel') }
  }
  if ($UseWindowsOllama -and $build -lt 22621) {
    Warn "Using this GPU needs Windows 11 22H2 or newer (for WSL's mirrored networking); this PC has build $build."
    Warn 'Falling back to running the model on the CPU inside WSL. Update Windows to use the GPU.'
    $UseWindowsOllama = $false
  }
  $gpuUsed = ($UseWindowsOllama -or $vendor -eq 'nvidia')
  if ($UseWindowsOllama) { Info 'The model will run in Ollama for Windows, which can use this GPU.' }
  elseif ($vendor -eq 'nvidia') { Info 'The model will run in Ollama inside WSL, which uses NVIDIA GPUs through the Windows driver.' }

  if (-not $PSBoundParameters.ContainsKey('Model') -and $gpuUsed -and $gpu) {
    if ($gpu.VramGB -ge 32) { $Model = 'qwen3:32b' }
    elseif ($gpu.VramGB -ge 15) { $Model = 'qwen3:14b' }
  }
  Ok "Local model: $Model"
  if (-not $gpuUsed) {
    # WSL gets half of the PC's memory by default.
    if ($ramGB -lt 12) {
      Warn "Local models need memory. With $ramGB GB, use a small model: -Model qwen3:4b (or qwen3:1.7b)."
    } elseif ($ramGB -lt 16 -and $Model -eq 'qwen3:8b') {
      Warn "With $ramGB GB, qwen3:8b will be tight. If it fails to load, re-run with -Model qwen3:4b."
    }
  }
}
if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) { Fail 'tar.exe is missing (it ships with Windows 10 1803 and later).' }
if (-not (Test-Path (Join-Path $RepoDir 'setup.sh'))) { Fail "Run this script from the ARTIFEX folder (setup.sh not found in $RepoDir)." }

Step 'WSL'
# WSL2 runs on Windows' hypervisor (the Virtual Machine Platform feature). The WSL app can be
# installed while that feature is still off or waiting for a restart, so check both.
$hvRunning = $false
try { $hvRunning = [bool](Get-CimInstance Win32_ComputerSystem).HypervisorPresent } catch { }
if (-not $hvRunning) {
  # With no hypervisor running, Windows reports whether virtualization is on in the firmware.
  $fwOn = $true
  try { $fwOn = (@(Get-CimInstance Win32_Processor | ForEach-Object { $_.VirtualizationFirmwareEnabled }) -contains $true) } catch { }
  if (-not $fwOn) {
    # This flag is occasionally wrong, so warn and carry on; a failure after the restart says so too.
    Warn "Windows reports virtualization as turned off in this PC's BIOS/UEFI, and WSL2 needs it."
    Warn "If setup fails after the restart: enter the BIOS setup (usually Del or F2 while booting), enable"
    Warn "'SVM Mode' (AMD) or 'Intel Virtualization Technology', save, and run setup again."
  }
}
$wslReady = $false
if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
  $wslReady = ((Quiet wsl.exe --version) -eq 0)
}
if (-not $wslReady -or -not $hvRunning) {
  if ($Resumed -and -not $hvRunning) {
    Fail ("Windows' virtualization layer still isn't running after the restart. Open 'Turn Windows features on or off', " +
          "tick 'Virtual Machine Platform' and 'Windows Subsystem for Linux', restart, and run setup again. " +
          "If they are already ticked, check that SVM Mode / Intel VT-x is enabled in the BIOS.")
  }
  Info 'Setting up WSL and the Virtual Machine Platform. Windows will ask for administrator permission.'
  try {
    Start-Process -FilePath 'wsl.exe' -ArgumentList @('--install', '--no-distribution') -Verb RunAs -Wait | Out-Null
  } catch {
    Fail 'Administrator permission is needed once to set up WSL. Run setup-windows.cmd again and choose Yes.'
  }
  # The hypervisor only starts at boot, so a restart is needed whenever it wasn't running.
  if (-not $hvRunning -or (Quiet wsl.exe --version) -ne 0) {
    Request-RestartAndResume 'WSL is set up, but Windows needs a restart to turn on the Virtual Machine Platform.'
  }
}
Info 'Updating WSL (if Windows asks for permission, choose Yes)'
& wsl.exe --update | Out-Host
& wsl.exe --version | Out-Host
Quiet wsl.exe --set-default-version 2 | Out-Null
Ok 'WSL2 is ready'
if (-not $UseWindowsOllama) { Remove-Item $WinOllamaMarker -Force -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
if ($UseWindowsOllama) {
  Step 'Ollama for Windows (uses your GPU)'
  Install-WindowsOllama
  Set-Content -Path $WinOllamaMarker -Value 'Ollama for Windows serves the model for ARTIFEX' -Encoding ASCII
  if (Enable-MirroredNetworking) {
    Warn "Switched WSL to mirrored networking in $WslConfig (backup: .wslconfig.artifex-backup)."
    Warn 'This applies to all your WSL distributions. Restarting WSL now.'
    & wsl.exe --shutdown | Out-Null
  } else {
    Ok 'WSL already uses mirrored networking'
  }
}

Step 'Linux environment'
if (Test-DistroExists) {
  Ok "Reusing the existing '$Distro' environment (re-running updates it)"
} else {
  Info "Creating the '$Distro' environment (Ubuntu 24.04)"
  $wslDir = Join-Path $DataRoot 'wsl'
  New-Item -ItemType Directory -Force -Path $wslDir | Out-Null
  # A disk image left by an earlier failed attempt (not registered with WSL) blocks a new one.
  Remove-Item (Join-Path $wslDir 'ext4.vhdx') -Force -ErrorAction SilentlyContinue
  if (-not (New-DistroFromImage $wslDir)) {
    Info 'Trying the Microsoft Store version of Ubuntu instead'
    & wsl.exe --install Ubuntu-24.04 --name $Distro --location $wslDir --no-launch | Out-Host
    if ($LASTEXITCODE -ne 0) {
      & wsl.exe --install Ubuntu-24.04 --name $Distro --location $wslDir --no-launch --web-download | Out-Host
    }
  }
  if (-not (Test-DistroExists)) {
    if (-not $Resumed) {
      # Creating a distro can switch on Windows features that only work after a restart.
      Request-RestartAndResume 'Creating the Linux environment needs a Windows restart to finish turning on WSL.'
    }
    Fail "Could not create the Linux environment, even after a restart. Open a terminal as administrator, run 'wsl --update', restart Windows, then run setup again."
  }
  Ok "Created '$Distro'"
}

Info 'Configuring it: dedicated user, no access to Windows drives or programs, systemd on'
$rc = Invoke-WslScript 'root' @"
if ! command -v curl >/dev/null || ! command -v sudo >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q && apt-get install -y -q curl ca-certificates sudo
fi
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
if ($UseWindowsOllama) {
  # An Ollama left inside WSL by an earlier install would clash on port 11434.
  Invoke-WslScript 'root' 'systemctl disable --now ollama >/dev/null 2>&1 || true' -Silent | Out-Null
  if ((Invoke-WslScript $LinuxUser "curl -fsS --max-time 5 $OllamaUrl/api/version" -Silent) -ne 0) {
    Fail "The Linux environment can't reach Ollama for Windows at $OllamaUrl. Check that $WslConfig has networkingMode=mirrored under [wsl2], run 'wsl --shutdown', then run setup again."
  }
  Ok 'The Linux environment reaches Ollama for Windows'
}
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
else {
  $setupArgs += @('--local-model', $Model, '--local-context', "$Context")
  if ($UseWindowsOllama) { $setupArgs += @('--ollama-url', $OllamaUrl) }
}
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

if ($UseWindowsOllama) {
  Step 'Checking that the model runs on the GPU'
  Invoke-OllamaWarmup
  $share = Get-OllamaGpuShare
  if ($share -eq 0) {
    # Ollama's Vulkan backend covers GPUs its ROCm build doesn't.
    Info 'The model is running on the CPU. Trying Ollama''s Vulkan GPU backend.'
    [Environment]::SetEnvironmentVariable('OLLAMA_VULKAN', '1', 'User')
    $env:OLLAMA_VULKAN = '1'
    Restart-WindowsOllama
    Invoke-OllamaWarmup
    $share = Get-OllamaGpuShare
    if ($share -le 0) {
      [Environment]::SetEnvironmentVariable('OLLAMA_VULKAN', $null, 'User')
      $env:OLLAMA_VULKAN = $null
      Restart-WindowsOllama
    }
  }
  if ($share -ge 100) { Ok 'The model runs fully on the GPU' }
  elseif ($share -gt 0) { Warn "Only $share% of the model fits in video memory; the rest runs on the CPU. For more speed: setup-windows.cmd -Model qwen3:8b" }
  elseif ($share -eq 0) { Warn 'The model runs on the CPU. Update the AMD Software: Adrenalin Edition driver, restart Windows, then run setup again.' }
  else { Warn "Couldn't read the model's GPU use. Check with: ollama ps" }
}

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
try { Stop-Transcript | Out-Null } catch { }
if (-not $NoBrowser) { Start-Process $Url }
if ($Resumed) { Read-Host 'Press Enter to close' | Out-Null }
