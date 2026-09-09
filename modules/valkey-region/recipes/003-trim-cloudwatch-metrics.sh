#!/usr/bin/env bash
# Drop redundant CloudWatch metrics: mem_available, swap_used, and procstat
# (double-counted, since valkey-sentinel is a symlink to valkey-server).
# Billing is per name PER NODE, so each costs nine metrics, not one.
#
# Two non-obvious agent behaviours:
#   1. `fetch-config` MOVES the JSON into file_<name>.json; the path
#      userdata wrote to no longer exists afterwards.
#   2. The agent reads the GENERATED .toml, so editing JSON in place does
#      nothing until fetch-config regenerates.
#
# Hence: jq-edit a copy and hand it to fetch-config. jq rather than a
# rewrite so one recipe serves both node shapes without duplicating either.
#
# Userdata is deliberately NOT changed — that would replace all nine nodes.
# A node built later comes up untrimmed and replays this from the backlog.
set -euo pipefail

CTL=/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl
CONF_DIR=/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.d

# No agent is a legitimate no-op. An agent installed with no findable
# config is not — that means an assumption here is wrong, and exiting 0
# would hide it.
if [ ! -x "$CTL" ]; then
  echo "no CloudWatch agent installed; nothing to trim"
  exit 0
fi

CONF="$(find "$CONF_DIR" -name '*.json' -type f 2>/dev/null | head -1)"
if [ -z "$CONF" ]; then
  echo "CloudWatch agent is installed but no JSON config found under $CONF_DIR" >&2
  exit 1
fi

TMP=/var/tmp/cwagent-trimmed.json
jq '
  (.metrics.metrics_collected.mem.measurement)  |= map(select(. != "mem_available"))
| (.metrics.metrics_collected.swap.measurement) |= map(select(. != "swap_used"))
| del(.metrics.metrics_collected.procstat)
' "$CONF" >"$TMP"

# jq emits nothing useful on a parse failure; refuse rather than install an
# empty config, which would stop ALL metrics from this node instead of
# trimming three.
[ -s "$TMP" ] || { echo "jq produced no output; leaving config untouched" >&2; rm -f "$TMP"; exit 1; }

if cmp -s "$CONF" "$TMP"; then
  echo "already trimmed"
  rm -f "$TMP"
  exit 0
fi

"$CTL" -a fetch-config -m ec2 -s -c "file:$TMP" >/dev/null
rm -f "$TMP"

# Prove it took, rather than trusting the exit code: fetch-config succeeds
# whether or not the file said what we meant.
NEW="$(find "$CONF_DIR" -name '*.json' -type f 2>/dev/null | head -1)"
if grep -q '"procstat"' "$NEW" 2>/dev/null; then
  echo "procstat still present after reload" >&2
  exit 1
fi

echo "trimmed mem_available + swap_used + procstat; agent reloaded"
