#!/usr/bin/env bash
# Rotate the Valkey and Sentinel logs. Valkey never rotates `logfile`
# itself, and building from source means no packaged logrotate config.
#
# copytruncate is mandatory, not stylistic: Redis-lineage servers do not
# reopen their log on SIGHUP, so rotating by rename leaves the daemon
# writing to an unlinked inode that only a restart releases.
set -euo pipefail

command -v logrotate >/dev/null 2>&1 || dnf install -y logrotate

# maxsize, not size: `size` REPLACES the time schedule rather than
# capping it, so `daily` becomes dead config and logrotate says so.
# maxsize means "daily, or sooner if it passes 32M" — the actual intent.
cat >/etc/logrotate.d/valkey <<'CONF'
/var/log/valkey/*.log {
    daily
    rotate 7
    maxsize 32M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su valkey valkey
}
CONF
chmod 0644 /etc/logrotate.d/valkey

# Parse the whole set, not just this file — a syntax error here would
# otherwise break rotation for every other log on the box, silently.
# Failing now means the recipe is not recorded and the next run retries.
#
# --debug writes its whole trace to STDERR, so both streams go to
# /dev/null; only the exit status is wanted.
logrotate --debug /etc/logrotate.conf >/dev/null 2>&1

echo "logrotate: /etc/logrotate.d/valkey installed"
