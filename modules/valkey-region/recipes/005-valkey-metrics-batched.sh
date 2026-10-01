#!/usr/bin/env bash
# Replaces valkey-metrics.sh on running nodes; files/valkey-metrics.sh stays as the
# boot copy because user-data must render byte-identical. One batched call per run on
# the boot timer's cadence, dimension InstanceId only, AUTH from valkey.conf.
set -euo pipefail

BIN=/usr/local/bin/valkey-metrics.sh
PREV=/var/tmp/valkey-metrics.sh.prev
TIMER=valkey-metrics.timer

if [ ! -f "/etc/systemd/system/$TIMER" ]; then
  echo "no $TIMER on this node (arbiter); nothing to replace"
  exit 0
fi

NEW="$(mktemp /var/tmp/valkey-metrics.XXXXXX)"
trap 'rm -f "$NEW"' EXIT

cat >"$NEW" <<'SCRIPT'
#!/bin/bash
# Valkey INFO metrics in one PutMetricData per run, dimension InstanceId.
# Installed by valkey-region recipe 005; files/valkey-metrics.sh is only the boot copy.
set -euo pipefail

CONF=/etc/valkey/valkey.conf
AUTH="$(awk '/^requirepass /{gsub(/^"|"$/,"",$2); print $2; exit}' "$CONF")"
CLI=(valkey-cli -a "$AUTH" --no-auth-warning)
if grep -q '^tls-port ' "$CONF"; then
  CLI+=(--tls --cacert /etc/valkey/tls/ca.crt --cert /etc/valkey/tls/node.crt --key /etc/valkey/tls/node.key)
fi

INFO="$("${CLI[@]}" INFO | tr -d '\r')"
val() { awk -F: -v k="$1" '$1 == k {print $2; exit}' <<<"$INFO"; }
ROLE="$(val role)"
[ -n "$ROLE" ] || { echo "INFO returned no role" >&2; exit 1; }

TOKEN="$(curl -sf -X PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')"
IID="$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)"

DATA='[]'
add() {
  DATA="$(jq -c --arg n "$1" --argjson v "$2" --arg u "$3" --arg i "$IID" \
    '. + [{MetricName: $n, Value: $v, Unit: $u, Dimensions: [{Name: "InstanceId", Value: $i}]}]' <<<"$DATA")"
}

MAXMEM="$(val maxmemory)"
if [ "${MAXMEM:-0}" -gt 0 ]; then
  add MaxmemoryUsedPercent "$(awk -v u="$(val used_memory)" -v m="$MAXMEM" 'BEGIN {printf "%.2f", 100 * u / m}')" Percent
fi

case "$ROLE" in
  slave | replica)
    LINK=0
    [ "$(val master_link_status)" = up ] && LINK=1
    add MasterLinkUp "$LINK" None
    # Age of the master's heartbeat as replicated here; 0-60 s when healthy.
    HB="$("${CLI[@]}" GET meandr:repl:heartbeat 2>/dev/null || true)"
    if [[ "$HB" =~ ^[0-9]+$ ]]; then
      add ReplicationLagSeconds "$(($(date +%s) - HB))" Seconds
    fi
    ;;
  *)
    REPLICAS="$(val connected_slaves)"
    add ConnectedReplicas "${REPLICAS:-0}" Count
    if [ "${REPLICAS:-0}" -gt 0 ]; then
      "${CLI[@]}" SET meandr:repl:heartbeat "$(date +%s)" >/dev/null 2>&1 || true
    fi
    ;;
esac

aws cloudwatch put-metric-data --namespace meandr/valkey --metric-data "$DATA"
SCRIPT

if cmp -s "$NEW" "$BIN"; then
  echo "metrics script already batched"
  exit 0
fi

# Timer stopped for the swap so the trial run below is the new script's own;
# the trap restarts it on every exit path.
trap 'rm -f "$NEW"; systemctl start "$TIMER" || true' EXIT
systemctl stop "$TIMER"
for _ in $(seq 30); do
  [ "$(systemctl show -p ActiveState --value valkey-metrics.service)" = activating ] || break
  sleep 1
done
# A start now would join the old run and report its result as the new script's.
if [ "$(systemctl show -p ActiveState --value valkey-metrics.service)" = activating ]; then
  echo "old metrics run still going after 30 s; not swapping under it" >&2
  exit 1
fi

cp -p "$BIN" "$PREV"
install -m 0755 "$NEW" "$BIN.new"
mv -f "$BIN.new" "$BIN"
if ! systemctl start valkey-metrics.service; then
  mv -f "$PREV" "$BIN"
  echo "new metrics script failed its first run; previous one restored" >&2
  journalctl -u valkey-metrics.service -n 20 --no-pager >&2 || true
  exit 1
fi
rm -f "$PREV"

systemctl start "$TIMER"
systemctl is-active --quiet "$TIMER"

echo "metrics script batched (InstanceId only); first run published"
