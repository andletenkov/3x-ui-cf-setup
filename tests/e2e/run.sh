#!/usr/bin/env bash
# E2E smoke-test orchestrator. Builds a systemd-booted container, mounts the
# repo into it, and runs each scenario under tests/e2e/scenarios/ against
# REAL installed services (3x-ui, nginx, Caddy) -- no bash stubs. Exercises
# the same install/config code paths setup.sh and setup-3x-ui.sh use on a
# real VPS, so it catches the class of bug unit tests structurally cannot:
# wrong assumptions about external API/release shapes and real runtime
# config conflicts (port binding, missing packages, etc).
#
# Usage: tests/e2e/run.sh [scenario-name ...]
#   With no args, runs every executable script under tests/e2e/scenarios/.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." &>/dev/null && pwd)"
IMAGE_TAG="3xui-e2e-test:latest"
CONTAINER_NAME="3xui-e2e-$$"

cleanup() {
  echo "--- cleanup: stopping/removing ${CONTAINER_NAME} ---" >&2
  docker rm -f "$CONTAINER_NAME" &>/dev/null || true
}
trap cleanup EXIT

# klzgrad/forwardproxy (the real Caddy/NaiveProxy binary source) only ships
# a linux/amd64 build, so the e2e image always targets amd64 regardless of
# the host's native arch (e.g. Apple Silicon dev machines) -- otherwise
# scenario 02 fails with an unrelated "Exec format error" that has nothing
# to do with the scripts under test. CI runners (GitHub Actions ubuntu-
# latest) are natively amd64, so this is a no-op emulation-free path there.
PLATFORM="linux/amd64"

echo "=== Building E2E test image (${PLATFORM}) ===" >&2
docker build --platform "$PLATFORM" -t "$IMAGE_TAG" -f "${SCRIPT_DIR}/Dockerfile" "$SCRIPT_DIR"

echo "=== Booting systemd container ===" >&2
docker run -d --privileged --cgroupns=host --platform "$PLATFORM" --name "$CONTAINER_NAME" \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v "${REPO_ROOT}:/repo:ro" \
  "$IMAGE_TAG" >/dev/null

# Wait for systemd to finish booting (basic.target reached) before running
# anything -- otherwise `systemctl start` calls race an unready manager.
echo "=== Waiting for systemd to be ready ===" >&2
for _ in $(seq 1 30); do
  if docker exec "$CONTAINER_NAME" systemctl is-system-running --wait \
      2>/dev/null | grep -qE "running|degraded"; then
    break
  fi
  sleep 1
done

# Copy the repo read-write into the container's own filesystem instead of
# relying on the read-only bind mount for scenario work directories (some
# installers refuse to write config next to a read-only source tree).
docker exec "$CONTAINER_NAME" cp -r /repo /opt/repo

scenarios=("$@")
if [[ ${#scenarios[@]} -eq 0 ]]; then
  while IFS= read -r -d '' f; do
    scenarios+=("$(basename "$f")")
  done < <(find "${SCRIPT_DIR}/scenarios" -maxdepth 1 -type f -perm -u+x -print0 | sort -z)
fi

overall_status=0
for scenario in "${scenarios[@]}"; do
  echo >&2
  echo "=== Running scenario: ${scenario} ===" >&2
  if docker exec -e SCENARIO_NAME="$scenario" "$CONTAINER_NAME" \
      bash "/opt/repo/tests/e2e/scenarios/${scenario}"; then
    echo "=== PASS: ${scenario} ===" >&2
  else
    echo "=== FAIL: ${scenario} ===" >&2
    overall_status=1
  fi
done

exit "$overall_status"
