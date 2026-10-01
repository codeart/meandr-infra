#!/usr/bin/env bash
# Agent keep-list: mem_used_percent, swap_used_percent, disk_used_percent (/)
# at 60 s. CPU and network come free as AWS/EC2; procstat is gone with 003.
# Same mechanics as 003: jq-edit a copy, fetch-config it, prove it took.
set -euo pipefail

CTL=/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl
CONF_DIR=/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.d
TOML=/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.toml
TMP=/var/tmp/cwagent-trimmed.json

if [ ! -x "$CTL" ]; then
  echo "no CloudWatch agent installed; nothing to trim"
  exit 0
fi

mapfile -t CONFS < <(find "$CONF_DIR" -name '*.json' -type f 2>/dev/null)
if [ "${#CONFS[@]}" -ne 1 ]; then
  echo "expected one agent config under $CONF_DIR, found ${#CONFS[@]}" >&2
  exit 1
fi
CONF="${CONFS[0]}"

keep_list() {
  jq -e '(.metrics.metrics_collected | keys) == ["disk", "mem", "swap"]
    and .agent.metrics_collection_interval == 60
    and .metrics.namespace == "meandr/valkey"
    and .metrics.append_dimensions.InstanceId == "${aws:InstanceId}"' "$1" >/dev/null 2>&1
}

# The whole collected set is replaced, so data nodes and arbiters converge
# on the same config whatever 003 left behind.
jq '
  .agent.metrics_collection_interval = 60
| .metrics.force_flush_interval = 60
| .metrics.metrics_collected = {
    mem:  { measurement: ["mem_used_percent"] },
    swap: { measurement: ["swap_used_percent"] },
    disk: { measurement: ["used_percent"], resources: ["/"] }
  }
' "$CONF" >"$TMP"

[ -s "$TMP" ] || { echo "jq produced no output; leaving config untouched" >&2; rm -f "$TMP"; exit 1; }
if ! keep_list "$TMP"; then
  echo "edited config lacks the keep-list, namespace or InstanceId; leaving config untouched" >&2
  rm -f "$TMP"
  exit 1
fi

# The agent runs the generated TOML, so a JSON newer than it was never translated
# (a fetch-config that failed after writing it); that case reloads below.
if cmp -s "$CONF" "$TMP" && [ ! "$CONF" -nt "$TOML" ]; then
  rm -f "$TMP"
  if ! "$CTL" -a status | jq -e '.status == "running"' >/dev/null; then
    echo "config is on the keep-list but the agent is not running" >&2
    exit 1
  fi
  echo "already on the keep-list"
  exit 0
fi

"$CTL" -a fetch-config -m ec2 -s -c "file:$TMP" >/dev/null
rm -f "$TMP"

NEW="$(find "$CONF_DIR" -name '*.json' -type f 2>/dev/null | head -1)"
if ! keep_list "$NEW"; then
  echo "agent config is not the keep-list after reload" >&2
  exit 1
fi
if ! "$CTL" -a status | jq -e '.status == "running"' >/dev/null; then
  echo "agent not running after reload" >&2
  exit 1
fi

echo "agent on keep-list (mem, swap, disk at 60s); reloaded"
