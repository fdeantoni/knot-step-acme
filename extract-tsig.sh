#!/usr/bin/env bash
set -euo pipefail

# Usage: ./generate-tsig-key.sh [output-file]
OUT_FILE="${1:-tsig.key}"

# Resolve container ID for the 'knot' service
get_knot_cid() {
  local cid=""
  if command -v docker >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1; then
      cid="$(docker compose ps -q knot || true)"
    fi
    if [ -z "${cid}" ] && command -v docker-compose >/dev/null 2>&1; then
      cid="$(docker-compose ps -q knot || true)"
    fi
    if [ -z "${cid}" ]; then
      cid="$(docker ps --filter 'name=knot' --format '{{.ID}}' | head -n1 || true)"
    fi
  fi
  echo "${cid}"
}

CID="$(get_knot_cid)"
if [ -z "${CID}" ]; then
  echo "Error: Could not find a running 'knot' container. Start services with: docker compose up -d" >&2
  exit 1
fi

SRC="/etc/knot/tsig.key"

# Ensure the key exists in the container
if ! docker exec "${CID}" test -f "${SRC}"; then
  echo "Error: ${SRC} not found in container ${CID}. Is the container built with the key?" >&2
  exit 1
fi

# Ensure destination directory exists
mkdir -p "$(dirname "${OUT_FILE}")"

# Copy key out of the container
docker cp "${CID}:${SRC}" "${OUT_FILE}"

# Restrict permissions
chmod 600 "${OUT_FILE}"

echo "Wrote TSIG key to ${OUT_FILE}"
echo "Use with nsupdate/add-subdomain.sh, e.g.: nsupdate -k ${OUT_FILE}"