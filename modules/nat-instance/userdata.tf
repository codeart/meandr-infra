locals {
  user_data = <<-BASH
    #!/bin/bash
    set -euxo pipefail

    # `nat-eu-central-1a` beats `ip-10-10-0-42` in a prompt, in journald and
    # in every log line that follows. preserve_hostname stops cloud-init
    # resetting it from DHCP on the next boot.
    hostnamectl set-hostname ${local.name}
    echo 'preserve_hostname: true' >/etc/cloud/cloud.cfg.d/99-hostname.cfg

    # --- Swap, BEFORE anything that allocates ---------------------------
    #
    # dnf is Python and peaks near 200 MiB, which a 412 MiB nano cannot
    # meet from AL2023's own swap alone — it OOM-killed the install and
    # left a box with a hostname and no NAT (us-east-1a, 2026-09-08).
    #
    # First, therefore. Swap created after the step that needs it is not
    # swap.
    if [ ! -f /swapfile ]; then
      dd if=/dev/zero of=/swapfile bs=1M count=512
      chmod 0600 /swapfile
      mkswap /swapfile
      swapon /swapfile
      echo '/swapfile none swap sw 0 0' >>/etc/fstab
    fi

    # --- Packages -------------------------------------------------------
    #
    # Separate transactions, smallest first: one combined dnf is a single
    # peak this box cannot afford, and a failure here kills cloud-init
    # before anything below runs.
    dnf install -y nftables
    dnf install -y --setopt=install_weak_deps=False awscli
    dnf install -y --setopt=install_weak_deps=False conntrack-tools tcpdump jq bind-utils

    # Operator tools, and `|| true` because a convenience package must
    # never be able to cost us a node.
    dnf install -y htop mc || true

    # htop's system-wide fallback, read when a user has no
    # ~/.config/htop/htoprc. A user's own changes are written to their
    # home, not here. Matches AL2023's htop 3.2.1.
    #
    # NOT indent()ed: the <<- dedent applies to this template's literal
    # lines before interpolation, so anything added here survives into the
    # file and htop's parser refuses an indented key.
    cat >/etc/htoprc <<'HTOPRC'
    ${file("${path.module}/files/htoprc")}
    HTOPRC
    chmod 0644 /etc/htoprc

    # --- Forwarding -----------------------------------------------------

    # Loose reverse-path (2), not strict: a NAT box legitimately sees
    # return traffic for addresses it does not own.
    cat >/etc/sysctl.d/99-nat.conf <<'SYSCTL'
    net.ipv4.ip_forward=1
    net.ipv4.conf.all.rp_filter=2
    net.ipv4.conf.default.rp_filter=2
    SYSCTL

    # Conntrack sizes itself from RAM, which on a nano is far below what
    # this box can actually track. Exhaustion drops NEW connections while
    # established ones keep working, so it presents as intermittent
    # failures rather than an outage.
    #
    # The timeouts matter as much as the ceiling: the kernel holds a
    # finished flow for 5 days by default, which suits a firewall watching
    # long sessions and not a NAT carrying short HTTPS calls.
    cat >/etc/sysctl.d/99-conntrack.conf <<'SYSCTL'
    net.netfilter.nf_conntrack_max=131072
    net.netfilter.nf_conntrack_tcp_timeout_established=3600
    net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
    net.netfilter.nf_conntrack_tcp_timeout_close_wait=30
    net.netfilter.nf_conntrack_tcp_timeout_fin_wait=30
    SYSCTL

    modprobe nf_conntrack
    sysctl --system

    # The upstream interface by discovery, not by name: ens5 is the usual
    # answer on nitro but it is not a guarantee, and a wrong name here
    # fails as a silent black hole.
    IFACE=$(ip -o -4 route show default | awk '{print $5; exit}')

    mkdir -p /etc/nftables
    cat >/etc/nftables/meandr-nat.nft <<NFT
    table ip meandr_nat {
      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "$IFACE" masquerade
      }
    }
    NFT

    grep -q meandr-nat /etc/sysconfig/nftables.conf ||
      echo 'include "/etc/nftables/meandr-nat.nft"' >>/etc/sysconfig/nftables.conf

    systemctl enable --now nftables

    # --- Metrics --------------------------------------------------------
    #
    # Conntrack occupancy ONLY. Throughput and packet rate already arrive
    # free as AWS/EC2 NetworkIn/NetworkOut/NetworkPacketsIn/Out, and
    # conntrack is the one signal with no equivalent — the table filling is
    # what turns a working NAT into one that refuses new connections while
    # established ones carry on, which reads as flapping, not an outage.
    cat >/usr/local/bin/nat-metrics <<'SCRIPT'
    #!/bin/bash
    set -euo pipefail

    count=$(< /proc/sys/net/netfilter/nf_conntrack_count)
    max=$(< /proc/sys/net/netfilter/nf_conntrack_max)
    [ "$max" -gt 0 ] || exit 0

    token=$(curl -sf -X PUT http://169.254.169.254/latest/api/token \
      -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
    meta() { curl -sf -H "X-aws-ec2-metadata-token: $token" \
      "http://169.254.169.254/latest/meta-data/$1"; }

    aws cloudwatch put-metric-data \
      --region "$(meta placement/region)" \
      --namespace meandr/nat \
      --metric-name ConntrackPercent \
      --unit Percent \
      --value "$(( count * 100 / max ))" \
      --dimensions InstanceId="$(meta instance-id)"
    SCRIPT
    chmod 0755 /usr/local/bin/nat-metrics

    # Five minutes, matching EC2 basic monitoring, so both land on one
    # grid. Conntrack filling is a capacity trend, not a spike to catch.
    cat >/etc/systemd/system/nat-metrics.service <<'UNIT'
    [Unit]
    Description=Publish NAT conntrack occupancy
    [Service]
    Type=oneshot
    ExecStart=/usr/local/bin/nat-metrics
    UNIT

    cat >/etc/systemd/system/nat-metrics.timer <<'UNIT'
    [Unit]
    Description=Publish NAT conntrack occupancy every 5 minutes
    [Timer]
    OnBootSec=2min
    OnUnitActiveSec=5min
    [Install]
    WantedBy=timers.target
    UNIT

    systemctl daemon-reload
    systemctl enable --now nat-metrics.timer
  BASH
}
