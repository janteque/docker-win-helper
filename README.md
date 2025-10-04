# Docker over TCP (WSL) — helper script (TLS secure mode supported)

A PowerShell helper script that configures Windows to use a Docker Engine running inside WSL2 by exposing the daemon over TCP. It now supports a SECURE TLS mode on `127.0.0.1:2376` (recommended) and an optional INSECURE mode on `0.0.0.0:2375`.

> Recommended: Always choose TLS (2376) unless you fully trust the host and network.

## Features

- Adds a systemd drop-in override in WSL to make `dockerd` listen on a secure TLS endpoint (`tcp://127.0.0.1:2376`) or, if chosen, an insecure endpoint (`tcp://0.0.0.0:2375`).
- Generates CA / server / client certificates (TLS mode) under `/etc/docker/certs` and copies client certs (`ca.pem`, `cert.pem`, and optionally `key.pem`) to Windows `%USERPROFILE%\.docker\certs`.
- Sets user `DOCKER_HOST` (and if TLS: `DOCKER_TLS_VERIFY=1`, `DOCKER_CERT_PATH`).
- Downloads Windows Docker CLI static binaries (`docker.exe`, `dockerd.exe`), docker-credential-wincred, Docker Compose, and Buildx, and places them in user locations.
- Adds the chosen docker folder to the user PATH.
- Shows the exact WSL commands it will execute (including the `sudo` prefix) before running them.

## Requirements

- Windows with WSL2 installed and at least one WSL distribution.
- Docker Engine installed inside the WSL distribution (and systemd available).
- PowerShell (run from your normal user; admin not required for user-level changes).

## Usage

1. Open PowerShell.
2. Clone or download repository (see below).
3. Run the script (optionally with `-ExecutionPolicy Bypass`).
4. Choose AUTOMATIC configuration and select SECURE (TLS) or INSECURE mode when prompted.
5. Decide whether to copy the client private key (`key.pem`) to Windows (only if the Windows account is trusted). If you skip copying the key you can still use Docker from inside WSL with the certs that remain there.

The script prints each WSL command before executing it.

## Defaults

- docker CLI default: 28.4.0
- docker-compose default: 2.39.4
- buildx default: 0.28.0
- docker-credential-wincred default: 0.9.4
- default installation folder for docker.exe/dockerd.exe: `C:\programs\docker`

It can also attempt to fetch the latest upstream versions and substitute them as defaults.

## Files / changes made

Inside WSL:
- Creates (or updates) systemd drop-in: `/etc/systemd/system/docker.service.d/override.conf`.
  - TLS mode ExecStart (example):
    ```
    /usr/bin/dockerd -H fd:// -H tcp://127.0.0.1:2376 \
      --tlsverify --tlscacert=/etc/docker/certs/ca.pem \
      --tlscert=/etc/docker/certs/server-cert.pem --tlskey=/etc/docker/certs/server-key.pem
    ```
  - Insecure mode ExecStart:
    ```
    /usr/bin/dockerd -H fd:// -H tcp://0.0.0.0:2375
    ```
- (TLS) Generates certs in `/etc/docker/certs`.

On Windows (user scope):
- Sets user environment variables depending on selection:
  - TLS mode: `DOCKER_HOST=tcp://127.0.0.1:2376`, `DOCKER_TLS_VERIFY=1`, `DOCKER_CERT_PATH=%USERPROFILE%\.docker\certs`.
  - Insecure mode: `DOCKER_HOST=tcp://127.0.0.1:2375` only (TLS vars cleared).
- Copies client certs to `%USERPROFILE%\.docker\certs`:
  - Always: `ca.pem`, `cert.pem`
  - Optional: `key.pem` (only if you answered Yes when prompted)
- Downloads:
  - `docker.exe`, `dockerd.exe` → chosen folder (added to PATH)
  - `docker-credential-wincred.exe` → same folder
  - `docker-compose.exe`, `docker-buildx.exe`, alias `buildx.exe` → `%USERPROFILE%\.docker\cli-plugins`
- Updates current session PATH.

## Choosing secure vs insecure mode

| Mode      | Host / Port              | Encryption | Auth (certs) | Exposure                          | Recommended |
|-----------|--------------------------|------------|--------------|-----------------------------------|-------------|
| TLS       | 127.0.0.1:2376 (default) | Yes        | Yes (mutual) | Local loopback only (unless you rebind) | Yes         |
| Insecure  | 0.0.0.0:2375             | No         | No           | All interfaces (any local user/process) | No (only for isolated, trusted setups) |

If you need containers (e.g. VS Code Dev Containers) to access the daemon via TLS from another network namespace, you can rebind to `0.0.0.0:2376` by editing the drop-in and restarting the service, or mount the Unix socket.

## Security note

INSECURE MODE (2375) sends all commands unencrypted and unauthenticated; any process that can reach the port can control Docker. Prefer TLS mode. For multi-user or semi-trusted environments ALWAYS use TLS or an alternative such as SSH sockets, rootless Docker, or `docker context` with secure transport.

If you copied `key.pem` to Windows ensure the file has restricted permissions; the script attempts to apply restrictive ACLs. If you later want to rotate certificates, delete the cert folder (`%USERPROFILE%\.docker\certs`) and rerun the script selecting TLS again.

## VS Code Dev Containers integration

TLS example (`.devcontainer/devcontainer.json` excerpt) — requires binding dockerd to `0.0.0.0:2376` OR using `host.docker.internal` (loopback mapping):
```jsonc
{
  "runArgs": ["--add-host=host.docker.internal:host-gateway"],
  "mounts": [
    "source=${localEnv:USERPROFILE}\\.docker\\certs,target=/workspaces/.docker-certs,type=bind"
  ],
  "remoteEnv": {
    "DOCKER_HOST": "tcp://host.docker.internal:2376",
    "DOCKER_TLS_VERIFY": "1",
    "DOCKER_CERT_PATH": "/workspaces/.docker-certs"
  }
}
```
Insecure example (NOT recommended):
```jsonc
{
  "runArgs": ["--add-host=host.docker.internal:host-gateway"],
  "remoteEnv": {
    "DOCKER_HOST": "tcp://host.docker.internal:2375"
  }
}
```
Alternative: Mount the socket instead (most secure inside same host boundary):
```jsonc
{
  "runArgs": ["-v", "/var/run/docker.sock:/var/run/docker.sock"]
}
```
(Only do this if you trust the host; mounting the socket grants root-equivalent access.)

## Troubleshooting

- If WSL is not detected, ensure WSL2 and a distribution are installed and try again.
- If the Docker service inside WSL does not start after the override:
  - Inside WSL: `sudo journalctl -xeu docker.service`
  - `systemctl status docker.service`
- To see current listening port: inside WSL `ss -ltnp | grep 237` (adjust for 2375 / 2376).
- If CLI can't connect:
  - Confirm `echo $Env:DOCKER_HOST` in PowerShell.
  - If TLS: ensure `DOCKER_TLS_VERIFY=1` and cert files exist in `%USERPROFILE%\.docker\certs`.
  - If insecure: ensure daemon really listening on chosen port.
- Rotate TLS certs: delete Windows cert folder (and optional key) + regenerate by rerunning script.

## Links

- WSL installation: https://learn.microsoft.com/windows/wsl/install
- Docker Engine install (Ubuntu): https://docs.docker.com/engine/install/ubuntu/
- Docker downloads: https://download.docker.com/win/static/stable/x86_64/
- Docker Compose releases: https://github.com/docker/compose/releases
- Buildx releases: https://github.com/docker/buildx/releases

## License

MIT — see `LICENSE`.