#!/bin/bash
set -e

echo "[zsync-runner] Booting container..."
cd /runner

if [ ! -d ".runner" ]; then
  echo "[zsync-runner] Configuring runner..."
  ./config.sh \
    --url https://github.com/GhostKellz/zsync \
    --token "${RUNNER_TOKEN:?RUNNER_TOKEN env var required}" \
    --name "${RUNNER_NAME:-nv-osmium}" \
    --labels self-hosted,zig,gpu \
    --unattended
else
  echo "[zsync-runner] Already configured."
fi

echo "[zsync-runner] Starting runner..."
exec ./run.sh
