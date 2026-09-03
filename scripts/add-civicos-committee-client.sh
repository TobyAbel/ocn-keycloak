#!/usr/bin/env bash
#
# add-civicos-committee-client.sh — idempotently create/update the
# `civicos-committee` OIDC client on the live `ocn` realm.
#
# Why a script instead of realm import: Keycloak's `--import-realm` only creates a
# realm on first boot; it will NOT update a realm that already exists. `ocn` already
# exists in production, so declarative client changes are applied with kcadm instead.
# Running this repeatedly is safe — it updates in place if the client is already there.
#
# Usage (on the Keycloak VM, or anywhere kcadm can reach the server):
#   KC_ADMIN=admin KC_ADMIN_PASSWORD=... ./scripts/add-civicos-committee-client.sh
#
# Env vars:
#   KC_SERVER          default http://localhost:8080   (use the local port on the VM)
#   KC_REALM           default ocn
#   KC_ADMIN           default admin                   (master-realm admin user)
#   KC_ADMIN_PASSWORD  if unset, kcadm prompts interactively
#   KCADM              default /opt/keycloak/bin/kcadm.sh
#
# On success it prints the client secret — copy it into Committees'
# AUTH_KEYCLOAK_SECRET (Auth.js) env var. The secret is NEVER committed; the
# realm/ocn-realm.json snapshot only holds a ${CIVICOS_COMMITTEE_CLIENT_SECRET}
# placeholder.

set -euo pipefail

KC_SERVER="${KC_SERVER:-http://localhost:8080}"
KC_REALM="${KC_REALM:-ocn}"
KC_ADMIN="${KC_ADMIN:-admin}"
KCADM="${KCADM:-/opt/keycloak/bin/kcadm.sh}"
CLIENT_ID="civicos-committee"

if [ ! -x "$KCADM" ]; then
  echo "error: kcadm.sh not found/executable at '$KCADM' (set KCADM=...)" >&2
  exit 1
fi

echo ">> authenticating to $KC_SERVER (master realm) as $KC_ADMIN"
if [ -n "${KC_ADMIN_PASSWORD:-}" ]; then
  "$KCADM" config credentials --server "$KC_SERVER" --realm master --user "$KC_ADMIN" --password "$KC_ADMIN_PASSWORD"
else
  "$KCADM" config credentials --server "$KC_SERVER" --realm master --user "$KC_ADMIN"
fi

# Desired client representation. Kept in sync with realm/ocn-realm.json, minus the
# secret (Keycloak generates/keeps that server-side).
REP=$(cat <<'JSON'
{
  "clientId": "civicos-committee",
  "name": "CivicOS Committees",
  "description": "CivicOS Committees (Next.js + Auth.js) — decisions, calendar, sittings.",
  "protocol": "openid-connect",
  "enabled": true,
  "publicClient": false,
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": false,
  "rootUrl": "https://committees.ocn.technology",
  "baseUrl": "https://committees.ocn.technology",
  "adminUrl": "https://committees.ocn.technology",
  "redirectUris": [
    "https://committees.ocn.technology/api/auth/callback/keycloak",
    "http://localhost:3001/api/auth/callback/keycloak"
  ],
  "webOrigins": [
    "https://committees.ocn.technology",
    "http://localhost:3001"
  ],
  "attributes": {
    "post.logout.redirect.uris": "https://committees.ocn.technology/*##http://localhost:3001/*",
    "pkce.code.challenge.method": "S256"
  },
  "fullScopeAllowed": true
}
JSON
)

# Look up any existing client with this clientId (parse the id out of the JSON,
# no jq dependency on the server).
EXISTING_ID=$("$KCADM" get clients -r "$KC_REALM" -q clientId="$CLIENT_ID" --fields id 2>/dev/null \
  | grep -o '"id"[^,]*' | head -1 | sed -E 's/.*"id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)

if [ -n "$EXISTING_ID" ]; then
  echo ">> updating existing client $CLIENT_ID ($EXISTING_ID)"
  printf '%s' "$REP" | "$KCADM" update "clients/$EXISTING_ID" -r "$KC_REALM" -f -
  ID="$EXISTING_ID"
else
  echo ">> creating client $CLIENT_ID"
  ID=$(printf '%s' "$REP" | "$KCADM" create clients -r "$KC_REALM" -f - -i)
fi

echo ">> done. client uuid: $ID"
echo ">> client secret (copy into Committees AUTH_KEYCLOAK_SECRET):"
"$KCADM" get "clients/$ID/client-secret" -r "$KC_REALM" --fields value \
  | grep -o '"value"[^,}]*' | sed -E 's/.*"value"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
