# RMIS — offline deploy to 10.10.73.8 (staging, direct-IP, HTTP)

This bundle deploys the **RMIS** app (Spring Boot backend + Angular SPA + its own
Postgres) to a **registry-less, repo-less** Linux server using a pre-built image
tarball. No internet, no git, no build step on the server.

RMIS is a **client** of the GoR SSO platform: it logs users in via the SSO
wrapper/Keycloak. **The SSO stack (`sso-deploy-bundle`) must already be deployed
and running on this same host (`10.10.73.8`)** before RMIS will work — RMIS
reaches it over the host's published ports.

> **Scope:** internal/test staging on `http://10.10.73.8` over **plain HTTP**
> (no TLS). Ships dev/test credentials — **rotate before any production use**.

## What's in this bundle

| File | Purpose |
|---|---|
| `docker-compose.deploy.yml` | Build-free Compose file. Images run as-is; all env inlined except `CLIENT_SECRET` (from `.env`). |
| `rmis-images.tar` | The 3 images: `rmis/backend`, `rmis/frontend`, `postgres:16-alpine`. **Produced by `build_images.sh` on your workstation — see Step 0.** |
| `build_images.sh` | Workstation-side: builds the two RMIS images (bakes `10.10.73.8` into the frontend) + packs the tar. |
| `environment.prod.10.10.73.8.ts` | The frontend prod env with `10.10.73.8` URLs baked in. `build_images.sh` swaps this in at build time. |
| `update_clients.sh` | Server-side: registers/repoints the `rmis-portal` Keycloak client to the `10.10.73.8` URLs. |
| `rmis-nginx.conf` | System nginx site that fronts `:80` and reverse-proxies to the frontend container on `:8086`. Install per Step 5. |
| `.env` | `CLIENT_SECRET` + Keycloak admin creds (used by compose + `update_clients.sh`). |

## How the URLs are split (read this first)

The SSO platform is split-host, and RMIS runs in containers, so three classes of
URL point at three different places:

| URL | Points at | Why |
|---|---|---|
| `SSO_ISSUER_URI` | `http://10.10.73.8:8080/...` | **Compared** to the `iss` claim. On this host Keycloak runs with `KC_HOSTNAME=10.10.73.8`, so it stamps `10.10.73.8` — NOT `localhost`. This is the #1 thing that differs from local dev. |
| `SSO_JWK_SET_URI`, `SSO_TOKEN_URI`, `SSO_USERINFO_URI` | `host.docker.internal:8080/:8000` | **Fetched/called server-side** from inside the backend container → reach the SSO stack's host-published ports. |
| `SSO_AUTH_URI`, `FRONTEND_URL`, and the frontend's `ssoLoginUrl`/`ssoLogoutUrl`/`postLogoutRedirectUri` | `http://10.10.73.8:...` | **Browser-facing** — the user's browser must resolve them. |

All of the above are already set correctly in `docker-compose.deploy.yml` and the
baked frontend env. You only touch them if the host IP changes.

---

## Step 0 — build the image tar (on your workstation, ONCE)

Docker must be running and the RMIS source present (`../CODEBASE/clients/rmis`).

```bash
cd rmis-deploy-bundle
bash ./build_images.sh
# -> produces rmis-images.tar (and leaves the repo's environment.prod.ts untouched)
```

> The frontend's SSO URLs are **baked in at build time** from
> `environment.prod.10.10.73.8.ts`. If `10.10.73.8` ever changes, edit that file
> and re-run `build_images.sh`.

## Prerequisites on the server

- The **SSO stack is up and healthy** (`docker compose -f docker-compose.deploy.yml ps`
  in `sso-deploy`), publishing wrapper `:8000` and Keycloak `:8080` on `10.10.73.8`.
- **Architecture: x86_64 / amd64** (the images are `linux/amd64`). `uname -m` → `x86_64`.
- Docker Engine + Compose plugin: `docker compose version`.
- Free TCP ports: **8086** (frontend container), **8085** (backend), **5436**
  (Postgres). These don't collide with the SSO stack (8000/8080/3001/8090). Check:
  `ss -ltnp | grep -E ':(8086|8085|5436)\b'` (should be empty).
- Port **80** is expected to be owned by the **shared system nginx** on this host
  (it's the single browser-facing origin, `http://10.10.73.8`). The frontend
  container therefore binds `:8086` and system nginx proxies `:80 -> :8086`
  (Step 5). If `:80` is *not* yet taken and you have no shared nginx, you can skip
  Step 5 and change the frontend port mapping back to `"80:80"` in the Compose file.
- The backend container must be able to reach the host's `:8000`/`:8080` via
  `host.docker.internal` (the Compose file adds `host-gateway` for this).

## Step 1 — copy the bundle to the server

```bash
scp -r rmis-deploy-bundle <user>@10.10.73.8:~/rmis-deploy
```

Then on the server:

```bash
cd ~/rmis-deploy
ls   # docker-compose.deploy.yml, rmis-images.tar, update_clients.sh, .env
```

## Step 2 — load the images

```bash
docker load -i rmis-images.tar
docker images | grep -E 'rmis|postgres' # rmis/backend, rmis/frontend, postgres:16-alpine
```

> If `docker load` errors specifically on `postgres:16-alpine` (older daemons can
> refuse multi-arch indexes) and the server can reach Docker Hub, just
> `docker pull postgres:16-alpine`. The two `rmis/*` images are single-platform
> and always load offline.

## Step 3 — register the rmis-portal client

The wrapper validates RMIS's secret + redirect URIs against Keycloak, so the
client must exist there with the `10.10.73.8` URLs. This script reconciles it
(idempotent — creates if missing, repoints if present):

```bash
set -a; . ./.env; set +a
bash ./update_clients.sh
```

Expected tail:
```
Done. rmis-portal reconciled:
  redirect      -> http://10.10.73.8:8085/login/oauth2/code/gor
  web origins   -> http://10.10.73.8 , http://10.10.73.8:8085
  post-logout   -> http://10.10.73.8/login
```

> If it can't find the Keycloak container, pass it explicitly:
> `KC_CONTAINER=sso-keycloak-1 bash ./update_clients.sh` (find it via `docker ps`).

## Step 4 — bring up RMIS

```bash
docker compose -f docker-compose.deploy.yml up -d
docker compose -f docker-compose.deploy.yml ps
```

Boot order: Postgres (healthcheck ~5 s) → backend → frontend. Watch the backend
come up (it creates its schema on first boot with `ddl-auto=update`):

```bash
docker compose -f docker-compose.deploy.yml logs -f backend   # wait for "Started ... in N seconds"
```

## Step 5 — install the system nginx site

The shared system nginx owns `:80` on this host, so the frontend container binds
`:8086` (see the Compose file) and nginx reverse-proxies `:80 -> 127.0.0.1:8086`.
This keeps the browser origin at `http://10.10.73.8` — exactly what `CORS_ORIGINS`,
`FRONTEND_URL`, and the Keycloak `redirect_uri` expect, so no app config changes.

```bash
sudo cp rmis-nginx.conf /etc/nginx/conf.d/rmis.conf
sudo nginx -t && sudo systemctl reload nginx
```

> SSO is **not** proxied here — the SPA hits the backend (`:8085`) and wrapper
> (`:8000`) directly via absolute URLs, so `/oauth2` and `/login/oauth2` never pass
> through this site. It's a plain pass-through of `:80`.

> **`default_server` caveat:** if the shared nginx already has a
> `server { listen 80 default_server; ... }` block (a catch-all for another app),
> requests with no matching `server_name` go *there*, not to this `server_name _;`
> site. Check with `grep -rn 'default_server' /etc/nginx/`. If one exists, either
> give RMIS its own hostname (`server_name rmis.<domain>;`) or fold this `location /`
> block into the existing default site instead of shipping a second server block.

## Step 6 — smoke test

On the server:

```bash
curl -sSIf http://10.10.73.8/            | head -n1   # via system nginx -> :8086 container, 200
curl -sSIf http://127.0.0.1:8086/        | head -n1   # frontend container directly, 200
curl -sSI  http://10.10.73.8:8085/api/auth/login | head -n1  # backend reachable (405/401 is fine — it's alive)
```

Then in a browser on the same network:
- RMIS SPA: `http://10.10.73.8` → **Login with Government SSO** → Keycloak login →
  back to RMIS dashboard.
- Logout from RMIS → ends the SSO session → lands on `http://10.10.73.8/login`.

Test users (realm `government-internal`) are in the repo's `CREDENTIALS.md`
(e.g. `kwizera_landowner` / `GovRwanda@2025`).

## Day-2

```bash
# logs
docker compose -f docker-compose.deploy.yml logs -f backend
# restart one service
docker compose -f docker-compose.deploy.yml restart backend
# stop / start everything (data persists in the named volume)
docker compose -f docker-compose.deploy.yml down        # keeps the DB volume
docker compose -f docker-compose.deploy.yml up -d
# full reset INCLUDING the RMIS database
docker compose -f docker-compose.deploy.yml down -v
```

## Troubleshooting

- **Login fails with issuer/`iss` mismatch:** `SSO_ISSUER_URI` must equal what
  Keycloak stamps. On this host that's `http://10.10.73.8:8080/realms/government-internal`
  (because the SSO stack sets `KC_HOSTNAME=10.10.73.8`). If you point Keycloak at a
  different hostname, change `SSO_ISSUER_URI` to match.
- **`redirect_uri` rejected:** you skipped Step 3, or the host IP changed. Re-run
  Step 3 (override `SERVER_IP=<newip>` if the box moved) **and** rebuild the
  frontend image (Step 0) so the baked SPA URLs match.
- **Backend can't reach Keycloak/wrapper (`Connection refused` to `host.docker.internal`):**
  confirm the SSO stack is up and its `:8000`/`:8080` are published on the host
  (`ss -ltnp | grep -E ':(8000|8080)'`), and that the backend container has the
  `host.docker.internal:host-gateway` entry (it's in the Compose file).
  Alternative: point `SSO_JWK_SET_URI`/`SSO_TOKEN_URI`/`SSO_USERINFO_URI` at
  `http://10.10.73.8:...` directly instead of `host.docker.internal`.
- **SPA shows the wrong SSO URL / logout doesn't end the session:** the frontend
  URLs are baked into the JS at build time. If the IP changed, rebuild the
  frontend image (Step 0) and re-ship the tar.
- **`failed to bind host port for 0.0.0.0:80 ... address already in use`** (frontend
  won't start): the shared system nginx (or another process) already holds `:80`.
  That's expected on this host — the frontend should bind `:8086`, not `:80`.
  Confirm the Compose `frontend.ports` is `"8086:80"` and that you ran Step 5 so
  nginx proxies `:80 -> :8086`. Identify the `:80` holder with
  `sudo ss -ltnp 'sport = :80'`.
- **`400: client_id is required ...` on logout:** the SPA must send `client_id`
  (`rmis-portal`) on `/oauth2/logout` — it does, via the baked `ssoClientId`. If
  you changed the env, keep that field set.

## Security (must do before production)

This is a **staging/internal** bundle: plain HTTP, dev secrets baked in
(`POSTGRES_PASSWORD=rmis_pass`, `JWT_SECRET=...change-in-production...`,
`CLIENT_SECRET` in `.env`). Before any real use: put TLS in front, rotate every
secret (and the `rmis-portal` client secret in Keycloak via Step 3 with the new
value), and remove the test users.
