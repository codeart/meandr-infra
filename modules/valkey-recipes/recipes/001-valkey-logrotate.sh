#!/usr/bin/env bash
# Rotate the Valkey and Sentinel logs.
#
# Valkey inherits Redis's behaviour: it writes to `logfile` and never
# rotates it. Distro packages ship a logrotate config alongside the
# binary; we build from source, so we get the daemon without the
# packaging that normally covers this. Nothing on these nodes rotates
# /var/log/valkey/*.log.
#
# copytruncate is mandatory, not stylistic. Redis-lineage servers do not
# reopen their log on SIGHUP, so rotating by rename leaves the daemon
# writing to an unlinked inode: the disk fills with a file that `ls`
# cannot show you and only a restart releases.
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
