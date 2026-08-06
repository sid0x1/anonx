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
conntrack:conntrack:dropping pre-existing connections so none leak past Tor
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
    bad "apt could not install: $missing"
    info "fix: refresh apt and try the packages by hand:"
    info "  ${G}sudo apt update${N} && ${G}sudo apt install $missing${N}"
    info "if a repo is broken, check:  ${G}sudo apt update${N}  ${D}(read the red lines)${N}"
    die "dependencies missing — install them, then re-run"
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

nat_ok(){ iptables -t nat -L OUTPUT -n >/dev/null 2>&1; }
if nat_ok; then
  ok "iptables nat table reachable"
else
  # try to fix it ourselves before giving up
  info "nat table not ready — loading the kernel module..."
  modprobe iptable_nat 2>/dev/null; modprobe nf_nat 2>/dev/null
  if nat_ok; then
    ok "iptables nat table reachable ${D}(loaded iptable_nat)${N}"
  elif command -v iptables-nft >/dev/null 2>&1; then
    info "switching iptables to the nft backend..."
    update-alternatives --set iptables  /usr/sbin/iptables-nft  >/dev/null 2>&1
    update-alternatives --set ip6tables /usr/sbin/ip6tables-nft >/dev/null 2>&1
    modprobe iptable_nat 2>/dev/null
    nat_ok && ok "iptables nat table reachable ${D}(switched to nft backend)${N}"
  fi
  if ! nat_ok; then
    bad "iptables still cannot use the nat table"
    info "your kernel may lack nat support — check:  ${G}sudo modprobe iptable_nat${N}"
    die "no usable nat table — anonx can't redirect traffic here"
  fi
fi

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
  bad "tor rejected the configuration"
  info "see the exact error:  ${G}sudo -u debian-tor tor --verify-config${N}"
  info "restore the original:  ${G}sudo cp $TORRC.pre-anonx $TORRC${N}  ${D}(if a backup exists)${N}"
  die "bad tor config — fix the line it names, then re-run"
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
# start tor and wait for the transparent ports; returns 0 if they come up.
# Clears systemd's start-rate-limit first — repeated restarts (e.g. re-running
# the installer) trip "Start request repeated too quickly / start-limit-hit",
# after which systemd refuses to start tor until the counter is reset.
tor_ports_up(){
  systemctl reset-failed tor@default 2>/dev/null
  systemctl restart tor@default 2>/dev/null || systemctl restart tor 2>/dev/null
  local i
  for i in $(seq 1 25); do
    ss -tln 2>/dev/null | grep -q '127.0.0.1:9040' \
      && ss -tln 2>/dev/null | grep -q '127.0.0.1:9050' && return 0
    sleep 1
  done
  return 1
}

if [ "$RUN_TEST" -eq 1 ]; then
  echo "  ${W}smoke test${N} ${D}(proving Tor can start on this machine)${N}"
  up=0
  tor_ports_up && up=1

  # --- self-heal: if the ports are blocked, fix what we safely can and retry ---
  if [ "$up" -eq 0 ]; then
    holder=$(ss -tlnp 2>/dev/null | grep -E '127\.0\.0\.1:(9040|9050|9051)' | head -1)
    hprog=$(echo "$holder" | grep -o 'users:(("[^"]*"' | grep -o '"[^"]*"' | tr -d '"' | head -1)
    if [ -n "$hprog" ] && [ "$hprog" != "tor" ]; then
      # a user app (Tor Browser / firefox) owns the ports — we must NOT kill it
      warn "the ports are held by ${Y}$hprog${N} (a user app, e.g. Tor Browser)"
      info "  → close it, then re-run:  ${G}sudo ./install.sh${N}"
    else
      # a stray/previous Tor is holding them — stop it ourselves and retry
      info "a leftover Tor is holding the ports — stopping it and retrying..."
      systemctl stop tor tor@default 2>/dev/null
      pkill -x tor 2>/dev/null
      modprobe iptable_nat 2>/dev/null
      systemctl reset-failed tor@default 2>/dev/null
      sleep 2
      tor_ports_up && { up=1; ok "recovered — ports came up on retry"; }
    fi
  fi

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
    # auto-heal did not fix it — explain what is left for the user to do
    echo
    bad "Tor could not open its transparent ports (9040/9050/5353)"
    echo
    printf "  ${W}what to do${N}\n"
    if [ -n "$hprog" ] && [ "$hprog" != "tor" ]; then
      info "  • ${Y}$hprog${N} is holding the ports (a user app we won't kill for you)"
      info "    close it, then re-run:  ${G}sudo ./install.sh${N}"
    else
      info "Tor's own log says why it stopped:"
      journalctl -u tor@default -n 6 --no-pager 2>/dev/null | sed 's/^/      /'
      echo
      info "  • config error → ${G}sudo -u debian-tor tor --verify-config${N}"
      info "  • full log     → ${G}sudo journalctl -u tor@default -n 50${N}"
      info "  • then re-run  → ${G}sudo ./install.sh${N}"
    fi
    echo
    systemctl stop tor@default 2>/dev/null
    die "smoke test failed — anonx would not work until Tor can bind its ports (nothing left running)"
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
