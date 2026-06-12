#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# update_clients.sh — register / repoint the `rmis-portal` OAuth client to the
# 10.10.73.8 URLs, in the already-running SSO stack's Keycloak.
#
# Why this exists:
#   RMIS authenticates against the GoR SSO wrapper, which validates client
#   secret + redirect URIs by querying Keycloak directly (client_service
#   ._get_raw_client). So rmis-portal needs no wrapper-side config — it only has
#   to EXIST in the `government-internal` realm with the right secret and the
#   10.10.73.8 redirect URIs. The realm import only carries localhost URIs (and
#   may not define rmis-portal at all), so we reconcile it here.
#
# Idempotent: the client is created if absent; redirect URIs / web origins /
# post-logout URIs / secret are SET (not appended), so re-running after a URL or
# secret change converges cleanly.
#
# Run this ON THE SERVER, AFTER the SSO stack is up and Keycloak is healthy:
#   set -a; . ./.env; set +a
#   bash ./update_clients.sh
#
# If the host moves, override SERVER_IP (or the *_BASE_URL vars):
#   SERVER_IP=10.10.73.9 bash ./update_clients.sh
# ---------------------------------------------------------------------------
set -euo pipefail

# --- config (overridable via env) ------------------------------------------
REALM=${KEYCLOAK_REALM:-government-internal}
KC_USER=${KEYCLOAK_ADMIN:-admin}
KC_PASS=${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD must be set (see .env)}
KCADM_SERVER=${KCADM_SERVER:-http://localhost:8080}   # localhost = inside the keycloak container

SERVER_IP=${SERVER_IP:-10.10.73.8}
# Backend (Spring) host port — Spring's callback convention is
#   http://<backend-host>:<port>/login/oauth2/code/<registrationId>  (registrationId=gor)
BACKEND_BASE_URL=${BACKEND_BASE_URL:-http://$SERVER_IP:8085}
# SPA (nginx) host — served on :80; the post-logout landing page is /login.
FRONTEND_BASE_URL=${FRONTEND_BASE_URL:-http://$SERVER_IP}

# Client secret — MUST match what the RMIS backend is configured with (.env).
CLIENT_SECRET=${CLIENT_SECRET:?CLIENT_SECRET must be set (see .env)}

# Locate the running SSO Keycloak container (sso-deploy-bundle compose project).
KC_CONTAINER=${KC_CONTAINER:-$(docker ps --filter name=keycloak --format '{{.Names}}' | head -n1)}
[ -n "$KC_CONTAINER" ] || { echo "ERROR: no running container matched name 'keycloak'. Is the SSO stack up? Override with KC_CONTAINER=<name>."; exit 1; }
echo "Using Keycloak container: $KC_CONTAINER"

# --- helpers ---------------------------------------------------------------
kc() { docker exec -i "$KC_CONTAINER" /opt/keycloak/bin/kcadm.sh "$@"; }

client_uuid() {
  kc get clients -r "$REALM" -q clientId="$1" --fields id --format csv --noquotes \
    2>/dev/null | tr -d '\r' | head -n1
}

# --- run -------------------------------------------------------------------
echo "Reconciling 'rmis-portal' in realm '$REALM' via $KCADM_SERVER ..."
kc config credentials --server "$KCADM_SERVER" \
  --realm master --user "$KC_USER" --password "$KC_PASS"

REDIRECTS="[\"$BACKEND_BASE_URL/login/oauth2/code/gor\",\"$BACKEND_BASE_URL/*\"]"
ORIGINS="[\"$FRONTEND_BASE_URL\",\"$BACKEND_BASE_URL\"]"
# Keycloak stores post-logout URIs as a '##'-separated attribute list.
POSTLOGOUT="$FRONTEND_BASE_URL/login##$FRONTEND_BASE_URL/*"

uuid="$(client_uuid rmis-portal)"
if [ -z "$uuid" ]; then
  echo "  + creating client 'rmis-portal'"
  kc create clients -r "$REALM" \
    -s clientId=rmis-portal \
    -s enabled=true \
    -s protocol=openid-connect \
    -s publicClient=false \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false \
    -s secret="$CLIENT_SECRET" \
    -s "redirectUris=$REDIRECTS" \
    -s "webOrigins=$ORIGINS" \
    -s "attributes.\"post.logout.redirect.uris\"=$POSTLOGOUT" >/dev/null
else
  echo "  ~ updating client 'rmis-portal' ($uuid)"
  kc update "clients/$uuid" -r "$REALM" \
    -s "redirectUris=$REDIRECTS" \
    -s "webOrigins=$ORIGINS" \
    -s "attributes.\"post.logout.redirect.uris\"=$POSTLOGOUT" \
    -s secret="$CLIENT_SECRET" >/dev/null
fi

echo "Done. rmis-portal reconciled:"
echo "  redirect      -> $BACKEND_BASE_URL/login/oauth2/code/gor"
echo "  web origins   -> $FRONTEND_BASE_URL , $BACKEND_BASE_URL"
echo "  post-logout   -> $FRONTEND_BASE_URL/login"
