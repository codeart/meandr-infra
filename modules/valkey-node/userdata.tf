# User-data, not a baked image.
#
# These nodes run for years, so the one thing baking clearly wins — boot
# speed — is the one nobody notices. What it costs is a build pipeline, an
# image lifecycle per region, and config that lives inside an artifact
# instead of in a reviewable diff. Determinism, the real argument for
# baking, comes from the vendored source and its checksum instead.
#
# NOTHING here is fetched from a third party. Packages come from the Amazon
# Linux repos and the Valkey source from our own bucket, both over the VPC's
# S3 gateway endpoint. The two Secrets Manager calls go out via NAT, so NAT
# is the one boot dependency — a deliberate choice over paying for an
# interface endpoint on a node replaced maybe twice a year.
#
# The cost is boot time: compiling Valkey takes minutes on a t4g.micro, and
# that lands inside the window where replacing a replica leaves the master
# write-paused (min-replicas-to-write). Worth it for a boot that cannot be
# broken by someone else's outage or a re-pointed git tag.

locals {
  user_data = <<-BASH
    #!/bin/bash
    set -euxo pipefail

    # `valkey-config-a` beats `ip-10-10-1-23` in a prompt, in journald and
    # in every log line that follows. preserve_hostname stops cloud-init
    # resetting it from DHCP on the next boot.
    hostnamectl set-hostname ${local.node_name}
    echo 'preserve_hostname: true' >/etc/cloud/cloud.cfg.d/99-hostname.cfg

    # htop's system-wide fallback, read when a user has no
    # ~/.config/htop/htoprc. A user's own changes are written to their
    # home, not here. Matches AL2023's htop 3.2.1.
    cat >/etc/htoprc <<'HTOPRC'
    # Beware! This file is rewritten by htop when settings are changed in the interface.
    # The parser is also very primitive, and not human-friendly.
    htop_version=3.2.1
    config_reader_min_version=3
    fields=0 48 17 18 38 39 40 2 46 47 49 1
    hide_kernel_threads=1
    hide_userland_threads=1
    shadow_other_users=1
    show_thread_names=1
    show_program_path=1
    highlight_base_name=1
    highlight_deleted_exe=1
    highlight_megabytes=1
    highlight_threads=1
    highlight_changes=0
    highlight_changes_delay_secs=5
    find_comm_in_cmdline=1
    strip_exe_from_cmdline=1
    show_merged_command=0
    header_margin=1
    screen_tabs=1
    detailed_cpu_time=1
    cpu_count_from_one=1
    show_cpu_usage=1
    show_cpu_frequency=0
    show_cpu_temperature=0
    degree_fahrenheit=0
    update_process_names=1
    account_guest_in_cpu_meter=1
    color_scheme=0
    enable_mouse=1
    delay=15
    hide_function_bar=0
    header_layout=two_50_50
    column_meters_0=AllCPUs Memory Swap
    column_meter_modes_0=1 1 1
    column_meters_1=Tasks LoadAverage Uptime
    column_meter_modes_1=2 2 2
    tree_view=0
    sort_key=46
    tree_sort_key=0
    sort_direction=-1
    tree_sort_direction=1
    tree_view_always_by_pid=0
    all_branches_collapsed=0
    screen:Main=PID USER PRIORITY NICE M_VIRT M_RESIDENT M_SHARE STATE PERCENT_CPU PERCENT_MEM TIME Command
    .sort_key=PERCENT_CPU
    .tree_sort_key=PID
    .tree_view=0
    .tree_view_always_by_pid=0
    .sort_direction=-1
    .tree_sort_direction=1
    .all_branches_collapsed=0
    screen:I/O=PID USER IO_PRIORITY IO_RATE IO_READ_RATE IO_WRITE_RATE
    .sort_key=IO_RATE
    .tree_sort_key=PID
    .tree_view=0
    .tree_view_always_by_pid=0
    .sort_direction=-1
    .tree_sort_direction=1
    .all_branches_collapsed=0
    HTOPRC
    chmod 0644 /etc/htoprc

    dnf install -y --setopt=install_weak_deps=False \
      jq awscli bind-utils gcc make openssl-devel systemd-devel tar gzip

    # Operator tools, and `|| true` because a convenience package must
    # never be able to cost us a node.
    dnf install -y htop mc || true


    # Valkey is COMPILED HERE, from source vendored in this repository.
    #
    # A build is unavoidable: nothing packages 9.x for aarch64 — AL2023
    # stops at 8.0.3, EPEL has no valkey at all, redis.io publishes x86_64
    # only, and valkey.io's binaries are Ubuntu-linked against a newer
    # glibc than ours. The only question was where it happens.
    #
    # Here, from S3, because a boot that reaches out to GitHub is a boot
    # that depends on GitHub being up, on a tag still pointing where it did
    # last year, and on whatever a third party decides to serve. The source
    # rides in the repo, is uploaded by the same apply that made this node,
    # and arrives over the VPC's S3 gateway endpoint — no NAT, no internet.
    aws s3 cp '${local.source_uri}' /tmp/valkey-src.tar.gz
    echo '${var.valkey_source_sha256}  /tmp/valkey-src.tar.gz' | sha256sum -c -

    # 2 GiB of swap, permanently — it has two jobs.
    #
    # At boot it is what lets the compile finish on a 1 GiB t4g.micro: cc1
    # wants a few hundred MB per translation unit, so a parallel make would
    # be an OOM kill, which presents as a node that never joins rather than
    # as a build that failed.
    #
    # Afterwards it stays, as a safety net. A node running out of memory
    # degrades into swap — slow, visible, alarmable — instead of being
    # killed outright, which buys an operator time to act. SwapUsedPercent
    # is the signal: sustained non-zero means maxmemory is too close to
    # what this instance actually has.
    #
    # swappiness=1, not 0: the kernel may reach for swap under genuine
    # pressure but will not proactively page out a keyspace that fits.
    # Swapping the dataset is a latency cliff, not graceful degradation —
    # the net is for surviving an incident, not for running in.
    #
    # dd, not fallocate: AL2023 roots are XFS, where swapon refuses a
    # fallocated file ("it appears to have holes").
    dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab

    # Kernel settings this workload actually cares about. Everything here
    # is a known Valkey/Redis failure mode, not general-purpose tuning.
    cat >/etc/sysctl.d/60-valkey.conf <<'SYSCTL'
    # See the swapfile note above: a net to fall into, not a floor to run on.
    vm.swappiness = 1

    # THE classic. Background saves fork, and with the default heuristic
    # overcommit the kernel can refuse a fork whose COW pages it thinks it
    # cannot back — so the AOF rewrite fails on exactly the busy node that
    # most needs it. Valkey warns about this at startup for a reason.
    vm.overcommit_memory = 1

    # Must be >= tcp-backlog (511 default) or the listen backlog is
    # silently truncated and bursts of reconnects are dropped rather than
    # queued. A fleet reconnecting after a failover is precisely a burst.
    net.core.somaxconn = 1024

    # Socket buffers sized for CROSS-REGION replication. A transatlantic
    # link has a bandwidth-delay product far past the ~200 KB default, so
    # without this the replication stream is capped by the receive window
    # rather than by the link — which shows up as chronic lag on exactly
    # the replicas that are hardest to observe.
    net.core.rmem_max = 16777216
    net.core.wmem_max = 16777216
    net.ipv4.tcp_rmem = 4096 87380 16777216
    net.ipv4.tcp_wmem = 4096 65536 16777216

    # A replication link is long-lived and bursty. Without this the kernel
    # resets the congestion window after every idle gap and each burst
    # restarts in slow start.
    net.ipv4.tcp_slow_start_after_idle = 0
    SYSCTL
    sysctl -q --system

    # Transparent huge pages: OFF, and not a sysctl.
    #
    # This is the single worst latency source for a forking, copy-on-write
    # server. THP makes each COW fault copy 2 MB instead of 4 KB, so a
    # background save on a busy master turns into multi-second stalls that
    # look like the process hanging. Ordered before valkey so no dataset
    # has been loaded when it flips.
    cat >/etc/systemd/system/disable-thp.service <<'UNIT'
    [Unit]
    Description=Disable transparent huge pages (Valkey latency)
    DefaultDependencies=no
    After=sysinit.target local-fs.target
    Before=valkey.service

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
    ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'

    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload
    systemctl enable --now disable-thp

    mkdir -p /tmp/valkey-src
    tar -xzf /tmp/valkey-src.tar.gz -C /tmp/valkey-src --strip-components=1
    cd /tmp/valkey-src

    # BUILD_TLS because the fleet has no plaintext listener at all.
    # USE_SYSTEMD so the server answers READY=1 only once it has finished
    # loading the AOF — without it systemd calls a node started the moment
    # the process forks, and a node reporting healthy while still loading
    # is exactly the stale-but-serving state the metrics watch for.
    make -j"$(nproc)" BUILD_TLS=yes USE_SYSTEMD=yes
    strip src/valkey-server src/valkey-cli src/valkey-benchmark

    # `make install` rather than copying binaries: it lays down
    # valkey-sentinel, valkey-check-rdb and valkey-check-aof as symlinks to
    # valkey-server, which is how they are meant to exist — the server
    # picks its mode from argv[0].
    make install PREFIX=/usr/local

    cd /
    rm -rf /tmp/valkey-src /tmp/valkey-src.tar.gz

    # Supplied by the package until we stopped using it.
    getent group valkey >/dev/null || groupadd --system valkey
    getent passwd valkey >/dev/null || useradd --system --gid valkey \
      --home-dir /var/lib/valkey --shell /sbin/nologin --comment Valkey valkey

    AUTH="$(aws secretsmanager get-secret-value \
      --secret-id '${var.auth_secret_arn}' \
      --query SecretString --output text)"

    # /etc/valkey is WRITABLE by design, not an oversight. Both daemons
    # rewrite their own config at runtime: valkey-server persists replicaof
    # when Sentinel demotes it, and Sentinel continuously records the peers
    # and epochs it has discovered. Read-only config here means a node that
    # forgets its role across a restart.
    install -d -o valkey -g valkey -m 0750 \
      /var/lib/valkey /var/log/valkey /etc/valkey /etc/valkey/tls

    # TLS material for the whole fleet in this environment: ca.crt for
    # verification, node.crt/node.key for the listener. One keypair shared
    # across nodes rather than one per node — every node is equally trusted
    # (same AUTH, same data), so per-node keys would add rotation work
    # without narrowing a blast radius. Revisit if that stops being true.
    aws secretsmanager get-secret-value \
      --secret-id '${var.tls_secret_arn}' --query SecretString --output text \
      | jq -r '.ca_crt'   > /etc/valkey/tls/ca.crt
    aws secretsmanager get-secret-value \
      --secret-id '${var.tls_secret_arn}' --query SecretString --output text \
      | jq -r '.node_crt' > /etc/valkey/tls/node.crt
    aws secretsmanager get-secret-value \
      --secret-id '${var.tls_secret_arn}' --query SecretString --output text \
      | jq -r '.node_key' > /etc/valkey/tls/node.key
    chown -R valkey:valkey /etc/valkey/tls
    chmod 0400 /etc/valkey/tls/node.key
    chmod 0444 /etc/valkey/tls/ca.crt /etc/valkey/tls/node.crt

    # maxmemory from the instance's ACTUAL memory rather than a lookup
    # table keyed on instance type — the table goes stale the moment
    # somebody resizes, and the failure is an OOM kill rather than an
    # error. 70% leaves room for the OS, replication buffers, and the
    # copy-on-write spike a full resync causes.
    MEM_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
    MAXMEM_MB="$(( MEM_KB * 70 / 100 / 1024 ))"

    # I/O threading, only where it earns its keep. Valkey executes commands
    # on ONE thread whatever this says — io-threads parallelises socket
    # reads and writes only — and below 4 cores it costs more in contention
    # than it returns, which is why upstream advises against enabling it
    # there. Derived from the actual core count so a resize turns it on by
    # itself rather than waiting for somebody to remember.
    CORES="$(nproc)"
    IO_THREADS=""
    if [ "$CORES" -ge 4 ]; then
      IO_THREADS="io-threads $(( CORES - 1 ))
    io-threads-do-reads yes"
    fi

    # Whether this node boots as a replica is DERIVED from the master
    # record, not declared in Terraform.
    #
    # A declared role is wrong the moment Sentinel promotes, and replacement
    # re-applies it: relaunching yesterday's master after a failover would
    # start a SECOND master, empty, whose Sentinel monitors itself and so
    # never discovers the other one. Resolving the record instead makes a
    # replacement correct whichever node is replaced and whoever currently
    # holds the master.
    #
    # If the record names a master that is gone, this node becomes a replica
    # of a corpse and nothing converges until an operator promotes the
    # survivor. That is the intended outcome: a stall is recoverable, and
    # the alternative — an empty master the survivors resync from — is not.

    # The master record is a CNAME to whichever node currently holds the
    # role, so its TARGET is that node's stable name. Reading the target
    # rather than resolving to an address is what lets replication and
    # Sentinel address peers by name.
    #
    # Retried, not probed once. A transient resolver failure read as "no
    # master yet" is exactly how a fleet acquires a second master.
    MASTER_NAME=""
    for _ in $(seq 1 12); do
      MASTER_NAME="$(dig +short CNAME ${local.master_record} | sed 's/\.$//' || true)"
      [ -n "$MASTER_NAME" ] && break
      sleep 5
    done

    # `role` survives only to break the bootstrap tie. Before the record
    # exists something has to decide, and both nodes deciding "master" is
    # the one outcome worse than waiting.
    BOOTSTRAP_MASTER=${var.role == "master" ? "yes" : "no"}

    # No record and no claim to the role: refuse. Continuing would write an
    # empty replicaof and point Sentinel at ourselves, which is how a fleet
    # ends up with two masters. A node that fails to boot is recoverable.
    if [ -z "$MASTER_NAME" ] && [ "$BOOTSTRAP_MASTER" != yes ]; then
      echo "no master record after 60s and not the bootstrap master; refusing"
      exit 1
    fi

    # Every address below is a node's OWN stable name — never the master
    # record, which moves and would become a node identity Sentinel later
    # reports as a promotion target.
    REPLICAOF="replicaof $MASTER_NAME 6379"
    if [ "$MASTER_NAME" = "${local.hostname}" ]; then
      REPLICAOF=""
    elif [ -z "$MASTER_NAME" ] && [ "$BOOTSTRAP_MASTER" = yes ]; then
      REPLICAOF=""
    fi

    # What Sentinel monitors: the master's name, or our own when we are
    # the one bootstrapping it.
    SENTINEL_ADDR="$MASTER_NAME"
    [ -z "$SENTINEL_ADDR" ] && SENTINEL_ADDR="${local.hostname}"

    cat >/etc/valkey/valkey.conf <<CONF
    # TLS ONLY. Plaintext is disabled outright, not merely discouraged —
    # clients connect with rediss:// and a listener on 6379 would be a
    # standing invitation to a misconfigured one.
    port 0
    tls-port 6379
    tls-cert-file /etc/valkey/tls/node.crt
    tls-key-file /etc/valkey/tls/node.key
    tls-ca-cert-file /etc/valkey/tls/ca.crt
    tls-replication yes
    # Every connection must present a certificate from our CA, in both
    # directions. The CA issues only to this fleet, so holding the cert is
    # the identity.
    tls-auth-clients yes

    dir /var/lib/valkey
    logfile /var/log/valkey/valkey.log

    # Pairs with Type=notify in the unit: the node counts as started only
    # once the AOF is loaded, rather than the moment the process exists.
    supervised systemd

    # Announce ourselves by name so the master lists us by name and
    # Sentinel adopts it as our identity.
    replica-announce-ip ${local.hostname}

    protected-mode no
    requirepass $AUTH
    masterauth $AUTH
    masteruser default

    # AOF ON, and this is not about durability.
    #
    # A master that restarts with no persistence comes back EMPTY — and its
    # replicas faithfully sync that emptiness. One restart would wipe the
    # config for the whole fleet. That the data is rebuildable from Postgres
    # does not help: nothing would know to rebuild it, and every proxy would
    # be serving an empty catalogue meanwhile.
    #
    # everysec fsyncs on a background thread (bio), so the cost is a
    # fraction of a second of writes on a hard kill — against a projection
    # that BE rewrites anyway. RDB snapshots stay off; AOF alone restores
    # the state that matters.
    appendonly yes
    appendfsync everysec
    # Do not stall writes during a rewrite; the same background thread is
    # already doing the fsync.
    no-appendfsync-on-rewrite yes
    save ""

    $IO_THREADS

    maxmemory $${MAXMEM_MB}mb
    # NOEVICTION is a contract, not a preference: the eventbus refuses to
    # start against anything else (internal/eventbus/bus.go), because the
    # lossless stream cannot uphold durability on a store that silently
    # drops entries under pressure. A full instance must fail writes
    # loudly instead.
    maxmemory-policy noeviction

    # Decides whether a WAN blip costs a partial resync or a full one. A
    # full cross-region resync ships the whole dataset again.
    repl-backlog-size 64mb
    repl-backlog-ttl 0

    $REPLICAOF
    ${var.promotable ? "" : "replica-priority 0"}
    ${local.split_brain_guard}
    CONF

    chown valkey:valkey /etc/valkey/valkey.conf
    chmod 0640 /etc/valkey/valkey.conf

    ${local.systemd_units}

    systemctl daemon-reload
    systemctl enable --now valkey

    ${local.monitoring_setup}

    ${var.run_sentinel ? local.sentinel_setup : "# no Sentinel on this node"}
  BASH

  # The units the AL2023 package used to supply.
  #
  # Type=notify throughout, which is the reason the build carries
  # USE_SYSTEMD: it makes "started" mean "finished loading the AOF" rather
  # than "the process exists". On a node with a real dataset those are
  # minutes apart, and everything ordered after this unit would otherwise
  # start against a server still reading from disk.
  #
  # ProtectSystem=full with /etc/valkey punched back out — see the install
  # step: both daemons rewrite their own config, so it is state, not
  # configuration, however much it looks like the latter.
  systemd_units = <<-BASH
    cat >/etc/systemd/system/valkey.service <<'UNIT'
    [Unit]
    Description=Valkey
    Wants=network-online.target
    After=network-online.target

    [Service]
    Type=notify
    User=valkey
    Group=valkey
    ExecStart=/usr/local/bin/valkey-server /etc/valkey/valkey.conf
    Restart=always
    RestartSec=5
    LimitNOFILE=65536
    ProtectSystem=full
    ReadWritePaths=/etc/valkey
    PrivateTmp=yes
    NoNewPrivileges=yes

    [Install]
    WantedBy=multi-user.target
    UNIT

    cat >/etc/systemd/system/valkey-sentinel.service <<'UNIT'
    [Unit]
    Description=Valkey Sentinel
    Wants=network-online.target
    After=network-online.target

    [Service]
    Type=notify
    User=valkey
    Group=valkey
    ExecStart=/usr/local/bin/valkey-sentinel /etc/valkey/sentinel.conf
    Restart=always
    RestartSec=5
    LimitNOFILE=65536
    ProtectSystem=full
    ReadWritePaths=/etc/valkey
    PrivateTmp=yes
    NoNewPrivileges=yes

    [Install]
    WantedBy=multi-user.target
    UNIT
  BASH

  # CloudWatch agent for everything it understands — CPU, memory, disk,
  # network — plus procstat for the valkey process itself. Config-driven
  # and AWS-maintained, so none of that is ours to keep working.
  #
  # It does NOT understand Valkey: master_link_status, replication offsets
  # and evicted_keys are INFO output, not OS metrics. That gap is the only
  # thing the script below covers, and it stays small on purpose.
  monitoring_setup = <<-BASH
    dnf install -y amazon-cloudwatch-agent

    cat >/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'CWCONF'
    {
      "agent": { "metrics_collection_interval": 60 },
      "metrics": {
        "namespace": "meandr/valkey",
        "append_dimensions": { "InstanceId": "$${aws:InstanceId}" },
        "metrics_collected": {
          "mem":  { "measurement": ["mem_used_percent", "mem_available"] },
          "swap": { "measurement": ["swap_used_percent", "swap_used"] },
          "cpu":  { "measurement": ["cpu_usage_active", "cpu_usage_iowait"], "totalcpu": true },
          "disk": { "measurement": ["used_percent"], "resources": ["/"] },
          "net":  { "measurement": ["bytes_sent", "bytes_recv"] },
          "procstat": [
            { "exe": "valkey-server", "measurement": ["cpu_usage", "memory_rss"] }
          ]
        }
      }
    }
    CWCONF

    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
      -a fetch-config -m ec2 -s \
      -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

    # The Valkey-specific handful the agent cannot see.
    #
    # master_link_status is the one that matters most and the reason this
    # exists at all: a replica whose link is down keeps serving its last
    # known state indefinitely, so from a client's side stale and healthy
    # look identical. Every other number here is a gauge; that one is a
    # boolean that quietly invalidates all of them.
    #
    # evicted_keys must be zero. Non-zero means maxmemory-policy is not
    # noeviction, which breaks the durability contract the eventbus
    # asserts at startup — cheap canary for an expensive mistake.
    base64 -d >/usr/local/bin/valkey-metrics.sh <<'B64'
    ${base64encode(file("${path.module}/files/valkey-metrics.sh"))}
    B64
    chmod 0755 /usr/local/bin/valkey-metrics.sh

    cat >/etc/systemd/system/valkey-metrics.service <<UNIT
    [Service]
    Type=oneshot
    Environment=AUTH_SECRET=${var.auth_secret_arn}
    Environment=AWS_DEFAULT_REGION=${data.aws_region.current.name}
    ExecStart=/usr/local/bin/valkey-metrics.sh
    UNIT

    cat >/etc/systemd/system/valkey-metrics.timer <<'UNIT'
    [Timer]
    OnBootSec=120
    OnUnitActiveSec=60
    [Install]
    WantedBy=timers.target
    UNIT

    systemctl daemon-reload
    systemctl enable --now valkey-metrics.timer
  BASH

  # A master that cannot see a replica stops accepting writes.
  #
  # Without this, a master partitioned from BOTH its peer AZ and the
  # sentinels keeps taking writes while the survivors promote someone
  # else — two masters, diverging, and whichever loses the race loses its
  # writes silently. The cost is that a genuinely isolated master goes
  # read-only, which is the correct trade: refusing a write is recoverable,
  # accepting one that is about to be discarded is not.
  #
  # Not configurable, deliberately. The end state is four nodes across two
  # regions, where a single replacement always leaves a replica connected
  # and this costs nothing. The window where it does cost something — two
  # nodes, mid-maintenance — is a staging transient, and a knob defaulted
  # off "until later" is a knob nobody remembers to turn on.
  split_brain_guard = <<-CONF
    min-replicas-to-write 1
    min-replicas-max-lag 10
  CONF

  # Sentinel runs in EVERY region, including the ones holding only
  # non-promotable replicas.
  #
  # It has to. Promotable nodes live in the API region across two AZs, so
  # confining Sentinels to them caps the fleet at two voters and quorum 2 —
  # under which an isolated master leaves one voter, no agreement is ever
  # reached, and automatic failover can never happen at all.
  #
  # An edge Sentinel is safe because it contributes quorum without
  # contributing a candidate: every edge replica carries replica-priority
  # 0, so a partition that isolates the API region lets the edges agree the
  # master is down and then find nothing they are allowed to promote. The
  # failover attempt dies for want of a candidate rather than splitting the
  # fleet, which is the outcome we want from that partition.
  sentinel_setup = <<-BASH
    cat >/etc/valkey/sentinel.conf <<CONF
    port 0
    tls-port 26379
    tls-cert-file /etc/valkey/tls/node.crt
    tls-key-file /etc/valkey/tls/node.key
    tls-ca-cert-file /etc/valkey/tls/ca.crt
    tls-replication yes
    tls-auth-clients yes

    dir /var/lib/valkey
    logfile /var/log/valkey/sentinel.log
    supervised systemd

    # Without this anything inside the SG can trigger a failover. Every
    # Sentinel must share the value, which they do — it is the fleet AUTH.
    requirepass $AUTH

    # Names end to end: Sentinel stores addresses as identities, resolves
    # them for connections, and reports them on promotion. announce-ip is
    # this Sentinel's own name; the monitor target is the master's.
    sentinel resolve-hostnames yes
    sentinel announce-hostnames yes
    sentinel announce-ip ${local.hostname}

    sentinel monitor ${local.sentinel_master_name} $SENTINEL_ADDR 6379 ${var.sentinel_quorum}
    sentinel auth-pass ${local.sentinel_master_name} $AUTH
    sentinel down-after-milliseconds ${local.sentinel_master_name} 5000
    sentinel failover-timeout ${local.sentinel_master_name} 60000
    sentinel parallel-syncs ${local.sentinel_master_name} 1

    # Edge replicas run no Sentinel of their own and are never told about
    # a promotion directly. They follow a DNS record instead, which this
    # script rewrites — without it a failover strands every region
    # pointing at a node that is no longer master.
    sentinel client-reconfig-script ${local.sentinel_master_name} /usr/local/bin/valkey-promote.sh
    CONF

    base64 -d >/usr/local/bin/valkey-promote.sh <<'B64'
    ${base64encode(file("${path.module}/files/valkey-promote.sh"))}
    B64

    chmod 0755 /usr/local/bin/valkey-promote.sh
    mkdir -p /etc/systemd/system/valkey-sentinel.service.d
    cat >/etc/systemd/system/valkey-sentinel.service.d/env.conf <<UNIT
    [Service]
    Environment=ZONE_ID=${var.dns_zone_id}
    Environment=MASTER_RECORD=${local.master_record}
    Environment=AWS_DEFAULT_REGION=${data.aws_region.current.name}
    UNIT
    chown valkey:valkey /etc/valkey/sentinel.conf
    chmod 0640 /etc/valkey/sentinel.conf
    systemctl daemon-reload
    systemctl enable --now valkey-sentinel
  BASH

  # What clients and replicas connect to. Deliberately NOT a Terraform
  # record: it moves on promotion, and Terraform reverting it on the next
  # apply would silently point everything at a demoted node.
  master_record = "${var.fleet}-master.${local.dns_root}"

  # What Sentinel knows the master by, and what an operator types in
  # `SENTINEL FAILOVER <name>`. Derived, not configurable: it must match
  # across every Sentinel watching this fleet, and the fleet is already
  # the thing that makes it unique.
  sentinel_master_name = var.fleet
}
