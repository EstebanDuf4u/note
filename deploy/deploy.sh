#!/bin/bash
# Installs a release of the Note+ server, and goes back to the previous one
# if the new one doesn't answer.
#
# Usage (as root): deploy.sh <release tarball> <version>
# The CI runs it through sudo; see deploy/setup-server.sh.
set -euo pipefail

TARBALL="$1"
VERSION="$2"
ROOT=/opt/note
RELEASE="$ROOT/releases/$VERSION"
KEEP=5

if [[ ! "$VERSION" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid version: $VERSION" >&2
  exit 2
fi

echo "Installing $VERSION"
rm -rf "$RELEASE"
mkdir -p "$RELEASE"
tar -xzf "$TARBALL" -C "$RELEASE"
chown -R root:root "$RELEASE"
chmod 755 "$RELEASE/bin/note-server"
rm -f "$TARBALL"

PREVIOUS=""
if [ -L "$ROOT/current" ]; then
  PREVIOUS="$(readlink -f "$ROOT/current")"
fi

# switch atomically
ln -sfn "$RELEASE" "$ROOT/current.new"
mv -Tf "$ROOT/current.new" "$ROOT/current"
systemctl restart note

healthy() {
  for _ in $(seq 1 20); do
    if curl -fsS -H 'Accept: application/json' http://127.0.0.1:8787/ | grep -q '"noteplus"'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

if healthy; then
  echo "Note+ $VERSION is up"
else
  echo "Note+ $VERSION doesn't answer" >&2
  journalctl -u note -n 30 --no-pager >&2 || true
  if [ -n "$PREVIOUS" ] && [ "$PREVIOUS" != "$RELEASE" ]; then
    echo "Going back to $(basename "$PREVIOUS")" >&2
    ln -sfn "$PREVIOUS" "$ROOT/current.new"
    mv -Tf "$ROOT/current.new" "$ROOT/current"
    systemctl restart note
  fi
  exit 1
fi

# keep the last few releases, to go back by hand if needed
ls -1dt "$ROOT"/releases/*/ | tail -n +$((KEEP + 1)) | xargs -r rm -rf
