#!/usr/bin/env bash
# Drop redundant CloudWatch metrics from the agent config.
#
# CloudWatch bills per unique namespace + name + DIMENSION SET, so a name
# published by nine nodes is nine billable metrics, not one. At $0.30 each
# these cost ~$9/month and grow with every node and every region.
#
#   mem_available    — derivable from mem_used_percent, which we keep
#   swap_used        — swap_used_percent carries the same signal; the
#                      absolute figure adds nothing on a fixed-size node
#   procstat         — 12 metrics, and DOUBLE-COUNTED by accident:
#                      valkey-sentinel is a symlink to valkey-server (the
#                      mode comes from argv[0]), so a filter on
#                      `exe: valkey-server` matches both processes and
#                      emits a set for each. UsedMemory from INFO is a
#                      better memory number than procstat_memory_rss, and
#                      we already publish it.
#
# TWO THINGS ABOUT THE AGENT THAT ARE NOT OBVIOUS:
#
# 1. `fetch-config` MOVES the JSON you hand it into
#    etc/amazon-cloudwatch-agent.d/file_<name>.json. The path userdata
#    wrote to does not exist afterwards.
# 2. The running agent reads the GENERATED .toml, not the JSON. Editing
#    the JSON in place changes nothing until fetch-config regenerates.
#
# So: edit a copy, hand the copy to fetch-config, let it regenerate and
# restart. Edited with jq rather than rewritten so one recipe serves both
# node shapes — a data node and an arbiter have different configs, and
# duplicating that here would give it a second place to drift.
#
# The userdata template is deliberately NOT changed: that would rewrite
# user_data and replace all nine nodes to save $9/month. A node built
# later comes up with the extra metrics and the next apply trims them,
# because a new instance replays the whole backlog.
set -euo pipefail

CTL=/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl
CONF_DIR=/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.d

# No agent at all is a legitimate "nothing to do". An agent that IS
# installed but whose config cannot be found is NOT — it means an
# assumption here is wrong, and reporting success would hide that. The
# first version of this recipe did exactly that on all nine nodes.
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
