#!/bin/bash
# The Valkey-specific metrics the CloudWatch agent cannot see.
#
# The agent covers CPU, memory, disk, network and procstat — all OS-level.
# What it has no idea about is INFO output, and that is where the numbers
# that actually describe replication live.
#
# MasterLinkUp is the one that matters most, and the reason this script
# exists at all: a replica whose link is down keeps serving its last known
# state indefinitely, so from a client's side stale and healthy look
# identical. Every other value here is a gauge; that one is a boolean
# which quietly invalidates all of them.
#
# EvictedKeys must be zero. Non-zero means maxmemory-policy is not
# noeviction, which breaks the durability contract the eventbus asserts at
# startup — a cheap canary for an expensive mistake.
#
# Env comes from the systemd unit: AUTH_SECRET, AWS_DEFAULT_REGION.
set -euo pipefail

AUTH="$(aws secretsmanager get-secret-value \
  --secret-id "$AUTH_SECRET" --query SecretString --output text)"

INFO="$(valkey-cli --tls --cacert /etc/valkey/tls/ca.crt \
  --cert /etc/valkey/tls/node.crt --key /etc/valkey/tls/node.key \
  -a "$AUTH" --no-auth-warning INFO 2>/dev/null)"

# IMDSv2 — the instance enforces tokens, so the unauthenticated form fails.
TOKEN="$(curl -sX PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')"
IID="$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)"

val() { echo "$INFO" | tr -d '\r' | awk -F: -v k="$1" '$1 == k {print $2; exit}'; }

# Reported role, not the configured one. A node launched as master may be
# a replica by now; publishing what it was told to be would describe the
# wrong box on exactly the day it changed.
ROLE="$(val role)"

put() {
  aws cloudwatch put-metric-data --namespace meandr/valkey \
    --metric-name "$1" --value "$2" --unit "$3" \
    --dimensions "InstanceId=$IID,Role=$ROLE"
}

put UsedMemory "$(val used_memory)" Bytes
put EvictedKeys "$(val evicted_keys)" Count
put ConnectedClients "$(val connected_clients)" Count

if [ "$ROLE" = "slave" ]; then
  if [ "$(val master_link_status)" = "up" ]; then
    put MasterLinkUp 1 None
  else
    put MasterLinkUp 0 None
  fi
  put MasterLastIO "$(val master_last_io_seconds_ago)" Seconds

  # Bytes behind, which is the exact measure: seconds since last IO can
  # look healthy on an idle link that is actually broken.
  MOFF="$(val master_repl_offset)"
  SOFF="$(val slave_read_repl_offset)"
  put ReplicationLagBytes "$(( ${MOFF:-0} - ${SOFF:-0} ))" Bytes

  # Lag in SECONDS, from a heartbeat the master stamps on every run.
  #
  # Redis exposes no such number, so this derives it: the replica reads
  # its own copy of the key and subtracts. What it measures is how stale
  # this replica's view is, which is the question that matters for a
  # config projection.
  #
  # The floor is the heartbeat interval — with a 60s timer a healthy
  # replica reads anywhere from 0-60s, so this CANNOT see sub-second WAN
  # lag and should not be alarmed on tightly. It catches the failure that
  # matters: replication minutes or hours behind. Use ReplicationLagBytes
  # for precision.
  HB="$(valkey-cli --tls --cacert /etc/valkey/tls/ca.crt \
  --cert /etc/valkey/tls/node.crt --key /etc/valkey/tls/node.key \
    -a "$AUTH" --no-auth-warning GET meandr:repl:heartbeat 2>/dev/null || true)"
  if [ -n "$HB" ]; then
    put ReplicationLagSeconds "$(( $(date +%s) - HB ))" Seconds
  fi
else
  # A replica silently dropping off is invisible from the master unless
  # somebody counts them.
  put ConnectedReplicas "$(val connected_slaves)" Count

  # Stamped by the master only. Replicas read their replicated copy above
  # to derive staleness — writing it anywhere else would measure the local
  # clock against itself.
  #
  # WAIT blocks until a replica ACKNOWLEDGES the write, so timing this
  # measures the replication round trip rather than the age of a
  # heartbeat. Both commands go down ONE connection, so the TLS handshake
  # is paid before the clock starts rather than inside the measurement.
  #
  # Resolution is milliseconds with a few ms of noise from process start
  # and the round trip itself — enough to see a link degrade, NOT enough
  # to reproduce the sub-millisecond figure ElastiCache reports. That
  # needs a resident process holding a connection open; this is a timer
  # firing a CLI once a minute. Alarm on tens of ms, not on ones.
  START="$(date +%s%3N)"
  printf 'SET meandr:repl:heartbeat %s\nWAIT 1 1000\n' "$(date +%s)" \
    | valkey-cli --tls --cacert /etc/valkey/tls/ca.crt \
  --cert /etc/valkey/tls/node.crt --key /etc/valkey/tls/node.key \
        -a "$AUTH" --no-auth-warning >/dev/null 2>&1 || true
  END="$(date +%s%3N)"
  put ReplicationAckMs "$(( END - START ))" Milliseconds
fi
