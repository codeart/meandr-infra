#!/bin/bash
# Point-in-time RDB, taken from the REPLICA and uploaded to S3.
#
# `valkey-cli --rdb` performs a replica-style full sync: the server forks and
# streams a consistent snapshot. It never reads the node's own AOF, so it
# cannot catch a rewrite mid-flight the way a volume snapshot can — the
# manifest of a multi-part AOF may reference a base file still being written.
#
# Replica only. The fork's copy-on-write spike then lands on the node that is
# not taking writes, and the master keeps serving.
#
# Env comes from the systemd unit: AUTH_SECRET, BACKUP_BUCKET, FLEET,
# AWS_DEFAULT_REGION.
set -euo pipefail

AUTH="$(aws secretsmanager get-secret-value \
  --secret-id "$AUTH_SECRET" --query SecretString --output text)"

TLS="--tls --cacert /etc/valkey/tls/ca.crt
     --cert /etc/valkey/tls/node.crt --key /etc/valkey/tls/node.key"

ROLE="$(valkey-cli $TLS -a "$AUTH" --no-auth-warning INFO replication \
  | tr -d '\r' | awk -F: '/^role:/ {print $2; exit}')"

if [ "$ROLE" != "slave" ]; then
  echo "role=$ROLE — backups run on the replica; nothing to do"
  exit 0
fi

OUT="/var/tmp/valkey-backup.rdb"
trap 'rm -f "$OUT"' EXIT

# /var/tmp, not /tmp: /tmp is tmpfs and sized by instance memory.
rm -f "$OUT"
valkey-cli $TLS -a "$AUTH" --no-auth-warning --rdb "$OUT"

KEY="$FLEET/$(date -u +%Y/%m/%d)/dump-$(date -u +%Y%m%dT%H%M%SZ).rdb"
aws s3 cp "$OUT" "s3://$BACKUP_BUCKET/$KEY"
echo "uploaded s3://$BACKUP_BUCKET/$KEY ($(stat -c %s "$OUT") bytes)"
