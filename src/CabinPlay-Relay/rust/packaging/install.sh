#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: AGPL-3.0-only
# Created by riko chen on 2026-10-15
# Usage: [DESTDIR=/absolute/staging/root] install.sh CABINPLAY_RELAY_BINARY OXP_RELAY_BINARY WEB_ASSETS ADMIN_ASSETS [PLUGINS_BUNDLE]
set -eu
# The Debian builder uses this same host payload installer.
install_host_tuning() {
  host_dir="$(dirname "$0")/host"
  install -d -m 0755 "$1/etc/NetworkManager/conf.d" "$1/usr/lib/cabinplay-relay"
  install -m 0644 "$host_dir/cabinplay-relay-wifi-powersave.conf" \
    "$host_dir/cabinplay-relay-wifi-scan-mac.conf" "$1/etc/NetworkManager/conf.d/"
  install -m 0755 "$host_dir/clock-guard" "$1/usr/lib/cabinplay-relay/clock-guard"
}
if [ "${1:-}" = --install-host-tuning ]; then
  [ "$#" -eq 2 ] && [ -n "$2" ] || exit 2
  case "$2" in /*) ;; *) exit 2 ;; esac
  install_host_tuning "${2%/}"
  exit 0
fi
if [ "$#" -ne 4 ] && [ "$#" -ne 5 ]; then
  echo "Usage: $0 CABINPLAY_RELAY_BINARY OXP_RELAY_BINARY WEB_ASSETS ADMIN_ASSETS [PLUGINS_BUNDLE]" >&2
  exit 2
fi
DESTDIR=${DESTDIR:-}
case "$DESTDIR" in ""|/*) ;; *) echo "DESTDIR must be absolute" >&2; exit 2 ;; esac
case "$DESTDIR" in ''|*[!/]*) ;; *) echo "Use an empty DESTDIR for live installation" >&2; exit 2 ;; esac
DESTDIR=${DESTDIR%/}
if [ -z "$DESTDIR" ] && [ "$(id -u)" -ne 0 ]; then
  echo "Run as root on the target device." >&2
  exit 1
fi
for binary in "$1" "$2"; do test -f "$binary"; done
# The receiver page lives at receiver/index.html; the admin page at the root.
test -f "$3/receiver/index.html"
test -f "$4/index.html"
# Identity material is supplied separately by the operator, never by this package.
for assets in "$3" "$4"; do
  if find "$assets" -type f \( -name identity.pk8 -o -name certificate.p7b \) | read -r ignored; then
    echo "Refusing asset directory containing MFi identity material: $assets" >&2
    exit 1
  fi
done
# Optional bundle is a prebuilt host/ + p/ install directory; no runtime dependency.
plugins_stage=
if [ "$#" -eq 5 ]; then
  plugins_stage=$(mktemp -d)
  trap 'rm -rf "$plugins_stage"' 0
  python3 "$(dirname "$0")/plugins-bundle.py" "$5" "$plugins_stage"
fi
install -d -m 0755 "$DESTDIR/opt/cabinplay/bin" "$DESTDIR/opt/cabinplay/share/web" "$DESTDIR/opt/cabinplay/share/admin"
install -m 0755 "$1" "$DESTDIR/opt/cabinplay/bin/cabinplay-relay"
install -m 0755 "$2" "$DESTDIR/opt/cabinplay/bin/oxp-relay"
cp -Rf "$3/." "$DESTDIR/opt/cabinplay/share/web/"
cp -Rf "$4/." "$DESTDIR/opt/cabinplay/share/admin/"
if [ -n "$plugins_stage" ]; then
  install -d -m 0755 "$DESTDIR/opt/cabinplay/share/plugins"
  cp -Rf "$plugins_stage/." "$DESTDIR/opt/cabinplay/share/plugins/"
  find "$DESTDIR/opt/cabinplay/share/plugins" -type d -exec chmod 0755 {} +
  find "$DESTDIR/opt/cabinplay/share/plugins" -type f -exec chmod 0644 {} +
fi
# Preserve both project licenses and component notices with the installed build.
# A device bundle ships them next to this script; the repository keeps them at its root.
license_dir="$(dirname "$0")/licenses"
[ -f "$license_dir/LICENSE" ] || license_dir="$(dirname "$0")/../.."
install -d -m 0755 "$DESTDIR/opt/cabinplay/share/licenses"
install -m 0644 "$license_dir/LICENSE" "$license_dir/LICENSE-GPL-3.0" "$license_dir/NOTICE" "$DESTDIR/opt/cabinplay/share/licenses/"
install -d -m 0700 "$DESTDIR/var/lib/cabinplay" "$DESTDIR/var/lib/cabinplay/mfi"
# Older device bundles ship only install.sh and the unit.
if [ -d "$(dirname "$0")/host" ]; then
  install_host_tuning "$DESTDIR"
else
  echo "Host tuning files not bundled next to install.sh; skipped." >&2
fi
install -d -m 0755 "$DESTDIR/etc/systemd/system"
install -m 0644 "$(dirname "$0")/cabinplay-relay.service" "$DESTDIR/etc/systemd/system/cabinplay-relay.service"
if [ -n "$DESTDIR" ]; then
  systemctl --root="$DESTDIR" enable cabinplay-relay.service
else
  nmcli general reload >/dev/null 2>&1 || :
  systemctl daemon-reload
  systemctl enable cabinplay-relay.service
fi
printf '%s\n' 'Installed. Supply your MFi identity separately:' \
  '  /var/lib/cabinplay/mfi/identity.pk8' \
  '  /var/lib/cabinplay/mfi/certificate.p7b' \
  'Set both files to mode 0600, then run systemctl start cabinplay-relay.service.' \
  'First setup: https://cabinplay-admin.local:6975 (LAN) or https://cabinplay-car.local:6975 (CarPlay network) (password: cabinplay).' \
  'Requires NetworkManager (nmcli), iw, dnsmasq-base (shared-mode DHCP),' \
  'BlueZ (bluetoothctl, btmgmt, sdptool, hciconfig), and kernel RFCOMM support.'
