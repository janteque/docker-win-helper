<#
.SYNOPSIS
  Configures Windows to use a Docker Engine running inside WSL exposing the daemon over TCP on 2375.
  - Shows detailed instructions to edit the Docker service in WSL (override ExecStart).
  - Creates DOCKER_HOST in Windows (user) pointing to tcp://localhost:2375.
  - Downloads docker.exe/dockerd.exe (chosen version) and adds them to the user PATH.
  - Downloads Docker Compose and Buildx and places them under %USERPROFILE%\.docker\cli-plugins.

.REQUIREMENTS
  - WSL2 installed.
  - Docker Engine installed inside WSL (e.g. Ubuntu) and systemd active in WSL.
#>

# Default versions for docker cli, compose,  buildx and wincred 
$defaultDocker = "28.4.0"
$defaultCompose = "2.39.4"
$defaultBuildx = "0.28.0"
$defaultCred = "0.9.4"

# Default folder for docker.exe
$defaultDest = "C:\programs\docker"

# ---------- Utilities ----------
$ErrorActionPreference = 'Stop'

function Write-Section($title) {
  Write-Host "`n=== $title ===" -ForegroundColor Cyan
}

# ---------- Welcome Message ----------
Write-Host @"

╔════════════════════════════════════════════════════════════════════════════════╗
║                         Docker over TCP Configuration Script                   ║
╚════════════════════════════════════════════════════════════════════════════════╝

This script configures Windows to use Docker Engine running inside WSL2 by:
  • Setting up Docker daemon to expose Docker over TCP (secure TLS 2376 recommended, optional insecure 2375)
  • Creating DOCKER_HOST environment variable in Windows
  • Downloading and installing Docker CLI tools for Windows
  • Installing Docker Compose and Buildx plugins

REQUIREMENTS:
  ✓ WSL2 must be installed and configured
  ✓ A Linux distribution in WSL (Ubuntu, Debian, etc.)
  ✓ Docker Engine installed inside the WSL distribution
  ✓ systemd enabled in WSL

If you need to install WSL2 first, follow this guide:
🔗 https://docs.microsoft.com/en-us/windows/wsl/install

If you haven't installed Docker in WSL yet, follow this guide:
🔗 https://docs.docker.com/engine/install/ubuntu/

Press any key to continue or Ctrl+C to exit...
"@ -ForegroundColor White

$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

function Read-YesNo($prompt, [bool]$defaultYes=$true) {
  $suffix = if ($defaultYes) { "[Y/n]" } else { "[y/N]" }
  while ($true) {
    $ans = Read-Host "$prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($ans)) { return $defaultYes }
    switch ($ans.ToLower()) {
      'y' { return $true }
      'yes' { return $true }
      'n' { return $false }
      'no' { return $false }
    }
  }
}

function Set-TlsProtocol {
  try {
    [Net.ServicePointManager]::SecurityProtocol = `
      [Net.SecurityProtocolType]::Tls12 -bor `
      [Net.SecurityProtocolType]::Tls11 -bor `
      [Net.SecurityProtocolType]::Tls
  } catch { }
}

function Get-RemoteFile($Url, $OutFile) {
  Set-TlsProtocol
  Write-Host "Downloading: $Url" -ForegroundColor Yellow
  Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
}

function Get-LatestDockerStaticVersion {
  param(
    [switch]$IncludePrerelease
  )
  $url = 'https://download.docker.com/win/static/stable/x86_64/'
  Write-Host "Fetching Docker static listing ..." -ForegroundColor Cyan
  try {
    $html = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30
  } catch {
    Write-Warning "Failed to fetch docker static listing: $($_.Exception.Message)"
    return $null
  }
  $content = $html.Content

  # Extract docker-<semver>.zip
  $regex = 'docker-([0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9\.]+)?)\.zip'
  $versionMatches = [System.Text.RegularExpressions.Regex]::Matches($content, $regex) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
  if (-not $IncludePrerelease) {
    $versionMatches = $versionMatches | Where-Object { $_ -notmatch '-(rc|beta|alpha)' }
  }
  if (-not $versionMatches) { return $null }
  # Sort semver descending
  $parsed = $versionMatches | ForEach-Object {
    $parts = $_.Split('-')[0].Split('.')
    [pscustomobject]@{ Version = $_; Major = [int]$parts[0]; Minor = [int]$parts[1]; Patch = [int]$parts[2] }
  } | Sort-Object Major,Minor,Patch -Descending
  return $parsed[0].Version
}

function Get-GitHubLatestReleaseTag {
  param(
    [Parameter(Mandatory)] [string]$Owner,
    [Parameter(Mandatory)] [string]$Repo,
    [switch]$IncludePrerelease
  )
  $headers = @{ 'User-Agent' = 'docker-helper-script'; 'Accept' = 'application/vnd.github+json' }

  if ($IncludePrerelease) {
    # Need to list releases and pick the first (most recent) regardless of prerelease flag
    $api = "https://api.github.com/repos/$Owner/$Repo/releases?per_page=30"
    try {
      $data = Invoke-RestMethod -Uri $api -Headers $headers -TimeoutSec 30
    } catch {
      Write-Warning "GitHub API error for ${Owner}/${Repo}: $($_.Exception.Message)"
      return $null
    }
    if (-not $data) { return $null }
    return ($data | Select-Object -First 1).tag_name
  } else {
    $api = "https://api.github.com/repos/$Owner/$Repo/releases/latest"
    try {
      $data = Invoke-RestMethod -Uri $api -Headers $headers -TimeoutSec 30
    } catch {
      Write-Warning "GitHub API error for ${Owner}/${Repo}: $($_.Exception.Message)"
      return $null
    }
    return $data.tag_name
  }
}

function Get-LatestVersions {
  param([switch]$IncludePrerelease)
  
  $dockVer = Get-LatestDockerStaticVersion -IncludePrerelease:$IncludePrerelease
  $composeTag = Get-GitHubLatestReleaseTag -Owner docker -Repo compose -IncludePrerelease:$IncludePrerelease
  $buildxTag = Get-GitHubLatestReleaseTag -Owner docker -Repo buildx -IncludePrerelease:$IncludePrerelease
  $credTag   = Get-GitHubLatestReleaseTag -Owner docker -Repo docker-credential-helpers -IncludePrerelease:$IncludePrerelease

  # Normalize tags that start with 'v'
  function StripV($v){ if ($v -and $v.StartsWith('v')) { return $v.Substring(1) } else { return $v } }
  $composeVer = StripV $composeTag
  $buildxVer  = StripV $buildxTag
  $credVer    = StripV $credTag

  return [pscustomobject]@{
    DockerStaticWindows = $dockVer
    Compose             = $composeVer
    Buildx              = $buildxVer
    Wincred             = $credVer
    TimestampUtc        = (Get-Date).ToUniversalTime().ToString('o')
    IncludePrerelease   = [bool]$IncludePrerelease
  }
}

function Add-ToUserPath([string]$PathToAdd) {
  $PathToAdd = $PathToAdd.TrimEnd('\\')
  $userPath = [Environment]::GetEnvironmentVariable('Path','User')

  $already = $false
  if ($userPath) {
    $already = $userPath.Split(';') -contains $PathToAdd
  }

  if (-not $already) {
    $newPath = if ($userPath) { "$userPath;$PathToAdd" } else { $PathToAdd }
    [Environment]::SetEnvironmentVariable('Path',$newPath,'User')
    # Also add to current session
    if (-not ($env:Path.Split(';') -contains $PathToAdd)) {
      $env:Path += ";$PathToAdd"
    }
    Write-Host "Added to user PATH: $PathToAdd" -ForegroundColor Green
  } else {
    Write-Host "User PATH already contains: $PathToAdd" -ForegroundColor DarkGreen
  }
}

# Nueva: helper para mostrar y ejecutar comandos en WSL.
function Invoke-WSLCommand {
  param(
    [Parameter(Mandatory)][string]$Command,
    [switch]$AddSudo
  )
  $toRun = if ($AddSudo) { "sudo $Command" } else { $Command }
  Write-Host "WSL will execute: $toRun" -ForegroundColor Cyan
  return wsl bash -c $toRun
}

# Replace prior sudo caching/batching helpers with a single function that executes all privileged commands
# inside ONE wsl invocation so sudo only prompts once.
function Invoke-WSLSudoScript {
  param(
    [Parameter(Mandatory)][string]$Script,
    [string]$Description = 'Executing privileged script in single WSL session'
  )
  Write-Host $Description -ForegroundColor Cyan
  $clean = $Script -replace "`r`n","`n" -replace "`r","`n"
  $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($clean))
  wsl bash -c "echo $encoded | base64 -d | sudo bash -s" | Out-Null
}

# Helper: ensure key.pem on Windows is writable/removable (clear read-only attr and grant user Full control)
function Unlock-KeyPem {
  param([Parameter(Mandatory)][string]$Path)
  if (Test-Path $Path) {
    try {
      attrib -R $Path 2>$null | Out-Null
      icacls $Path /inheritance:r /grant:r "$($env:USERNAME):(F)" 1>$null 2>$null | Out-Null
    } catch { Write-Warning "Could not adjust Windows permissions on key.pem: $($_.Exception.Message)" }
  }
}

# ---------- Step 1: Instructions to expose the daemon in WSL ----------
Write-Section "1) Expose the WSL Docker Engine via TCP (secure TLS 2376 or insecure 2375)"

$wslDistro = (wsl -l -q 2>$null | Select-Object -First 1)
if (-not $wslDistro) {
  Write-Warning "No WSL distribution detected. Aborting."
  exit 1
}

$instructions = @"

You can configure the Docker service in WSL in two ways:

OPTION A - AUTOMATIC (Recommended):
  This script will ask if you want a SECURE TLS endpoint (127.0.0.1:2376) or an INSECURE endpoint (0.0.0.0:2375).
  TLS mode generates CA/server/client certs and sets DOCKER_TLS_VERIFY/DOCKER_CERT_PATH.
  Insecure mode leaves the daemon unprotected over TCP (NOT recommended on shared machines / untrusted networks).

OPTION B - MANUAL:
  1) Open a WSL terminal (e.g. run 'wsl' or open Ubuntu from Start Menu)
  2) Run: sudo systemctl edit docker.service
  3) For SECURE TLS (recommended) add:
     [Service]
     ExecStart=
     ExecStart=/usr/bin/dockerd -H fd:// -H tcp://127.0.0.1:2376 \
       --tlsverify --tlscacert=/etc/docker/certs/ca.pem \
       --tlscert=/etc/docker/certs/server-cert.pem --tlskey=/etc/docker/certs/server-key.pem

     (Certificates must exist under /etc/docker/certs as generated by the automatic option.)

     For INSECURE (NOT recommended) add:
     [Service]
     ExecStart=
     ExecStart=/usr/bin/dockerd -H fd:// -H tcp://0.0.0.0:2375

  4) Apply changes: sudo systemctl daemon-reload && sudo systemctl restart docker.service
  =============================================================================================
  
"@

Write-Host $instructions -ForegroundColor White

$autoConfig = Read-YesNo "Do you want to automatically configure the Docker service? (Recommended)" $true

# === REFACTORED BLOCK TO USE SINGLE SUDO SESSION ===
if ($autoConfig) {
  Write-Host "`nConfiguring Docker service automatically..." -ForegroundColor Yellow
  try {
    Write-Host "Checking Docker service status..." -ForegroundColor Cyan
    $serviceCheck = wsl bash -c "systemctl is-active docker.service 2>/dev/null || echo 'inactive'"
    if ($serviceCheck -match "inactive|failed") {
      Write-Warning "Docker service is not running or doesn't exist. Please install Docker first."
      Write-Host "Please use the manual option (Option B above)." -ForegroundColor Yellow
    } else {
      $useTLS = Read-YesNo "Do you want to secure the Docker daemon with TLS (recommended)? This will generate CA/server/client certs inside WSL and copy client certs to Windows (DOCKER_CERT_PATH)." $true
      $wslWinPath = "/mnt/c/Users/$($env:USERNAME)/.docker/certs"
      if ($useTLS) {
        Write-Host "Preparing secure TLS configuration (dockerd -> 127.0.0.1:2376) in WSL..." -ForegroundColor Cyan
        $tlsScript = @" 
set -e
apt-get update
apt-get install -y openssl ca-certificates
mkdir -p /etc/docker/certs $wslWinPath /etc/systemd/system/docker.service.d
cd /etc/docker/certs
openssl genrsa -out ca-key.pem 4096
openssl req -x509 -new -nodes -key ca-key.pem -days 3650 -subj '/CN=docker-ca' -out ca.pem
openssl genrsa -out server-key.pem 4096
openssl req -new -key server-key.pem -subj '/CN=localhost' -out server.csr
printf 'subjectAltName=IP:127.0.0.1,DNS:localhost' > extfile.cnf
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out server-cert.pem -days 3650 -extfile extfile.cnf
openssl genrsa -out key.pem 4096
openssl req -subj '/CN=docker-client' -new -key key.pem -out client.csr
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out cert.pem -days 3650
chmod 0400 ca-key.pem server-key.pem key.pem && chmod 0444 ca.pem server-cert.pem cert.pem
printf '%s\n' '[Service]' 'ExecStart=' 'ExecStart=/usr/bin/dockerd -H fd:// -H tcp://127.0.0.1:2376 --tlsverify --tlscacert=/etc/docker/certs/ca.pem --tlscert=/etc/docker/certs/server-cert.pem --tlskey=/etc/docker/certs/server-key.pem' > /etc/systemd/system/docker.service.d/override.conf
systemctl daemon-reload
systemctl restart docker.service
cp /etc/docker/certs/ca.pem $wslWinPath/ca.pem
cp /etc/docker/certs/cert.pem $wslWinPath/cert.pem
"@
        Invoke-WSLSudoScript -Script $tlsScript -Description "Apply TLS configuration and restart Docker"
        $copyKey = Read-YesNo "Copy the CLIENT PRIVATE KEY (key.pem) to Windows as well? Storing the private key on Windows may be less secure. Only do this if you trust the Windows account." $false
        if ($copyKey) {
          # Remove previous key (if any) inside WSL path first to avoid attribute/permission issues
          Invoke-WSLSudoScript -Description "Remove old key.pem if exists (WSL view)" -Script @" 
set -e
rm -f $wslWinPath/key.pem || true
"@
          # Copy fresh key
          Invoke-WSLSudoScript -Description "Copy client private key (single sudo session)" -Script @" 
set -e
cp /etc/docker/certs/key.pem $wslWinPath/key.pem
"@
          try {
            $winCertDir = Join-Path $env:USERPROFILE ".docker\certs"
            $winKeyPath = Join-Path $winCertDir "key.pem"
            Unlock-KeyPem -Path $winKeyPath
          } catch { Write-Warning "Could not set ACL on client key (Windows side)." }
        } else { Write-Host "Client key was NOT copied to Windows." -ForegroundColor Yellow }
        $winCertDir = Join-Path $env:USERPROFILE ".docker\certs"
        if (-not (Test-Path $winCertDir)) { New-Item -Path $winCertDir -ItemType Directory -Force | Out-Null }
        [Environment]::SetEnvironmentVariable('DOCKER_HOST', 'tcp://localhost:2376', 'User')
        [Environment]::SetEnvironmentVariable('DOCKER_TLS_VERIFY', '1', 'User')
        [Environment]::SetEnvironmentVariable('DOCKER_CERT_PATH', $winCertDir, 'User')
        $env:DOCKER_HOST = 'tcp://localhost:2376'
        $env:DOCKER_TLS_VERIFY = '1'
        $env:DOCKER_CERT_PATH = $winCertDir
        $global:ChosenDockerHost = 'tcp://localhost:2376'
        $global:ChosenTLS = $true
        $global:ChosenCertPath = $winCertDir
        Write-Host "TLS setup complete. DOCKER_HOST set to tcp://localhost:2376" -ForegroundColor Green
      } else {
        Write-Host "Configuring non-TLS dockerd (0.0.0.0:2375) in one sudo session..." -ForegroundColor Cyan
        $plainScript = @" 
set -e
mkdir -p /etc/systemd/system/docker.service.d
printf '%s\n' '[Service]' 'ExecStart=' 'ExecStart=/usr/bin/dockerd -H fd:// -H tcp://0.0.0.0:2375' > /etc/systemd/system/docker.service.d/override.conf
systemctl daemon-reload
systemctl restart docker.service
"@
        Invoke-WSLSudoScript -Script $plainScript -Description "Apply non-TLS configuration and restart Docker"
        $global:ChosenDockerHost = 'tcp://localhost:2375'
        $global:ChosenTLS = $false
      }
      Start-Sleep -Seconds 3
      $status = wsl bash -c "systemctl is-active docker.service"
      if ($status -match "active") { Write-Host "✓ Docker service configured and restarted successfully!" -ForegroundColor Green } else { Write-Warning "✗ Docker service restart failed. Check logs." }
    }
  } catch {
    Write-Warning "Automatic configuration failed: $($_.Exception.Message)"
    Write-Host "Please use the manual option (Option B above)." -ForegroundColor Yellow
  }
} else {
  Write-Host "`nPlease follow the manual steps above to configure Docker service." -ForegroundColor Yellow
  if (Read-YesNo "Do you want to open a WSL shell now to perform the manual steps? (type 'exit' afterwards to return)" $true) { wsl }
}
# === END REFACTORED BLOCK ===

# Try to verify the endpoint from inside WSL
Write-Host "Checking that Docker is running inside WSL..." -ForegroundColor Yellow
try {
  # Run 'docker info' in WSL; suppress errors and return the output if the daemon responds
  $wslCmd = 'docker info --format "{{json .}}" 2>/dev/null || true'
  $resp = wsl bash -c $wslCmd
  if ($resp -and $resp.Trim()) {
    Write-Host "OK: Docker responds inside WSL." -ForegroundColor Green
  } else {
    Write-Warning "Docker is not responding inside WSL yet. You can continue; we'll check again later."
  }
} catch {
  Write-Warning "Could not run the check inside WSL: $($_.Exception.Message)"
}

# ---------- Step 2: DOCKER_HOST in Windows ----------
Write-Section "2) Create/update DOCKER_HOST (user)"

if (-not $global:ChosenDockerHost) { # Manual path fallback
  $global:ChosenDockerHost = 'tcp://localhost:2375'
  $global:ChosenTLS = $false
}

# Clear previous vars first to avoid stale secure settings when switching to insecure
[Environment]::SetEnvironmentVariable('DOCKER_HOST', $null, 'User')
[Environment]::SetEnvironmentVariable('DOCKER_TLS_VERIFY', $null, 'User')
[Environment]::SetEnvironmentVariable('DOCKER_CERT_PATH', $null, 'User')

[Environment]::SetEnvironmentVariable('DOCKER_HOST', $global:ChosenDockerHost, 'User')
$env:DOCKER_HOST = $global:ChosenDockerHost

if ($global:ChosenTLS) {
  [Environment]::SetEnvironmentVariable('DOCKER_TLS_VERIFY', '1', 'User')
  if ($global:ChosenCertPath) { [Environment]::SetEnvironmentVariable('DOCKER_CERT_PATH', $global:ChosenCertPath, 'User'); $env:DOCKER_CERT_PATH = $global:ChosenCertPath }
  $env:DOCKER_TLS_VERIFY = '1'
  Write-Host "DOCKER_HOST (user) = $global:ChosenDockerHost (TLS enabled)" -ForegroundColor Green
  if (-not $global:ChosenCertPath) { Write-Warning "TLS selected but no certificate path recorded. You may need to set DOCKER_CERT_PATH manually." }
} else {
  # Ensure session clears TLS vars
  Remove-Item Env:DOCKER_TLS_VERIFY -ErrorAction SilentlyContinue
  Remove-Item Env:DOCKER_CERT_PATH -ErrorAction SilentlyContinue
  Write-Host "DOCKER_HOST (user) = $global:ChosenDockerHost (INSECURE - no TLS)" -ForegroundColor Yellow
  Write-Warning "Insecure Docker daemon over TCP. Consider rerunning script and enabling TLS." 
}

# ---------- Step 3: Show WSL version and ask target versions ----------
Write-Section "3) Versions to use"

# Show Docker version inside WSL
try {
  Write-Host "Docker version installed in WSL:" -ForegroundColor Yellow
  wsl docker --version
} catch {
  Write-Warning "Could not invoke 'docker' inside WSL. Is it installed?"
}

# Show URLs where to check versions
Write-Host "`nYou can now choose the Windows CLI versions. You can check available versions at:" -ForegroundColor White
Write-Host "  Docker (static zip): https://download.docker.com/win/static/stable/x86_64/" -ForegroundColor Yellow
Write-Host "  Docker Compose (releases): https://github.com/docker/compose/releases" -ForegroundColor Yellow
Write-Host "  Buildx (releases): https://github.com/docker/buildx/releases" -ForegroundColor Yellow

# ---------- Optional: Fetch latest versions using helper script ----------
Write-Section "Fetch latest versions (optional)"
if (Read-YesNo "Do you want to fetch the latest available versions and use them as defaults?" $true) {
  try {
    Write-Host "Fetching latest versions from sources..." -ForegroundColor Yellow
    $latest = Get-LatestVersions
    if ($latest -and $latest.DockerStaticWindows) {
      $defaultDocker  = $latest.DockerStaticWindows
      if ($latest.Compose) { $defaultCompose = $latest.Compose }
      if ($latest.Buildx)  { $defaultBuildx  = $latest.Buildx }
      if ($latest.Wincred) { $defaultCred    = $latest.Wincred }
      Write-Host "Updated defaults: docker=$defaultDocker compose=$defaultCompose buildx=$defaultBuildx wincred=$defaultCred" -ForegroundColor Green
    } else {
      Write-Warning "Could not retrieve latest versions. Keeping hardcoded defaults."
    }
  } catch {
    Write-Warning "Failed to retrieve latest versions: $($_.Exception.Message). Using hardcoded defaults."
  }
} else {
  Write-Host "Skipping latest version fetch. Using hardcoded defaults." -ForegroundColor Yellow
}


$dockerVer = Read-Host "Docker version for Windows CLI (static zip from download.docker.com). Press Enter to use [$defaultDocker]"
if ([string]::IsNullOrWhiteSpace($dockerVer)) { $dockerVer = $defaultDocker }

$composeVer = Read-Host "Docker Compose version (GitHub releases). Press Enter to use [$defaultCompose]"
if ([string]::IsNullOrWhiteSpace($composeVer)) { $composeVer = $defaultCompose }

$buildxVer = Read-Host "Buildx version (GitHub releases) [$defaultBuildx]"
if ([string]::IsNullOrWhiteSpace($buildxVer)) { $buildxVer = $defaultBuildx }

# New option: credential helper version
$credVer = Read-Host "docker-credential-wincred version (GitHub releases) [$defaultCred]"
if ([string]::IsNullOrWhiteSpace($credVer)) { $credVer = $defaultCred }

Write-Host "`nWill use: docker=$dockerVer  docker-compose=$composeVer  buildx=$buildxVer  credential-wincred=$credVer" -ForegroundColor Green

# ---------- Step 4: Download docker.exe/dockerd.exe and add to PATH ----------
Write-Section "4) Download docker.exe/dockerd.exe and add to PATH"

$dest = Read-Host "Destination folder for 'docker.exe' and 'dockerd.exe' (e.g. C:\programas\docker) [$defaultDest]"
if ([string]::IsNullOrWhiteSpace($dest)) {
  $dest = $defaultDest
  Write-Host "Using default destination: $dest" -ForegroundColor Green
}
if (-not (Test-Path $dest)) { New-Item -Path $dest -ItemType Directory -Force | Out-Null }

$tmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ("dl-"+([Guid]::NewGuid().ToString("N")))) -Force
$zipUrl = "https://download.docker.com/win/static/stable/x86_64/docker-$dockerVer.zip"
$zipFile = Join-Path $tmp.FullName ("docker-$dockerVer.zip")

try {
  Get-RemoteFile -Url $zipUrl -OutFile $zipFile
} catch {
  Write-Error "Could not download $zipUrl. Check the version you entered."
  exit 1
}

# Extract
$extractTo = Join-Path $tmp.FullName "unz"
Expand-Archive -Path $zipFile -DestinationPath $extractTo -Force

# Zip creates subfolder 'docker\'
$inner = Join-Path $extractTo "docker"
if (-not (Test-Path $inner)) {
  # In some versions the content may be at root
  $inner = $extractTo
}

# Copy binaries to destination
Copy-Item -Path (Join-Path $inner "docker.exe") -Destination (Join-Path $dest "docker.exe") -Force
if (Test-Path (Join-Path $inner "dockerd.exe")) {
  Copy-Item -Path (Join-Path $inner "dockerd.exe") -Destination (Join-Path $dest "dockerd.exe") -Force
}

# Download and install docker-credential-wincred next to docker.exe
$credUrl = "https://github.com/docker/docker-credential-helpers/releases/download/v$credVer/docker-credential-wincred-v$credVer.windows-amd64.exe"
$credTmp = Join-Path $tmp.FullName ("docker-credential-wincred-v" + $credVer + ".exe")
try {
  Get-RemoteFile -Url $credUrl -OutFile $credTmp
  Copy-Item -Path $credTmp -Destination (Join-Path $dest "docker-credential-wincred.exe") -Force
  Unblock-File -Path (Join-Path $dest "docker-credential-wincred.exe") -ErrorAction SilentlyContinue
  Write-Host "docker-credential-wincred.exe installed at: " (Join-Path $dest "docker-credential-wincred.exe") -ForegroundColor Green
} catch { Write-Warning "Could not download docker-credential-wincred ($credUrl)." }

# Add to user PATH
Add-ToUserPath -PathToAdd $dest

# ---------- Step 5: Create ~/.docker/cli-plugins ----------
Write-Section "5) Create CLI plugins folder"
$pluginsDir = Join-Path $env:USERPROFILE ".docker\cli-plugins"
New-Item -Path $pluginsDir -ItemType Directory -Force | Out-Null
Write-Host "Plugins dir: $pluginsDir" -ForegroundColor Green

# ---------- Step 6: Download Docker Compose ----------
Write-Section "6) Download Docker Compose"

$composeUrl = "https://github.com/docker/compose/releases/download/v$composeVer/docker-compose-windows-x86_64.exe"
$composeExe = Join-Path $pluginsDir "docker-compose.exe"
try {
  Get-RemoteFile -Url $composeUrl -OutFile $composeExe
  Unblock-File -Path $composeExe -ErrorAction SilentlyContinue
  Write-Host "docker-compose.exe installed at: $composeExe" -ForegroundColor Green
} catch { Write-Warning "Could not download Compose ($composeUrl)." }

# ---------- Step 7: Download Buildx ----------
Write-Section "7) Download Buildx"

$buildxUrl = "https://github.com/docker/buildx/releases/download/v$buildxVer/buildx-v$buildxVer.windows-amd64.exe"
# Note: By plugin convention the recommended name is 'docker-buildx.exe' so it is invoked as 'docker buildx ...'.
# For convenience we also provide a short executable 'buildx.exe'.
$buildxPlugin = Join-Path $pluginsDir "docker-buildx.exe"
$buildxShort  = Join-Path $pluginsDir "buildx.exe"
try {
  Get-RemoteFile -Url $buildxUrl -OutFile $buildxPlugin
  Copy-Item $buildxPlugin $buildxShort -Force
  Unblock-File -Path $buildxPlugin -ErrorAction SilentlyContinue
  Unblock-File -Path $buildxShort -ErrorAction SilentlyContinue
  Write-Host "Buildx installed at: $buildxPlugin (and alias $buildxShort)" -ForegroundColor Green
} catch { Write-Warning "Could not download Buildx ($buildxUrl)." }

# ---------- Final checks ----------
Write-Section "Final checks"

# For this session, ensure PATH includes $dest (already done) and DOCKER_HOST (already done)
try {
  Write-Host "docker --version:" -ForegroundColor Yellow
  & (Join-Path $dest "docker.exe") --version
} catch { Write-Warning "Could not execute docker.exe from $dest" }


try {
  Write-Host "`n'docker version' (using DOCKER_HOST=$env:DOCKER_HOST, TLS=$([bool]$global:ChosenTLS)):" -ForegroundColor Yellow
  docker version
} catch { Write-Warning "CLI could not connect to daemon. Check Step 1 and DOCKER_HOST." }

try {
  Write-Host "`n'docker compose version':" -ForegroundColor Yellow
  docker compose version
} catch { Write-Warning "Compose did not respond. Check $composeExe." }

try {
  Write-Host "`n'docker buildx version':" -ForegroundColor Yellow
  docker buildx version
} catch { Write-Warning "Buildx did not respond. Check $buildxPlugin." }

Write-Host "`n======================================================================" -ForegroundColor Cyan
Write-Host "`nAll done!!" -ForegroundColor Cyan
Write-Host "`n======================================================================" -ForegroundColor Cyan