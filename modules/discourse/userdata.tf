# First boot builds the forum from nothing: swap, Docker, the launcher, a
# web_only container against the external Postgres and Valkey, then Let's
# Encrypt. Secrets come from Secrets Manager through the instance role —
# nothing sensitive rides in user-data, which anything on the box can read
# from instance metadata.
#
# Boot-only, by design. Rebuilding the container after a settings change
# is an SSM recipe (recipes/), not a user-data edit: user-data drift
# replaces the instance and its uploads with it.

module "rds_ca" {
  source = "../rds-ca"
  region = var.region
}

locals {
  user_data = <<-BASH
    #!/bin/bash
    set -euxo pipefail

    hostnamectl set-hostname ${local.name}
    echo 'preserve_hostname: true' >/etc/cloud/cloud.cfg.d/99-hostname.cfg

    # --- Swap, BEFORE anything that allocates ---------------------------
    #
    # 2 GiB RAM + 2 GiB swap is Discourse's documented floor. The image
    # build (asset precompile) is what needs it; steady state does not.
    if [ ! -f /swapfile ]; then
      dd if=/dev/zero of=/swapfile bs=1M count=2048
      chmod 0600 /swapfile
      mkswap /swapfile
      swapon /swapfile
      echo '/swapfile none swap sw 0 0' >>/etc/fstab
    fi
    sysctl -w vm.swappiness=10
    echo 'vm.swappiness=10' >/etc/sysctl.d/99-discourse.conf

    # --- Packages -------------------------------------------------------
    dnf -y install docker git jq htop
    systemctl enable --now docker

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

    # --- Launcher -------------------------------------------------------
    #
    # Cloned BEFORE anything writes under /var/discourse: git refuses a
    # destination that already exists and is not empty.
    if [ ! -d /var/discourse/.git ]; then
      git clone https://github.com/discourse/discourse_docker.git /var/discourse
    fi
    cd /var/discourse
    chmod 700 containers

    # --- RDS CA, so the app can verify-full ------------------------------
    #
    # NOT indent()ed, for the reason the htoprc block above gives: indented
    # base64 is not PEM, and psql rejects it with "bad end line" — measured
    # 2026-09-16, with verify-full silently not in effect until then.
    mkdir -p /var/discourse/shared/rds
    cat >/var/discourse/shared/rds/ca.pem <<'PEM'
    ${module.rds_ca.pem}
    PEM
    chmod 0444 /var/discourse/shared/rds/ca.pem
    # Refuse to boot on a bundle psql cannot parse: the failure it replaces
    # was silent, and a forum quietly skipping TLS verification is worse
    # than one that stops here.
    openssl crl2pkcs7 -nocrl -certfile /var/discourse/shared/rds/ca.pem | openssl pkcs7 -print_certs -noout >/dev/null

    # --- Secrets --------------------------------------------------------
    #
    # Read once, into root-only files the launcher reads at build time.
    # The Postmark token is set by hand into its container; an empty
    # secret here means "not yet" and the build refuses rather than ships
    # a forum that cannot send mail.
    #
    # xtrace OFF from here through the app.yml write: `set -x` would echo
    # every password into cloud-init-output.log, undoing the reason they
    # come from Secrets Manager at all.
    set +x
    umask 077
    mkdir -p /root/.discourse
    aws secretsmanager get-secret-value --secret-id '${module.db.secret_arn}' \
      --query SecretString --output text >/root/.discourse/db.json
    VALKEY_AUTH="$(aws secretsmanager get-secret-value --secret-id '${aws_secretsmanager_secret.valkey_auth.arn}' \
      --query SecretString --output text)"
    SMTP_PASS="$(aws secretsmanager get-secret-value --secret-id '${aws_secretsmanager_secret.smtp.arn}' \
      --query SecretString --output text 2>/dev/null || true)"
    if [ -z "$SMTP_PASS" ]; then
      echo "smtp-password secret is empty: put the Postmark server token in it, then re-run the bootstrap recipe"
      exit 1
    fi

    DB_HOST="$(jq -r .host   /root/.discourse/db.json)"
    DB_PORT="$(jq -r .port   /root/.discourse/db.json)"
    DB_USER="$(jq -r .username /root/.discourse/db.json)"
    DB_PASS="$(jq -r .password /root/.discourse/db.json)"
    DB_NAME="$(jq -r .dbname /root/.discourse/db.json)"

    # web_only: no bundled Postgres or Redis. Both are ours, outside.
    #
    # Unquoted heredoc so $DB_*/$VALKEY_AUTH/$SMTP_PASS expand at boot.
    # The launcher's own variables ($home) are therefore escaped, or bash
    # under set -u dies on them before the file is ever written.
    cat >containers/app.yml <<YML
    templates:
      - "templates/web.template.yml"
      - "templates/web.ratelimited.template.yml"
      - "templates/web.ssl.template.yml"
      - "templates/web.letsencrypt.ssl.template.yml"

    # Bound to the box; the NAT forwards the public 80/443 here.
    expose:
      - "80:80"
      - "443:443"

    params:
      db_default_text_search_config: "pg_catalog.english"

    env:
      LC_ALL: en_US.UTF-8
      LANG: en_US.UTF-8
      LANGUAGE: en_US.UTF-8
      # One web worker. Sidekiq (~540 MB, not a knob) plus two workers put
      # a 2 GiB box 550 MB into swap (measured 2026-09-16); one worker is
      # plenty for a small community and takes it off swap. Grow the
      # instance, not this number, if the forum outgrows it.
      UNICORN_WORKERS: 1

      DISCOURSE_HOSTNAME: '${var.hostname}'
      DISCOURSE_DEVELOPER_EMAILS: '${join(",", var.admin_emails)}'

      DISCOURSE_DB_HOST: '$DB_HOST'
      DISCOURSE_DB_PORT: '$DB_PORT'
      DISCOURSE_DB_NAME: '$DB_NAME'
      DISCOURSE_DB_USERNAME: '$DB_USER'
      DISCOURSE_DB_PASSWORD: '$DB_PASS'
      # verify-full against the vendored RDS root, mounted below.
      DISCOURSE_DB_SSLMODE: 'verify-full'
      DISCOURSE_DB_SSLROOTCERT: '/shared/rds/ca.pem'

      DISCOURSE_REDIS_HOST: '${aws_route53_record.valkey_master.name}'
      DISCOURSE_REDIS_PORT: '6379'
      DISCOURSE_REDIS_PASSWORD: '$VALKEY_AUTH'

      DISCOURSE_SMTP_ADDRESS: '${var.smtp_host}'
      DISCOURSE_SMTP_PORT: '${var.smtp_port}'
      DISCOURSE_SMTP_USER_NAME: '$SMTP_PASS'
      DISCOURSE_SMTP_PASSWORD: '$SMTP_PASS'
      DISCOURSE_SMTP_ENABLE_START_TLS: 'true'
      DISCOURSE_SMTP_DOMAIN: '${var.hostname}'
      DISCOURSE_NOTIFICATION_EMAIL: '${var.notification_email}'

      # Uploads and backups live in S3, not on this box — the last state
      # that made the instance non-disposable. The instance role is the
      # credential; there are no access keys.
      DISCOURSE_USE_S3: 'true'
      DISCOURSE_S3_USE_IAM_PROFILE: 'true'
      DISCOURSE_S3_REGION: '${var.region}'
      DISCOURSE_S3_BUCKET: '${aws_s3_bucket.uploads.bucket}'
      DISCOURSE_BACKUP_LOCATION: 's3'
      DISCOURSE_S3_BACKUP_BUCKET: '${aws_s3_bucket.backups.bucket}'

      LETSENCRYPT_ACCOUNT_EMAIL: '${var.letsencrypt_email}'

    volumes:
      - volume:
          host: /var/discourse/shared/standalone
          guest: /shared
      - volume:
          host: /var/discourse/shared/standalone/log/var-log
          guest: /var/log
      - volume:
          host: /var/discourse/shared/rds
          guest: /shared/rds

    hooks:
      after_code:
        - exec:
            cd: \$home/plugins
            cmd:
              - git clone https://github.com/discourse/docker_manager.git

    run:
      - exec: echo "Beginning of custom commands"
      - exec: echo "End of custom commands"
    YML
    chmod 600 containers/app.yml

    # --- Build and start ------------------------------------------------
    #
    # The launcher's bootstrap builds the image (assets, plugins) then
    # starts it. Let's Encrypt issues on the first start, over HTTP-01
    # against the public hostname — which must already point at the NAT.
    #
    # xtrace stays OFF. `launcher start` prints its full `docker run` line —
    # every env var expanded, every password in it — so its output is
    # dropped to a line count rather than reaching cloud-init-output.log.
    # Bootstrap's output is the build log, has no secrets, and is kept.
    ./launcher bootstrap app
    # Captured, not piped: the launcher's exit status alone decides the
    # boot, and only the secret-free lines are echoed.
    START_OUT="$(./launcher start app 2>&1)"
    printf '%s\n' "$START_OUT" | grep -vE 'docker run|DISCOURSE_(DB|REDIS|SMTP)_' || true
  BASH
}
