#!/usr/bin/env bash
#
#  anonx installer
#     sudo ./install.sh              full install (tool + torrc + shell helper)
#     sudo ./install.sh --no-shell   skip the interactive `tor` helper
#
set -o pipefail

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; D=$'\e[2m'; W=$'\e[1;37m'; N=$'\e[0m'
ok(){ printf "  ${G}✔${N} %s\n" "$1"; }
bad(){ printf "  ${R}✘${N} %s\n" "$1"; }
info(){ printf "  ${C}•${N} %s\n" "$1"; }

[ "$(id -u)" -eq 0 ] || { echo "${R}run as root:  sudo ./install.sh${N}"; exit 1; }

SRC=$(cd "$(dirname "$0")" && pwd)
WITH_SHELL=1
[ "$1" = "--no-shell" ] && WITH_SHELL=0

echo "${W}  installing anonx${N}"
printf "${D}────────────────────────────────────────────────────────${N}\n"

# ---------------- dependencies ----------------
# every external command anonx calls, and the package that provides it.
# "command:package:what it is needed for"
DEPS="
tor:tor:the Tor daemon itself
iptables:iptables:the transparent redirect and the kill switch
ip6tables:iptables:blocking IPv6
ip:iproute2:reading routes and link addresses
ss:iproute2:checking that Tor's ports are listening
macchanger:macchanger:MAC spoofing on non-NetworkManager links
ethtool:ethtool:reading the real (permanent) MAC
curl:curl:verifying that traffic really goes through Tor
xxd:xxd:reading Tor's control cookie
chattr:e2fsprogs:locking resolv.conf against rewrites
dig:dnsutils:testing Tor's DNS port in doctor
ping:iputils-ping:checking the link is really up after a MAC change
systemctl:systemd:starting and stopping the Tor service
"

echo "  ${W}dependency check${N}"
missing=""; report=""
while IFS=: read -r cmd pkg why; do
  [ -z "$cmd" ] && continue
  if command -v "$cmd" >/dev/null 2>&1; then
    report="$report  ${G}✔${N} ${W}$(printf '%-11s' "$cmd")${N} ${D}$why${N}\n"
  else
    report="$report  ${Y}+${N} ${W}$(printf '%-11s' "$cmd")${N} ${D}$why${N} ${Y}(will install $pkg)${N}\n"
    missing="$missing $pkg"
  fi
done <<< "$DEPS"
printf "$report"

# NetworkManager is not required, but without it a MAC spoof gets reverted on
# every reconnect, so anonx falls back to macchanger and warns
if command -v nmcli >/dev/null 2>&1; then
  ok "$(printf '%-11s' nmcli) ${D}MAC spoofing that survives reconnects${N}"
else
  printf "  ${Y}!${N} ${W}%-11s${N} ${Y}not found${N} ${D}— MAC spoofing falls back to macchanger${N}\n" nmcli
fi

missing=$(echo "$missing" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ *$//')
if [ -n "$missing" ]; then
  echo
  info "installing: ${Y}$missing${N}"
  apt-get update -qq 2>/dev/null
  apt-get install -y $missing >/dev/null 2>&1 || {
    bad "apt could not install: $missing"
    bad "install them by hand, then run this again"; exit 1; }

  # trust nothing: check again that every command is now really there
  still=""
  while IFS=: read -r cmd pkg why; do
    [ -z "$cmd" ] && continue
    command -v "$cmd" >/dev/null 2>&1 || still="$still $cmd"
  done <<< "$DEPS"
  [ -n "$still" ] && { bad "still missing after install:$still"; exit 1; }
  ok "all dependencies installed"
else
  ok "all dependencies already present"
fi

# ---------------- runtime sanity ----------------
id debian-tor >/dev/null 2>&1 \
  && ok "tor user 'debian-tor' exists ${D}(needed to exempt Tor from its own rules)${N}" \
  || { bad "user 'debian-tor' missing — reinstall the tor package"; exit 1; }

iptables -t nat -L OUTPUT -n >/dev/null 2>&1 \
  && ok "iptables works ${D}(nat table reachable)${N}" \
  || { bad "iptables cannot read the nat table — check your kernel/nftables setup"; exit 1; }

[ -f /etc/tor/torrc ] \
  && ok "found /etc/tor/torrc" \
  || { bad "/etc/tor/torrc missing — reinstall the tor package"; exit 1; }

pidof systemd >/dev/null 2>&1 \
  && ok "systemd is running" \
  || bad "systemd not detected — anonx controls Tor through systemctl"
echo

# ---------------- torrc ----------------
TORRC=/etc/tor/torrc
if grep -q "anonx transparent proxy" "$TORRC" 2>/dev/null; then
  ok "torrc already configured"
else
  cp -f "$TORRC" "$TORRC.pre-anonx" 2>/dev/null
  cat >> "$TORRC" <<'EOF'

# --- anonx transparent proxy (added by install.sh) ---
VirtualAddrNetwork 10.192.0.0/10
AutomapHostsOnResolve 1
TransPort 9040
DNSPort 5353
SocksPort 9050
ControlPort 9051
CookieAuthentication 1
CookieAuthFileGroupReadable 1
# --- end anonx ---
EOF
  ok "torrc updated (backup: $TORRC.pre-anonx)"
fi

# tor must not autostart on its own: anonx starts and stops it
systemctl disable tor@default >/dev/null 2>&1
systemctl disable tor        >/dev/null 2>&1

# ---------------- the tool ----------------
install -m 755 "$SRC/anonx" /usr/local/bin/anonx || { bad "could not install anonx"; exit 1; }
ok "installed /usr/local/bin/anonx"

# Many sudo configs (Kali among them) ship secure_path without /usr/local/bin,
# so `sudo anonx` fails with "command not found" while plain `anonx` works.
# /usr/sbin is always in that path and is the right place for a root-only tool.
ln -sf /usr/local/bin/anonx /usr/sbin/anonx
ok "symlinked /usr/sbin/anonx (so 'sudo anonx' resolves everywhere)"

# ---------------- interactive `tor` helper ----------------
if [ "$WITH_SHELL" -eq 1 ]; then
  install -d /usr/local/share/anonx
  install -m 644 "$SRC/shell/tor.sh" /usr/local/share/anonx/tor-shell.sh
  wired=0
  for rc in /root/.zshrc /root/.bashrc /home/*/.zshrc /home/*/.bashrc; do
    [ -f "$rc" ] || continue
    grep -q "anonx/tor-shell.sh" "$rc" 2>/dev/null && { wired=$((wired+1)); continue; }
    printf '\n# anonx: keep a bare `tor` usable while the tor service holds the ports\n[ -f /usr/local/share/anonx/tor-shell.sh ] && . /usr/local/share/anonx/tor-shell.sh\n' >> "$rc"
    wired=$((wired+1))
  done
  ok "shell helper installed ($wired rc files)"
fi

printf "${D}────────────────────────────────────────────────────────${N}\n"
ok "done"
echo
echo "  ${G}sudo anonx start${N}       go anonymous"
echo "  ${G}sudo anonx start 30s${N}   ...rotating the exit IP every 30 seconds"
echo "  ${G}sudo anonx status${N}      check state    ${D}(anonx doctor if anything looks wrong)${N}"
echo "  ${G}sudo anonx stop${N}        back to normal"
echo
echo "  ${D}open a new terminal (or: source ~/.zshrc) for the shell helper${N}"
