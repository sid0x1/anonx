# anonx — make a bare `tor` behave like a normal `tor` again
# ---------------------------------------------------------------------------
# /etc/tor/torrc pins SocksPort 9050, TransPort 9040, DNSPort 5353 and
# ControlPort 9051 — the exact ports the tor@default service already holds. So
# typing `tor` died with:
#     [warn] Could not bind to 127.0.0.1:9050: Address already in use
#     [err]  Reading config failed--see warnings above.
# Nothing is broken there, it is just a second Tor fighting the running one.
#
# This wrapper keeps stock behaviour: if the ports are free it runs the real
# `tor` untouched. If the service holds them, it still runs the REAL tor binary
# in the foreground with its own DataDirectory and a free SocksPort, so you get
# the genuine Tor log output (Bootstrapped 0% ... 100%) instead of an error.
# Any argument is passed straight through, so `tor --version`, `tor -f file`,
# `tor --list-torrc-options` etc. behave exactly as before.

tor() {
  if [ $# -gt 0 ]; then command tor "$@"; return $?; fi

  # ports free -> plain stock behaviour
  if ! ss -tln 2>/dev/null | grep -qE '127\.0\.0\.1:(9050|9040|9051)'; then
    command tor
    return $?
  fi

  # first free SOCKS port (9150 is usually Tor Browser's own tor)
  local p port=""
  for p in 9150 9250 9350 9450 9550 9650 9750; do
    ss -tln 2>/dev/null | grep -q "127\.0\.0\.1:$p\b" || { port=$p; break; }
  done
  [ -z "$port" ] && port=9950

  local d="${HOME:-/root}/.tor-cli"
  mkdir -p "$d" 2>/dev/null && chmod 700 "$d" 2>/dev/null
  printf '\033[2m# system Tor (tor@default) holds 9050/9040/9051 — running your own instance on SocksPort %s, data in %s\033[0m\n' "$port" "$d"
  command tor \
    --DataDirectory "$d" \
    --SocksPort "$port" \
    --CookieAuthFileGroupReadable 0 \
    --ControlPort 0 --DNSPort 0 --TransPort 0 \
    --CookieAuthentication 0 \
    --RunAsDaemon 0 \
    --Log "notice stdout"
}
