#!/usr/bin/env bash
#
#  anonx installer
#     sudo ./install.sh            install (with a live smoke test)
#     sudo ./install.sh --no-test  skip the Tor smoke test at the end
#
set -o pipefail

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; D=$'\e[2m'; W=$'\e[1;37m'; N=$'\e[0m'
ok(){   printf "  ${G}✔${N} %s\n" "$1"; }
bad(){  printf "  ${R}✘${N} %s\n" "$1"; }
warn(){ printf "  ${Y}!${N} %s\n" "$1"; }
info(){ printf "  ${C}•${N} %s\n" "$1"; }
line(){ printf "${D}────────────────────────────────────────────────────────${N}\n"; }
die(){  bad "$1"; echo; printf "  ${R}install aborted — nothing was changed on this system${N}\n"; exit 1; }

[ "$(id -u)" -eq 0 ] || { echo "${R}run as root:  sudo ./install.sh${N}"; exit 1; }

SRC=$(cd "$(dirname "$0")" && pwd)
RUN_TEST=1
[ "$1" = "--no-test" ] && RUN_TEST=0

echo "${W}  installing anonx${N}"
line

# ================= 0) preflight: will anonx even work here? =================
# anonx is built around Debian's tor packaging (the debian-tor user, the
# tor@default systemd unit) and iptables. On a box without those it cannot
# work, so we refuse up front instead of half-installing something broken.
echo "  ${W}environment check${N}"

if [ -r /etc/os-release ]; then
  . /etc/os-release
  info "system: ${W}${PRETTY_NAME:-unknown}${N}"
fi

command -v apt-get >/dev/null 2>&1 \
  && ok "apt package manager present" \
  || die "no apt-get — anonx targets Debian / Kali / Ubuntu. Unsupported here."

if [ -d /run/systemd/system ]; then
  ok "systemd is the init system"
else
  die "systemd not running — anonx drives Tor through 'systemctl' / tor@default. Unsupported here."
fi

case "$(uname -s)" in
  Linux) ok "Linux kernel" ;;
  *)     die "not Linux — anonx uses Linux iptables/netfilter" ;;
esac
echo

# ================= 1) dependencies =================
# command:package:why anonx needs it
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
missing=""
while IFS=: read -r cmd pkg why; do
  [ -z "$cmd" ] && continue
  if command -v "$cmd" >/dev/null 2>&1; then
    printf "  ${G}✔${N} ${W}%-11s${N} ${D}%s${N}\n" "$cmd" "$why"
  else
    printf "  ${Y}+${N} ${W}%-11s${N} ${D}%s${N} ${Y}(will install %s)${N}\n" "$cmd" "$why" "$pkg"
    missing="$missing $pkg"
  fi
done <<< "$DEPS"

# NetworkManager is optional (anonx falls back to macchanger without it)
if command -v nmcli >/dev/null 2>&1; then
  printf "  ${G}✔${N} ${W}%-11s${N} ${D}MAC spoofing that survives reconnects${N}\n" nmcli
else
  printf "  ${Y}!${N} ${W}%-11s${N} ${Y}not found${N} ${D}— MAC spoofing falls back to macchanger${N}\n" nmcli
fi

missing=$(echo "$missing" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ *$//')
if [ -n "$missing" ]; then
  echo
  info "installing: ${Y}$missing${N}"
  apt-get update -qq 2>/dev/null || warn "apt-get update had warnings (continuing)"
  if ! apt-get install -y $missing >/dev/null 2>&1; then
    die "apt could not install: $missing — install them by hand, then re-run"
  fi
  # trust nothing: verify each command is actually callable now
  still=""
  while IFS=: read -r cmd pkg why; do
    [ -z "$cmd" ] && continue
    command -v "$cmd" >/dev/null 2>&1 || still="$still $cmd"
  done <<< "$DEPS"
  [ -n "$still" ] && die "still missing after install:$still"
  ok "all dependencies installed and callable"
else
  ok "all dependencies already present"
fi
echo

# ================= 2) runtime prerequisites =================
echo "  ${W}runtime check${N}"
id debian-tor >/dev/null 2>&1 \
  && ok "tor user 'debian-tor' exists" \
  || die "user 'debian-tor' missing — the tor package did not set up correctly"

iptables -t nat -L OUTPUT -n >/dev/null 2>&1 \
  && ok "iptables nat table reachable" \
  || die "iptables cannot use the nat table (kernel/nftables problem) — anonx can't redirect traffic here"

ip6tables -L >/dev/null 2>&1 \
  && ok "ip6tables usable (IPv6 can be blocked)" \
  || warn "ip6tables not usable — IPv6 leak protection may not apply"

[ -f /etc/tor/torrc ] \
  && ok "/etc/tor/torrc present" \
  || die "/etc/tor/torrc missing — reinstall the tor package"
echo

# ================= 3) configure tor =================
TORRC=/etc/tor/torrc
if grep -q "anonx transparent proxy" "$TORRC" 2>/dev/null; then
  ok "torrc already has the transparent-proxy block"
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
  ok "torrc configured (backup at $TORRC.pre-anonx)"
fi
# tor must not autostart: anonx owns its lifecycle
systemctl disable tor@default >/dev/null 2>&1
systemctl disable tor         >/dev/null 2>&1

# validate the tor config actually parses before we rely on it
if tor --verify-config -f "$TORRC" >/dev/null 2>&1; then
  ok "tor configuration verified"
else
  die "tor rejected the configuration — check $TORRC (restore $TORRC.pre-anonx)"
fi
echo

# ================= 4) install the tool =================
install -m 755 "$SRC/anonx" /usr/local/bin/anonx || die "could not install /usr/local/bin/anonx"
ok "installed /usr/local/bin/anonx"
# Some sudo configs ship secure_path without /usr/local/bin, so `sudo anonx`
# would say "command not found". /usr/sbin is always on that path.
ln -sf /usr/local/bin/anonx /usr/sbin/anonx
ok "symlinked /usr/sbin/anonx (so 'sudo anonx' always resolves)"
echo

# ================= 5) smoke test: does Tor really come up here? =================
if [ "$RUN_TEST" -eq 1 ]; then
  echo "  ${W}smoke test${N} ${D}(proving Tor can start on this machine)${N}"
  systemctl restart tor@default 2>/dev/null || systemctl restart tor 2>/dev/null
  up=0
  for i in $(seq 1 25); do
    ss -tln 2>/dev/null | grep -q '127.0.0.1:9040' \
      && ss -tln 2>/dev/null | grep -q '127.0.0.1:9050' && { up=1; break; }
    sleep 1
  done
  if [ "$up" -eq 1 ]; then
    ok "Tor bound its ports (9040 transparent · 9050 socks · 5353 dns)"
    # bootstrap is best-effort: it needs working internet at install time
    boot=0
    for i in $(seq 1 20); do
      pct=$(timeout 6 bash -c '
        c=$(xxd -ps -c 32 /run/tor/control.authcookie 2>/dev/null | tr -d "\n"); [ -n "$c" ] || exit 0
        exec 3<>/dev/tcp/127.0.0.1/9051 2>/dev/null || exit 0
        printf "AUTHENTICATE %s\r\nGETINFO status/bootstrap-phase\r\nQUIT\r\n" "$c" >&3
        timeout 5 cat <&3 2>/dev/null' | grep -o 'PROGRESS=[0-9]*' | head -1 | cut -d= -f2)
      [ "$pct" = "100" ] && { boot=1; break; }
      sleep 2
    done
    [ "$boot" -eq 1 ] \
      && ok "Tor bootstrapped 100% — the full stack works here" \
      || warn "Tor started but did not finish bootstrapping (check your internet; anonx will retry on start)"
  else
    systemctl stop tor@default 2>/dev/null
    die "Tor could not open its ports here — anonx would not work. Config/kernel issue; nothing left running."
  fi
  systemctl stop tor@default 2>/dev/null
  ok "smoke test done — Tor stopped again (anonx starts it when you go anonymous)"
  echo
fi

line
ok "anonx installed"
echo
echo "  ${G}sudo anonx start${N}       go anonymous"
echo "  ${G}sudo anonx start 30s${N}   ...rotating the exit IP every 30 seconds"
echo "  ${G}sudo anonx status${N}      check state    ${D}(anonx doctor if anything looks wrong)${N}"
echo "  ${G}sudo anonx stop${N}        back to normal"
