# Realm management (`ocn`)

Keycloak's `ocn` realm is configured **live** (admin console + `kcadm.sh`). This
directory version-controls a **sanitised snapshot** of that realm so we have an
auditable source of truth, a disaster-recovery reference, and a reviewable record
of client/role changes.

- Snapshot: [`../realm/ocn-realm.json`](../realm/ocn-realm.json)
- Portal client bootstrap: [`../scripts/add-civicos-portal-client.sh`](../scripts/add-civicos-portal-client.sh)

> **Important — this snapshot is not auto-applied.** Keycloak's `--import-realm`
> only *creates* a realm on first boot; it will **not** update a realm that already
> exists. `ocn` already exists in production, so changes are applied to the live
> realm with `kcadm` (see below), and the snapshot is refreshed afterwards to match.

## What is (and isn't) in the snapshot

The committed `ocn-realm.json` is a `partial-export` (clients + roles + groups +
realm settings). It is **sanitised** — the following are stripped or replaced with
`${PLACEHOLDER}` values and must never be committed in cleartext:

| Removed / placeholdered | Why |
|---|---|
| `users` | credentials + PII |
| `components["org.keycloak.keys.KeyProvider"]` | realm signing private keys (Keycloak regenerates on import) |
| every confidential client `secret` | secret material |
| `smtpServer.password` | secret material |
| `saml.signing.private.key` / `saml.encryption.private.key` | secret material |

Public certificates (e.g. `saml.signing.certificate`) are kept — they are not secret.

## Re-exporting the realm (read-only, no downtime)

Run on the Keycloak VM. `partial-export` hits the admin REST API and needs **no
restart** — do **not** use `kc.sh export`, which boots a second instance against the
production database.

```bash
cd /opt/keycloak
CONF=/opt/keycloak/conf/keycloak.conf
AU=$(sudo grep -E "^[[:space:]]*admin[[:space:]]*=" "$CONF" | head -1 | cut -d= -f2- | tr -d " ")
AP=$(sudo grep -E "^[[:space:]]*admin-password[[:space:]]*=" "$CONF" | head -1 | cut -d= -f2- | tr -d " ")

./bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user "$AU" --password "$AP"
./bin/kcadm.sh create partial-export -r ocn \
  -q exportClients=true -q exportGroupsAndRoles=true -o > /tmp/ocn-realm-export.json
```

Pull it off the VM, then **delete `/tmp/ocn-realm-export.json`** (it contains
cleartext secrets and users).

```bash
gcloud compute scp --tunnel-through-iap --project=ocn-constitution-manager \
  --zone=europe-west2-c keycloak:/tmp/ocn-realm-export.json ./ocn-realm-export.raw.json
gcloud compute ssh keycloak --tunnel-through-iap --project=ocn-constitution-manager \
  --zone=europe-west2-c --command='rm -f /tmp/ocn-realm-export.json'
```

## Sanitising a fresh export before committing

```bash
jq '
    del(.users)
  | del(.components["org.keycloak.keys.KeyProvider"])
  | (if .smtpServer.password? then .smtpServer.password = "${SMTP_PASSWORD}" else . end)
  | .clients |= map( if .secret != null
        then .secret = "${" + (.clientId|ascii_upcase|gsub("[^A-Z0-9]";"_")) + "_CLIENT_SECRET}"
        else . end )
  | .clients |= map( if .attributes then .attributes |= (
        (if .["saml.signing.private.key"] then .["saml.signing.private.key"] = "${SAML_SIGNING_PRIVATE_KEY}" else . end)
      | (if .["saml.encryption.private.key"] then .["saml.encryption.private.key"] = "${SAML_ENCRYPTION_PRIVATE_KEY}" else . end)
    ) else . end )
' ocn-realm-export.raw.json > ../realm/ocn-realm.json
```

Verify before committing: `jq '.users|length' realm/ocn-realm.json` → `0`, and no
`BEGIN`/`MII…` strings remain except public certificates.

## Applying the portal client to the live realm

```bash
# on the VM, or anywhere kcadm can reach the server:
KC_ADMIN=admin KC_ADMIN_PASSWORD=... ./scripts/add-civicos-portal-client.sh
```

Idempotent — creates `civicos-portal` if absent, updates it in place otherwise. It
prints the generated client secret; put that in the portal's `AUTH_KEYCLOAK_SECRET`.
After applying, re-export + re-sanitise so the snapshot reflects reality.

## Cleanup / hardening backlog (observed in the current realm)

- `bruteForceProtected: false` — no brute-force lockout on the realm.
- `ocn-constitution-admin` has a sprawling redirect-URI list (mixes cms / cms2 /
  constitution hosts + several localhost ports + loose bare-origin entries) — tighten.
- Stale `cms2.opencouncil.network` redirect URIs coexist with `cms.opencouncil.network`.
- Group name typo: `Tower Hamets` (alongside `Tower Hamlets Admins`/`Editors`).
- Realm login theme is `keycloak.v2`; the repo's custom `leos-theme` is not the
  active realm login theme — reconcile.
