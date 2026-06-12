#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build_images.sh — build the RMIS images and pack them into rmis-images.tar.
#
# Run this ON YOUR WORKSTATION (where Docker + the RMIS source live), NOT on the
# server. It produces a single registry-less tarball you copy to 10.10.73.8 and
# `docker load`, exactly like sso-deploy-bundle/gor-sso-images.tar.
#
# What it does:
#   1. Backend  -> localhost/rmis/backend:latest   (env-driven at runtime, no IP baked)
#   2. Frontend -> localhost/rmis/frontend:latest   (server IP BAKED IN at build time:
#      it swaps environment.prod.10.10.73.8.ts in for the repo's environment.prod.ts,
#      builds, then restores the original — the repo is left untouched.)
#   3. Pulls postgres:16-alpine so the server needs no registry access.
#   4. docker save all three -> rmis-images.tar
#
# Usage (from this bundle directory):
#   bash ./build_images.sh
#   # override the source location if your checkout is elsewhere:
#   RMIS_SRC=/path/to/clients/rmis bash ./build_images.sh
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RMIS_SRC="${RMIS_SRC:-$HERE/../CODEBASE/clients/rmis}"
OUT="${OUT:-$HERE/rmis-images.tar}"
PROD_ENV_SRC="$HERE/environment.prod.10.10.73.8.ts"
PROD_ENV_DST="$RMIS_SRC/frontend/src/environments/environment.prod.ts"

[ -d "$RMIS_SRC" ]        || { echo "ERROR: RMIS source not found at '$RMIS_SRC' (set RMIS_SRC=...)"; exit 1; }
[ -f "$PROD_ENV_SRC" ]    || { echo "ERROR: missing $PROD_ENV_SRC"; exit 1; }
[ -f "$PROD_ENV_DST" ]    || { echo "ERROR: repo frontend env not found at '$PROD_ENV_DST'"; exit 1; }

echo "RMIS source : $RMIS_SRC"
echo "Output tar  : $OUT"
echo

# --- 1. backend (no IP baked; SSO_* are injected at runtime by compose) -----
echo "==> Building localhost/rmis/backend:latest"
docker build -t localhost/rmis/backend:latest "$RMIS_SRC/backend"

# --- 2. frontend (bake the 10.10.73.8 prod env, build, restore) -------------
BACKUP="$(mktemp)"
cp "$PROD_ENV_DST" "$BACKUP"
restore_env() { cp "$BACKUP" "$PROD_ENV_DST"; rm -f "$BACKUP"; echo "   (restored original environment.prod.ts)"; }
trap restore_env EXIT

echo "==> Baking server env into environment.prod.ts and building localhost/rmis/frontend:latest"
cp "$PROD_ENV_SRC" "$PROD_ENV_DST"
docker build -t localhost/rmis/frontend:latest "$RMIS_SRC/frontend"
restore_env
trap - EXIT

# --- 3. stock postgres (so the server needs no registry) --------------------
echo "==> Pulling postgres:16-alpine"
docker pull postgres:16-alpine

# --- 4. pack ----------------------------------------------------------------
echo "==> Saving images to $OUT"
docker save -o "$OUT" \
  localhost/rmis/backend:latest \
  localhost/rmis/frontend:latest \
  postgres:16-alpine

echo
echo "Done. Bundle the folder and ship it:"
echo "  $OUT"
ls -lh "$OUT" 2>/dev/null || true
