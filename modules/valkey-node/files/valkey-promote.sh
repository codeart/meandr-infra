#!/bin/bash
# Sentinel's client-reconfig-script: repoint the master DNS record on
# promotion.
#
# This is how replicas in OTHER regions learn the master moved. They run
# no Sentinel of their own — deliberately, since a Sentinel across a WAN
# votes in quorum and turns a transatlantic blip into a false promotion —
# so nothing tells them directly. They follow the record instead, and
# re-resolve on reconnect.
#
# Sentinel invokes this with:
#   $1 master-name  $2 role  $3 state  $4 from-ip  $5 from-port
#   $6 to-ip        $7 to-port
#
# Env comes from the systemd drop-in: ZONE_ID, MASTER_RECORD,
# AWS_DEFAULT_REGION.
set -euo pipefail
exec >>/var/log/valkey/promote.log 2>&1

echo "$(date -Is) reconfig: $*"

# Sentinel calls every observer, not only the one that ran the failover.
# Without this guard each of them would race to write the same record.
[ "${2:-}" = "leader" ] || exit 0

# Sentinel announces hostnames, so $6 is the new master's own stable name.
# An IP here means announce-hostnames is not in effect and the record would
# become an A record pointing at a node we cannot name.
NEW_MASTER="${6:-}"
case "$NEW_MASTER" in
  "" | *[!0-9.]*) ;;
  *)
    echo "$(date -Is) '$NEW_MASTER' is an address, not a name; refusing"
    exit 1
    ;;
esac

aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --change-batch "$(cat <<JSON
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$MASTER_RECORD",
      "Type": "CNAME",
      "TTL": 5,
      "ResourceRecords": [{"Value": "$NEW_MASTER"}]
    }
  }]
}
JSON
)"

echo "$(date -Is) repointed $MASTER_RECORD -> $NEW_MASTER"
