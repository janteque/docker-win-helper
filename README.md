# Docker over TCP (WSL) — helper script

A PowerShell helper script that configures Windows to use a Docker Engine running inside WSL2 by exposing the daemon over TCP (localhost:2375), installing the required Windows CLI binaries (docker, dockerd), and placing Compose / Buildx plugins in your user CLI-plugins folder.

Important: exposing the Docker daemon over plain TCP is insecure. Use only on trusted, local machines and networks. Do not expose port 2375 to untrusted networks.

## Features

- Adds a systemd drop-in override in WSL to make dockerd listen on `tcp://0.0.0.0:2375`.
- Sets a user `DOCKER_HOST` environment variable in Windows to `tcp://localhost:2375`.
- Downloads Windows Docker CLI static binaries (docker.exe, dockerd.exe), docker-credential-wincred, Docker Compose, and Buildx, and places them in user locations.
- Adds the chosen docker folder to the user PATH.
- Shows the exact WSL commands it will execute (including the `sudo` prefix) before running them.

## Requirements

- Windows with WSL2 installed and at least one WSL distribution.
- Docker Engine installed inside the WSL distribution (and systemd available).
- PowerShell (run from your normal user; admin not required for user-level changes).

## Usage

1. Open PowerShell.

2. Download the repository (choose one):

   - With Git:
     ```
     git clone https://github.com/janteque/docker-win-helper.git
     cd docker-win-helper
     ```

   - Without Git (PowerShell):
     ```
     Invoke-WebRequest -Uri "https://github.com/janteque/docker-win-helper/archive/refs/heads/main.zip" -OutFile docker-win-helper.zip
     Expand-Archive docker-win-helper.zip -DestinationPath .
     cd docker-win-helper-main
     ```

   - Download single script (PowerShell):
     ```
     Invoke-WebRequest -Uri "https://raw.githubusercontent.com/janteque/docker-win-helper/main/docker-over-tcp.ps1" -OutFile docker-over-tcp.ps1
     ```

3. Run the script (no admin required for user-level changes). If your system enforces an execution policy, run with Bypass:
   ```
   pwsh -ExecutionPolicy Bypass -File .\docker-over-tcp.ps1
   ```

4. Follow interactive prompts to:
   - Automatically configure the Docker service inside WSL (recommended) or show manual steps.
   - Fetch or accept default versions for docker, compose, buildx and credential helper.
   - Choose destination folder for Windows CLI binaries.

The script will print each WSL command before executing it (commands that are run with sudo are shown with the `sudo` prefix).

## Defaults

- docker CLI default: 28.4.0
- docker-compose default: 2.39.4
- buildx default: 0.28.0
- docker-credential-wincred default: 0.9.4
- default installation folder for docker.exe/dockerd.exe: `C:\programs\docker`

The script can optionally try to fetch the latest releases from upstream sources and use them as defaults.

## Files / changes made

- Creates a systemd drop-in: `/etc/systemd/system/docker.service.d/override.conf` (inside WSL).
- Sets user environment variable `DOCKER_HOST = tcp://localhost:2375`.
- Downloads and copies:
  - `docker.exe`, `dockerd.exe` → user-specified folder (added to user PATH).
  - `docker-credential-wincred.exe` → same folder.
  - `docker-compose.exe`, `docker-buildx.exe` (+ alias `buildx.exe`) → `%USERPROFILE%\.docker\cli-plugins`.
- Modifies the current PowerShell session PATH (so new docker.exe is usable immediately).

## Security note

Exposing Docker remotely without TLS/authentication means any local process that can reach `localhost:2375` can control your Docker daemon and host. Consider using Docker context, SSH sockets, or a properly secured TLS setup for production or shared systems.

## Troubleshooting

- If WSL is not detected, ensure WSL2 and a distribution are installed and try again.
- If the Docker service inside WSL does not start after the override:
  - Open WSL and inspect logs: `sudo journalctl -xeu docker.service`
  - Run `systemctl status docker.service` inside WSL.
- If downloads fail, check network and retry. The script ensures TLS 1.2 for web requests.
- If the CLI can't connect, verify `DOCKER_HOST` is set and the WSL daemon is listening on 2375:
  - In WSL: `ss -ltnp | grep 2375` or `ss -ltn | grep 2375`
  - From Windows: `curl http://localhost:2375/version`

## Links

- WSL installation: https://learn.microsoft.com/windows/wsl/install
- Docker Engine install (Ubuntu): https://docs.docker.com/engine/install/ubuntu/
- Docker downloads: https://download.docker.com/win/static/stable/x86_64/
- Docker Compose & Buildx releases on GitHub

## License


This project is licensed under the MIT License. See the `LICENSE` file for details.
