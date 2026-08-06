#!/usr/bin/env bash
#
#  Builds anonx_<version>_all.deb  ->  packaging/dist/
#     ./packaging/build-deb.sh
#
#  Install the result with:   sudo apt install ./packaging/dist/anonx_1.0_all.deb
#
set -e

SRC=$(cd "$(dirname "$0")/.." && pwd)
VER=$(grep -m1 '^VERSION=' "$SRC/anonx" | cut -d'"' -f2)
MAINTAINER="sidh4ck3r <69258027+sid-hack3r@users.noreply.github.com>"
OUT="$SRC/packaging/dist"
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

echo "building anonx $VER"

install -Dm755 "$SRC/anonx"        "$BUILD/usr/bin/anonx"
install -Dm644 "$SRC/shell/tor.sh" "$BUILD/usr/share/anonx/tor-shell.sh"
install -Dm644 "$SRC/README.md"    "$BUILD/usr/share/doc/anonx/README.md"
install -Dm644 "$SRC/LICENSE"      "$BUILD/usr/share/doc/anonx/copyright"

install -d "$BUILD/DEBIAN"
cat > "$BUILD/DEBIAN/control" <<EOF
Package: anonx
Version: $VER
Section: net
Priority: optional
Architecture: all
Depends: tor, macchanger, ethtool, iptables, iproute2, curl, xxd, e2fsprogs,
 dnsutils, iputils-ping, systemd
Recommends: network-manager
Maintainer: $MAINTAINER
Homepage: https://github.com/sid-hack3r/anonx
Description: transparent Tor gateway with MAC randomization
 anonx routes every TCP connection and every DNS query on the machine through
 Tor using iptables, blocks IPv6, randomizes the MAC address through
 NetworkManager and rotates the Tor exit IP on a configurable timer.
 .
 A kill-switch rule drops anything that is not going to Tor, so a Tor failure
 stops traffic instead of leaking it. Includes doctor and repair commands to
 diagnose and recover the network.
EOF

cat > "$BUILD/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
TORRC=/etc/tor/torrc

if [ "$1" = "configure" ]; then
  # transparent-proxy configuration
  if ! grep -q "anonx transparent proxy" "$TORRC" 2>/dev/null; then
    [ -f "$TORRC.pre-anonx" ] || cp -f "$TORRC" "$TORRC.pre-anonx" 2>/dev/null || true
    cat >> "$TORRC" <<'TORCFG'

# --- anonx transparent proxy (added by the anonx package) ---
VirtualAddrNetwork 10.192.0.0/10
AutomapHostsOnResolve 1
TransPort 9040
DNSPort 5353
SocksPort 9050
ControlPort 9051
CookieAuthentication 1
CookieAuthFileGroupReadable 1
# --- end anonx ---
TORCFG
  fi

  # anonx starts and stops Tor itself; it must not come up on its own
  systemctl disable tor@default >/dev/null 2>&1 || true
  systemctl disable tor         >/dev/null 2>&1 || true

  # interactive `tor` helper
  for rc in /root/.zshrc /root/.bashrc /home/*/.zshrc /home/*/.bashrc; do
    [ -f "$rc" ] || continue
    grep -q "anonx/tor-shell.sh" "$rc" 2>/dev/null && continue
    printf '\n# anonx: keep a bare `tor` usable while the tor service holds the ports\n[ -f /usr/share/anonx/tor-shell.sh ] && . /usr/share/anonx/tor-shell.sh\n' >> "$rc"
  done

  # a previous manual install would shadow the packaged binary
  # -L too: /usr/sbin/anonx is usually a symlink, and once its target is gone
  # a plain -e test misses it and leaves a dangling link earlier in PATH
  for old in /usr/local/bin/anonx /usr/sbin/anonx; do
    if { [ -e "$old" ] || [ -L "$old" ]; } && ! dpkg -S "$old" >/dev/null 2>&1; then
      rm -f "$old"
      echo "anonx: removed older manual install at $old"
    fi
  done

  echo "anonx installed — run:  sudo anonx start"
fi
exit 0
EOF

cat > "$BUILD/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
# never leave a locked firewall, pinned DNS or spoofed MAC behind
[ -x /usr/bin/anonx ] && /usr/bin/anonx repair >/dev/null 2>&1 || true
for rc in /root/.zshrc /root/.bashrc /home/*/.zshrc /home/*/.bashrc; do
  [ -f "$rc" ] || continue
  sed -i '/# anonx: keep a bare/d;/anonx\/tor-shell.sh/d' "$rc" 2>/dev/null || true
done
exit 0
EOF

cat > "$BUILD/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "purge" ]; then
  if [ -f /etc/tor/torrc.pre-anonx ]; then
    mv -f /etc/tor/torrc.pre-anonx /etc/tor/torrc
  else
    sed -i '/# --- anonx transparent proxy/,/# --- end anonx ---/d' /etc/tor/torrc 2>/dev/null || true
  fi
  rm -rf /var/lib/anonx /etc/anonx.conf
  rm -f /etc/systemd/system/anonx.service
  systemctl daemon-reload >/dev/null 2>&1 || true
fi
exit 0
EOF

chmod 755 "$BUILD/DEBIAN/postinst" "$BUILD/DEBIAN/prerm" "$BUILD/DEBIAN/postrm"

mkdir -p "$OUT"
DEB="$OUT/anonx_${VER}_all.deb"
dpkg-deb --root-owner-group --build "$BUILD" "$DEB" >/dev/null

echo "built: $DEB"
command -v lintian >/dev/null 2>&1 && lintian --no-tag-display-limit "$DEB" 2>/dev/null | head -10
echo
echo "install it:   sudo apt install $DEB"
