#!/usr/bin/env bash
#
#  anonx uninstaller — restores your network, then removes EVERYTHING anonx.
#     sudo ./uninstall.sh          full removal (default)
#     sudo ./uninstall.sh --keep-torrc   leave the /etc/tor/torrc block in place
#
set -o pipefail

R=$'\e[31m'; G=$'\e[32m'; C=$'\e[36m'; Y=$'\e[33m'; D=$'\e[2m'; W=$'\e[1;37m'; N=$'\e[0m'
ok(){   printf "  ${G}✔${N} %s\n" "$1"; }
info(){ printf "  ${C}•${N} %s\n" "$1"; }
warn(){ printf "  ${Y}!${N} %s\n" "$1"; }

[ "$(id -u)" -eq 0 ] || { echo "${R}run as root:  sudo ./uninstall.sh${N}"; exit 1; }

KEEP_TORRC=0
[ "$1" = "--keep-torrc" ] && KEEP_TORRC=1

echo "${W}  removing anonx — everything${N}"
printf "${D}────────────────────────────────────────────────────────${N}\n"

# 1) put the network back to normal FIRST (unlock firewall, DNS, MAC, timezone)
ANONX_BIN=$(command -v anonx 2>/dev/null || echo /usr/local/bin/anonx)
if [ -x "$ANONX_BIN" ]; then
  info "restoring network to normal..."
  "$ANONX_BIN" repair >/dev/null 2>&1
  "$ANONX_BIN" disable >/dev/null 2>&1
  ok "firewall, DNS, MAC and timezone restored"
fi

# 2) boot service + systemd drop-ins we added
rm -f /etc/systemd/system/anonx.service
rm -rf /etc/systemd/system/tor@default.service.d/anonx.conf
# drop the now-empty override dir if nothing else lives there
rmdir /etc/systemd/system/tor@default.service.d 2>/dev/null
systemctl daemon-reload 2>/dev/null
systemctl reset-failed tor@default 2>/dev/null
ok "systemd units and drop-ins removed"

# 3) the binary + every symlink to it, wherever it landed
rm -f /usr/local/bin/anonx /usr/sbin/anonx /usr/bin/anonx /bin/anonx
ok "anonx binary and symlinks removed"

# 4) data, config, state, and any shell helper
rm -rf /var/lib/anonx            # state: prev copy, interval, rotate.log, backups
rm -f  /etc/anonx.conf           # user config
rm -rf /usr/local/share/anonx /usr/share/anonx   # shell helper (old installs)
rm -f  /tmp/anonx.* 2>/dev/null
ok "state, config and helper files removed"

# 5) lines we appended to shell rc files
for rc in /root/.zshrc /root/.bashrc /home/*/.zshrc /home/*/.bashrc; do
  [ -f "$rc" ] || continue
  grep -q "anonx/tor-shell.sh" "$rc" 2>/dev/null || continue
  sed -i '/# anonx: keep a bare/d;/anonx\/tor-shell.sh/d' "$rc"
done
ok "shell rc entries cleaned"

# 6) the torrc transparent-proxy block (restore the pre-anonx backup if we have one)
if [ "$KEEP_TORRC" -eq 0 ]; then
  if [ -f /etc/tor/torrc.pre-anonx ]; then
    mv -f /etc/tor/torrc.pre-anonx /etc/tor/torrc
    ok "torrc restored from the pre-anonx backup"
  elif grep -q "anonx transparent proxy" /etc/tor/torrc 2>/dev/null; then
    # current marker style
    sed -i '/# --- anonx transparent proxy/,/# --- end anonx ---/d' /etc/tor/torrc
    # legacy marker style from very early builds (## ===== ... ===== )
    sed -i '/## ===== anonx transparent proxy/,/^## =\{5,\}$/d' /etc/tor/torrc
    ok "anonx block stripped from torrc"
  fi
  # also remove any bridges block we may have added
  sed -i '/# --- anonx bridges/,/# --- end anonx bridges ---/d' /etc/tor/torrc 2>/dev/null
  systemctl restart tor@default >/dev/null 2>&1
  systemctl stop tor@default    >/dev/null 2>&1
else
  info "kept the torrc block (--keep-torrc)"
fi

# 7) final sweep — prove nothing anonx is left behind
printf "${D}────────────────────────────────────────────────────────${N}\n"
left=$(ls -d /usr/local/bin/anonx /usr/sbin/anonx /usr/bin/anonx /bin/anonx \
              /var/lib/anonx /etc/anonx.conf /usr/local/share/anonx /usr/share/anonx \
              /etc/systemd/system/anonx.service \
              /etc/systemd/system/tor@default.service.d/anonx.conf 2>/dev/null)
if [ -z "$left" ] && ! command -v anonx >/dev/null 2>&1; then
  ok "clean — no anonx files remain anywhere"
else
  warn "these could not be removed (remove by hand):"
  printf '      %s\n' $left
  command -v anonx >/dev/null 2>&1 && printf '      %s\n' "$(command -v anonx)"
fi
printf "${D}────────────────────────────────────────────────────────${N}\n"
ok "anonx fully uninstalled"
