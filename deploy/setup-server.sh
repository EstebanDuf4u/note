#!/bin/bash
# Prepares a server to run Note+, once. Safe to run again.
#
#   sudo ./setup-server.sh <public key of the CI> [email for the certificate]
#
# It creates the `note` user that runs the server, the `deploy` user that the
# CI connects as (it may only run /opt/note/deploy.sh as root), the systemd
# service, and the nginx site for note.noryx.fr with its https certificate.
set -euo pipefail

DOMAIN=note.noryx.fr
HERE="$(cd "$(dirname "$0")" && pwd)"
CI_KEY_FILE="${1:?usage: setup-server.sh <ci public key file> [email]}"
EMAIL="${2:-}"

echo "== users"
id note >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin note
id deploy >/dev/null 2>&1 || useradd --create-home --shell /bin/bash deploy
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
install -m 600 -o deploy -g deploy "$CI_KEY_FILE" /home/deploy/.ssh/authorized_keys

echo "== directories"
install -d -m 755 /opt/note /opt/note/releases
install -d -m 750 -o note -g note /var/lib/note
install -d -m 755 /etc/note
[ -f /etc/note/note.env ] || echo 'NOTE_ARGS=' > /etc/note/note.env

echo "== deploy script and service"
install -m 755 -o root -g root "$HERE/deploy.sh" /opt/note/deploy.sh
install -m 644 "$HERE/note.service" /etc/systemd/system/note.service
systemctl daemon-reload
systemctl enable note >/dev/null

SUDOERS=/etc/sudoers.d/note-deploy
echo 'deploy ALL=(root) NOPASSWD: /opt/note/deploy.sh' > "$SUDOERS.tmp"
chmod 440 "$SUDOERS.tmp"
visudo -cf "$SUDOERS.tmp" >/dev/null
mv "$SUDOERS.tmp" "$SUDOERS"

echo "== nginx"
if [ ! -f "/etc/nginx/sites-available/$DOMAIN" ]; then
  install -m 644 "$HERE/nginx-note.conf" "/etc/nginx/sites-available/$DOMAIN"
fi
ln -sfn "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"
nginx -t
systemctl reload nginx

echo "== https"
SERVER_IP="$(curl -fsS4 https://ifconfig.me || true)"
DOMAIN_IP="$( (getent ahostsv4 "$DOMAIN" || true) | awk 'NR==1 {print $1}')"
if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
  echo "certificate already there"
elif [ -n "$DOMAIN_IP" ] && [ "$DOMAIN_IP" = "$SERVER_IP" ]; then
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --redirect \
    ${EMAIL:+-m "$EMAIL"} ${EMAIL:---register-unsafely-without-email}
else
  echo "$DOMAIN doesn't point to this server ($SERVER_IP) yet: add a DNS A record,"
  echo "then run this script again to get the https certificate."
fi

echo "== done"
