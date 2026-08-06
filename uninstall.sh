#!/usr/bin/env bash
#
#  anonx uninstaller — restores the network first, then removes everything.
#     sudo ./uninstall.sh              keep the torrc block
#     sudo ./uninstall.sh --purge      also revert /etc/tor/torrc and drop state
#
set -o pipefail

R=$'\e[31m'; G=$'\e[32m'; C=$'\e[36m'; D=$'\e[2m'; W=$'\e[1;37m'; N=$'\e[0m'
ok(){ printf "  ${G}✔${N} %s\n" "$1"; }
info(){ printf "  ${C}•${N} %s\n" "$1"; }

[ "$(id -u)" -eq 0 ] || { echo "${R}run as root:  sudo ./uninstall.sh${N}"; exit 1; }

echo "${W}  removing anonx${N}"
printf "${D}────────────────────────────────────────────────────────${N}\n"

# never leave a locked firewall or a spoofed MAC behind
if [ -x /usr/local/bin/anonx ]; then
  info "restoring network state..."
  /usr/local/bin/anonx repair >/dev/null 2>&1
  ok "firewall, DNS and MAC restored"
fi

/usr/local/bin/anonx disable >/dev/null 2>&1
rm -f /etc/systemd/system/anonx.service
systemctl daemon-reload 2>/dev/null
ok "boot service removed"

rm -f /usr/local/bin/anonx /usr/sbin/anonx
ok "binary removed"

# clean up the `tor` shell helper if an older version left it behind
rm -rf /usr/local/share/anonx
for rc in /root/.zshrc /root/.bashrc /home/*/.zshrc /home/*/.bashrc; do
  [ -f "$rc" ] || continue
  grep -q "anonx/tor-shell.sh" "$rc" 2>/dev/null || continue
  sed -i '/# anonx: keep a bare/d;/anonx\/tor-shell.sh/d' "$rc"
done

if [ "$1" = "--purge" ]; then
  if [ -f /etc/tor/torrc.pre-anonx ]; then
    mv -f /etc/tor/torrc.pre-anonx /etc/tor/torrc
    ok "torrc restored from backup"
  else
    sed -i '/# --- anonx transparent proxy/,/# --- end anonx ---/d' /etc/tor/torrc
    ok "anonx block stripped from torrc"
  fi
  rm -rf /var/lib/anonx
  ok "state directory removed"
  systemctl restart tor@default >/dev/null 2>&1
else
  info "kept /etc/tor/torrc and /var/lib/anonx  ${D}(use --purge to remove)${N}"
fi

printf "${D}────────────────────────────────────────────────────────${N}\n"
ok "anonx uninstalled"
