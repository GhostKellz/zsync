# GitHub Actions Self-Hosted Runner

Docker-based self-hosted runner configuration for zsync CI/CD with NVIDIA GPU support.

## Infrastructure

- **CKEL** - Local homelab infrastructure (Proxmox cluster)
- **CKTECH** - Production bare metal host (Interserver NY-East)

## Quick Start

1. Generate a runner token from GitHub repo settings
2. Create `.env` file:
   ```bash
   RUNNER_TOKEN=your_github_runner_token_here
   RUNNER_NAME=nv-osmium  # or nv-palladium
   ```

3. Start the runner:
   ```bash
   docker compose up -d
   ```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RUNNER_TOKEN` | (required) | GitHub Actions runner registration token |
| `RUNNER_NAME` | `nv-osmium` | Runner instance name |

### Runner Labels

The runner registers with these labels:
- `self-hosted`
- `zig`
- `gpu`

## Files

- `Dockerfile` - Ubuntu 24.04 with Zig nightly + NVIDIA Container Toolkit
- `compose.yml` - Docker Compose with GPU passthrough (nvidia runtime)
- `entrypoint.sh` - Runner bootstrap and registration script

## Requirements

- Docker with NVIDIA Container Toolkit
- NVIDIA GPU with drivers installed
- GitHub Actions runner token

## Usage in Workflows

```yaml
jobs:
  build:
    runs-on: [self-hosted, zig, gpu]
    steps:
      - uses: actions/checkout@v4
      - run: zig build test
```
