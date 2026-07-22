#!/usr/bin/env bash
# Swap a freshly-copied mkcert cert/key into Traefik and reload it.
# Usage: apply-cert.sh [/path/to/new-cert.pem]
#   If no path is given, picks the newest *.pem in /tmp (excluding *-key.pem),
#   matching mkcert's default drop location and naming (foo+N.pem / foo+N-key.pem).
set -euo pipefail

DYNAMIC_YML="/home/bitforge/homelab/compose/traefik/config/dynamic.yml"
TRAEFIK_CERT_MOUNT_DEST="/certs"

NEW_CERT="${1:-}"
if [[ -z "$NEW_CERT" ]]; then
  NEW_CERT=$(ls -t /tmp/*.pem 2>/dev/null | grep -v -- '-key\.pem$' | head -n1 || true)
fi
if [[ -z "$NEW_CERT" || ! -f "$NEW_CERT" ]]; then
  echo "No new cert found in /tmp. Pass the path explicitly: apply-cert.sh /tmp/bitforge+3.pem" >&2
  exit 1
fi
NEW_KEY="${NEW_CERT%.pem}-key.pem"
if [[ ! -f "$NEW_KEY" ]]; then
  echo "Expected matching key at $NEW_KEY but it's missing." >&2
  exit 1
fi

echo "== New cert: $NEW_CERT =="
openssl x509 -in "$NEW_CERT" -noout -ext subjectAltName -enddate

echo
echo "== Resolving current certFile/keyFile from Traefik's dynamic config =="
CERT_CONTAINER_PATH=$(grep -m1 'certFile' "$DYNAMIC_YML" | sed 's/.*certFile:[[:space:]]*//')
KEY_CONTAINER_PATH=$(grep -m1 'keyFile' "$DYNAMIC_YML" | sed 's/.*keyFile:[[:space:]]*//')

TRAEFIK_CONTAINER=$(docker ps --filter name=traefik --format '{{.Names}}' | head -n1)
if [[ -z "$TRAEFIK_CONTAINER" ]]; then
  echo "traefik container not found/running." >&2
  exit 1
fi

MOUNT_SOURCE=$(docker inspect "$TRAEFIK_CONTAINER" --format \
  '{{range .Mounts}}{{if eq .Destination "'"$TRAEFIK_CERT_MOUNT_DEST"'"}}{{.Source}}{{end}}{{end}}')
if [[ -z "$MOUNT_SOURCE" ]]; then
  echo "Could not resolve host path for the $TRAEFIK_CERT_MOUNT_DEST mount on $TRAEFIK_CONTAINER." >&2
  exit 1
fi

CERT="$MOUNT_SOURCE/$(basename "$CERT_CONTAINER_PATH")"
KEY="$MOUNT_SOURCE/$(basename "$KEY_CONTAINER_PATH")"

echo "certFile: $CERT"
echo "keyFile:  $KEY"
if [[ ! -f "$CERT" || ! -f "$KEY" ]]; then
  echo "Resolved cert/key not found on host, aborting." >&2
  exit 1
fi

CERT_MODE=$(stat -c '%a' "$CERT")
KEY_MODE=$(stat -c '%a' "$KEY")

echo
echo "== Backing up and installing new cert/key (preserving existing perms: cert=$CERT_MODE key=$KEY_MODE) =="
cp "$CERT" "$CERT.bak"
cp "$KEY" "$KEY.bak"
cp "$NEW_CERT" "$CERT"
cp "$NEW_KEY" "$KEY"
chmod "$CERT_MODE" "$CERT"
chmod "$KEY_MODE" "$KEY"
echo "done."

echo
echo "== Restarting $TRAEFIK_CONTAINER (file-provider hot-reload isn't reliable for cert swaps) =="
docker restart "$TRAEFIK_CONTAINER" >/dev/null
sleep 3
echo "restarted."

echo
echo "== Verifying served cert per SAN host =="
ALL_OK=1
HOSTS=$(openssl x509 -in "$NEW_CERT" -noout -ext subjectAltName | grep -o 'DNS:[^,]*' | sed 's/DNS://')
NEW_ISSUER=$(openssl x509 -in "$NEW_CERT" -noout -issuer)
for h in $HOSTS; do
  echo "--- $h ---"
  SERVED=$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$h" 2>/dev/null | openssl x509 -noout -ext subjectAltName -issuer)
  echo "$SERVED"
  if ! echo "$SERVED" | grep -q "DNS:$h"; then
    echo "  !! $h is NOT covered by the served cert's SAN"
    ALL_OK=0
  fi
done

echo
if [[ "$ALL_OK" -eq 1 ]]; then
  echo "== All hosts verified against the new cert. Cleaning up source files in /tmp =="
  shred -u "$NEW_CERT" "$NEW_KEY" 2>/dev/null || rm -f "$NEW_CERT" "$NEW_KEY"
  echo "Removed $NEW_CERT and $NEW_KEY."
  echo
  echo "SUCCESS. Backups of the previous cert/key are at $CERT.bak / $KEY.bak"
else
  echo "!! Verification failed for at least one host. NOT cleaning up /tmp — investigate before retrying."
  exit 1
fi
