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
    IFACE=$(ip -o -4 route show default | awk '{print $5; exit}')${local.nft_self_addr}

    mkdir -p /etc/nftables
    cat >/etc/nftables/meandr-nat.nft <<NFT
    table ip meandr_nat {
    ${local.nft_prerouting}  chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
    ${local.nft_no_masq}    oifname "$IFACE" masquerade
      }
    }
    NFT

    grep -q meandr-nat /etc/sysconfig/nftables.conf ||
      echo 'include "/etc/nftables/meandr-nat.nft"' >>/etc/sysconfig/nftables.conf

    systemctl enable --now nftables
    ${local.forward_resolver}
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

  # Both render EMPTY without forwards, so an egress-only NAT's user-data
  # is byte-identical to before this existed: user_data_replace_on_change
  # would otherwise rebuild every live NAT on the next apply.
  #
  # Forwarded flows skip masquerade on purpose. This box has ONE interface,
  # so a DNAT'd packet leaves the way it came and would otherwise be
  # rewritten to our address, hiding every client behind the NAT's IP —
  # rate limiting and IP bans on the target would see one visitor. Without
  # SNAT the target sees the real client; the reply still routes back
  # through here (we are its default route) and conntrack undoes the DNAT.
  #
  # A forward matches ONLY packets addressed to this box (the EIP arrives
  # as the ENI's own address). One interface carries both directions, so
  # matching on port alone would also catch the private subnets' OUTBOUND
  # 443 — every Secrets Manager, SSM and dnf call — and rewrite it to the
  # target. Measured 2026-09-16: two private boxes that never registered.
  nft_self_addr = length(var.forwards) == 0 ? "" : "\nSELF=$(ip -o -4 addr show dev \"$IFACE\" | awk '{print $4; exit}' | cut -d/ -f1)"

  # Host-mode leaves the chain EMPTY at boot and lets the resolver fill it:
  # the target usually does not exist yet the first time this box comes up,
  # and a rule built from an unresolvable name would be a rule to nowhere.
  forward_host = length(var.forwards) == 0 ? "" : var.forwards[0].target_host

  nft_prerouting = length(var.forwards) == 0 ? "" : join("", concat(
    ["  chain prerouting {\n    type nat hook prerouting priority dstnat; policy accept;\n"],
    local.forward_host != "" ? [] :
    [for f in var.forwards : "    iifname \"$IFACE\" ip daddr $SELF tcp dport ${f.port} dnat to ${f.target_ip}\n"],
    ["  }\n"],
  ))
  nft_no_masq = length(var.forwards) == 0 ? "" : "    ip daddr ${var.vpc_cidr} return\n"

  # The resolver. Installed only in host mode, so a static forward and an
  # egress-only NAT both render exactly as before.
  #
  # getent, not dig: it goes through glibc's resolver (no bind-utils to
  # install) and glibc does not cache, so the timer's period IS the
  # detection latency. An empty or non-IPv4 answer KEEPS the current rules —
  # a DNS blip must never rewrite the forward to nowhere.
  forward_resolver = local.forward_host == "" ? "" : <<-RESOLVER

    install -d -m 0755 /var/lib/meandr
    cat >/usr/local/bin/nat-forward-resolve <<'SCRIPT'
    #!/bin/sh
    # Re-point the DNAT chain when the target record moves. nftables resolves
    # a name once at load time and never again, so the swap has to happen
    # here. One `nft -f` transaction, so no packet ever sees a half-updated
    # chain.
    set -eu
    HOST='${local.forward_host}'
    STATE=/var/lib/meandr/forward-target

    IFACE=$(ip -o -4 route show default | awk '{print $5; exit}')
    SELF=$(ip -o -4 addr show dev "$IFACE" | awk '{print $4; exit}' | cut -d/ -f1)
    NEW=$(getent ahostsv4 "$HOST" 2>/dev/null | awk '{print $1; exit}' || true)

    case "$NEW" in
      ''|*[!0-9.]*) exit 0 ;;
    esac

    OLD=$(cat "$STATE" 2>/dev/null || true)
    [ "$NEW" = "$OLD" ] && exit 0

    nft -f - <<NFT
    flush chain ip meandr_nat prerouting
    table ip meandr_nat {
      chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
    ${join("", [for f in var.forwards : "    iifname \"$IFACE\" ip daddr $SELF tcp dport ${f.port} dnat to $NEW\n"])}  }
    }
    NFT

    printf '%s\n' "$NEW" >"$STATE"
    logger -t nat-forward "target $HOST moved: $${OLD:-none} -> $NEW"
    SCRIPT
    chmod 0755 /usr/local/bin/nat-forward-resolve

    cat >/etc/systemd/system/nat-forward-resolve.service <<'UNIT'
    [Unit]
    Description=Re-point the NAT DNAT chain at the forward target's current address
    After=nftables.service
    [Service]
    Type=oneshot
    ExecStart=/usr/local/bin/nat-forward-resolve
    UNIT

    cat >/etc/systemd/system/nat-forward-resolve.timer <<'UNIT'
    [Unit]
    Description=Re-check the forward target every 30s
    [Timer]
    OnBootSec=10s
    OnUnitActiveSec=30s
    AccuracySec=1s
    [Install]
    WantedBy=timers.target
    UNIT

    systemctl daemon-reload
    systemctl enable --now nat-forward-resolve.timer
  RESOLVER
}
