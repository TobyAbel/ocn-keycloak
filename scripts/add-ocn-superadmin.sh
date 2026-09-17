#!/usr/bin/env bash
#
# add-ocn-superadmin.sh — B6 (council lifecycle) Keycloak prerequisites.
#
# >>> HUMAN-RUN against PRODUCTION Keycloak. Not part of any deploy. <<<
#
# This script performs three LIVE, idempotent operations on the `ocn` realm:
#   1) create the realm role `ocn-superadmin` (the sole non-council-scoped meta
#      role — add/edit councils);
#   2) assign `ocn-superadmin` to the platform owner (default toby@gearhart.co.uk);
#   3) grant the `civicos-admin` service account (`service-account-civicos-admin`)
#      the `realm-management` client role `manage-realm`, so the portal can create
#      per-council realm roles at runtime via the Admin API.
#
# Why a script instead of realm import: Keycloak's `--import-realm` only creates a
# realm on first boot; it will NOT update a realm that already exists. `ocn` already
# exists in production, so these changes are applied with kcadm. Re-running is safe:
# the role create ignores "already exists", and `add-roles` is naturally idempotent.
#
# AFTER running this, re-export + sanitise the snapshot per docs/realm-management.md
# so `ocn-superadmin` lands in realm/ocn-realm.json's roles.realm array. The
# service-account grant will NOT appear in the snapshot (users/service-accounts are
# stripped on export) — it is documented in docs/realm-management.md instead.
# Verify the re-export with:  jq '.users | length' realm/ocn-realm.json  ->  0
#
# Usage (on the Keycloak VM, or anywhere kcadm can reach the server):
#   KC_ADMIN=admin KC_ADMIN_PASSWORD=... ./scripts/add-ocn-superadmin.sh
#   # optionally target a different owner:
#   KC_ADMIN=admin KC_ADMIN_PASSWORD=... OWNER_USERNAME=someone@example.org \
#     ./scripts/add-ocn-superadmin.sh
#
# Env vars:
#   KC_SERVER          default http://localhost:8080   (use the local port on the VM)
#   KC_REALM           default ocn
#   KC_ADMIN           default admin                   (master-realm admin user)
#   KC_ADMIN_PASSWORD  if unset, kcadm prompts interactively
#   KCADM              default /opt/keycloak/bin/kcadm.sh
#   OWNER_USERNAME     default toby@gearhart.co.uk     (who gets ocn-superadmin)
#
# No secrets are printed or committed by this script.

set -euo pipefail

KC_SERVER="${KC_SERVER:-http://localhost:8080}"
KC_REALM="${KC_REALM:-ocn}"
KC_ADMIN="${KC_ADMIN:-admin}"
KCADM="${KCADM:-/opt/keycloak/bin/kcadm.sh}"
OWNER_USERNAME="${OWNER_USERNAME:-toby@gearhart.co.uk}"

SUPERADMIN_ROLE="ocn-superadmin"
SUPERADMIN_DESC="Council lifecycle super-admin (B6): add/edit councils. The only non-council-scoped role."
SERVICE_ACCOUNT="service-account-civicos-admin"
MGMT_CLIENT="realm-management"
MGMT_ROLE="manage-realm"

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

# ---------------------------------------------------------------------------
# 1) Create the meta role (idempotent — tolerate "already exists" / 409).
# ---------------------------------------------------------------------------
echo ">> [1/3] ensuring realm role '$SUPERADMIN_ROLE' exists on realm '$KC_REALM'"
if "$KCADM" get "roles/$SUPERADMIN_ROLE" -r "$KC_REALM" >/dev/null 2>&1; then
  echo "   role '$SUPERADMIN_ROLE' already exists — leaving as-is"
else
  if "$KCADM" create roles -r "$KC_REALM" \
       -s "name=$SUPERADMIN_ROLE" \
       -s "description=$SUPERADMIN_DESC"; then
    echo "   created role '$SUPERADMIN_ROLE'"
  else
    # Race / pre-existing: re-check rather than fail the whole run.
    if "$KCADM" get "roles/$SUPERADMIN_ROLE" -r "$KC_REALM" >/dev/null 2>&1; then
      echo "   role '$SUPERADMIN_ROLE' already exists — continuing"
    else
      echo "error: failed to create role '$SUPERADMIN_ROLE'" >&2
      exit 1
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 2) Assign ocn-superadmin to the platform owner (add-roles is idempotent).
# ---------------------------------------------------------------------------
echo ">> [2/3] assigning '$SUPERADMIN_ROLE' to owner '$OWNER_USERNAME'"
"$KCADM" add-roles -r "$KC_REALM" \
  --uusername "$OWNER_USERNAME" \
  --rolename "$SUPERADMIN_ROLE"
echo "   ensured '$OWNER_USERNAME' has '$SUPERADMIN_ROLE'"

# ---------------------------------------------------------------------------
# 3) Grant the civicos-admin service account manage-realm so the portal can
#    create per-council realm roles at runtime (add-roles is idempotent).
# ---------------------------------------------------------------------------
echo ">> [3/3] granting '$SERVICE_ACCOUNT' the '$MGMT_CLIENT' role '$MGMT_ROLE'"
"$KCADM" add-roles -r "$KC_REALM" \
  --uusername "$SERVICE_ACCOUNT" \
  --cclientid "$MGMT_CLIENT" \
  --rolename "$MGMT_ROLE"
echo "   ensured '$SERVICE_ACCOUNT' has '$MGMT_CLIENT:$MGMT_ROLE'"

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
echo
echo ">> verification"

echo "   - role '$SUPERADMIN_ROLE' present:"
if "$KCADM" get roles -r "$KC_REALM" --fields name | grep -q "\"$SUPERADMIN_ROLE\""; then
  echo "     OK"
else
  echo "     MISSING — investigate" >&2
fi

echo "   - owner '$OWNER_USERNAME' has '$SUPERADMIN_ROLE' (effective):"
if "$KCADM" get-roles -r "$KC_REALM" --uusername "$OWNER_USERNAME" --effective --fields name \
     | grep -q "\"$SUPERADMIN_ROLE\""; then
  echo "     OK"
else
  echo "     MISSING — investigate" >&2
fi

echo "   - service account '$SERVICE_ACCOUNT' has '$MGMT_CLIENT:$MGMT_ROLE':"
if "$KCADM" get-roles -r "$KC_REALM" --uusername "$SERVICE_ACCOUNT" \
     --cclientid "$MGMT_CLIENT" --fields name \
     | grep -q "\"$MGMT_ROLE\""; then
  echo "     OK"
else
  echo "     MISSING — investigate" >&2
fi

echo
echo ">> done."
echo ">> NEXT: re-export + sanitise the snapshot so '$SUPERADMIN_ROLE' lands in"
echo "         realm/ocn-realm.json (see docs/realm-management.md). The"
echo "         '$SERVICE_ACCOUNT' grant will NOT appear in the snapshot"
echo "         (service accounts are stripped) — it is documented instead."
echo ">> NOTE: the owner must sign out/in of the portal to pick up '$SUPERADMIN_ROLE'"
echo "         in their token before the Councils admin becomes reachable."
