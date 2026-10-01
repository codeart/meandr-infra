#!/usr/bin/env bash
# ConntrackPercent every minute on the wall clock. The boot timer's 5 min ran every
# 6 under the default 1 min accuracy, leaving one 5 min alarm period in six empty.
set -euo pipefail

TIMER=nat-metrics.timer
DROPIN=/etc/systemd/system/nat-metrics.timer.d/cadence.conf

if [ ! -f "/etc/systemd/system/$TIMER" ]; then
  echo "no $TIMER on this NAT; its conntrack alarm has nothing to read" >&2
  exit 1
fi

CADENCE='[Unit]
Description=Publish NAT conntrack occupancy every minute
[Timer]
OnUnitActiveSec=
OnCalendar=minutely
AccuracySec=1s'

on_minute_grid() {
  local mono cal acc
  mono="$(systemctl show -p TimersMonotonic --value "$TIMER")"
  cal="$(systemctl show -p TimersCalendar --value "$TIMER")"
  acc="$(systemctl show -p AccuracyUSec --value "$TIMER")"
  if [ -n "$mono" ] || [[ "$cal" != *'*:*:00'* ]] || [ "$acc" != 1s ] || ! systemctl is-active --quiet "$TIMER"; then
    echo "timer not on the minute grid: monotonic='$mono' calendar='$cal' accuracy='$acc'" >&2
    return 1
  fi
}

if printf '%s\n' "$CADENCE" | cmp -s - "$DROPIN"; then
  on_minute_grid
  echo "nat-metrics already minutely"
  exit 0
fi

# One publish first: a box whose role or egress cannot carry it fails here,
# before the drop-in, so the retry tests it again.
systemctl start nat-metrics.service

mkdir -p "$(dirname "$DROPIN")"
printf '%s\n' "$CADENCE" >"$DROPIN"
systemctl daemon-reload
systemctl restart "$TIMER"
on_minute_grid

echo "nat-metrics timer minutely; one datapoint published"
