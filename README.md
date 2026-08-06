# anonx

A transparent Tor gateway for Debian/Kali in a single shell script.

`anonx start` pushes **every TCP connection and every DNS query on the machine**
through Tor, randomizes your MAC, blocks IPv6, and rotates the exit IP on a timer.
No `proxychains` prefix, no per-app SOCKS settings — curl, apt, your browser, a
Python script, all of it goes through Tor because the kernel puts it there.

```
   ANONYMOUS   everything on this machine leaves through Tor
────────────────────────────────────────────────────────
  ✔  Tor         running · fully connected to the Tor network
  ✔  Firewall    locked · anything not going through Tor is blocked
  ✔  Public IP   185.220.101.178 · a Tor exit node, not you
  ✔  MAC eth0    ea:52:86:8f:c8:eb fake (real aa:bb:cc:dd:ee:ff)
                 · your internet goes out through this link
  ✔  IPv6        blocked · Tor is IPv4-only, so v6 would expose you
  ✔  DNS         inside Tor · your ISP cannot see the sites you look up
  ✔  New IP      automatic · every 30s
────────────────────────────────────────────────────────
```

## What it actually does

| Layer | Action |
|---|---|
| TCP | `nat OUTPUT` redirects every SYN to Tor's `TransPort` (9040) |
| DNS | port 53 (udp+tcp) is redirected to Tor's `DNSPort` (5353); `resolv.conf` is pinned to `127.0.0.1` and made immutable so NetworkManager can't rewrite it |
| Kill switch | the last `filter OUTPUT` rule is `REJECT` — if Tor dies, traffic stops instead of leaking |
| IPv6 | dropped entirely (Tor's transparent proxy is IPv4-only, so v6 is a pure leak vector) |
| MAC | randomized through NetworkManager's `cloned-mac-address`, which survives reconnects (a plain `macchanger` spoof gets reverted by NM) |
| Exit IP | `SIGNAL NEWNYM` on the control port every *N* seconds, interval configurable |
| LAN | DHCP, the gateway and RFC1918 ranges stay reachable, so the link keeps its lease |

## Install

**From the apt repository** (once it is published):

```bash
echo "deb [trusted=yes] https://<user>.github.io/anonx ./" | sudo tee /etc/apt/sources.list.d/anonx.list
sudo apt update && sudo apt install anonx
```

**From a downloaded package:**

```bash
sudo apt install ./anonx_1.0_all.deb
```

**From source:**

```bash
git clone https://github.com/<user>/anonx.git
cd anonx
sudo ./install.sh
```

All three do the same work: pull the dependencies (`tor`, `macchanger`,
`ethtool`, `iptables`, `curl`, `xxd`, `iproute2`), append the transparent-proxy
block to `/etc/tor/torrc` (keeping a `.pre-anonx` backup), stop Tor from starting
on its own — anonx owns its lifecycle — and install the `tor` shell helper.

Remove it with `sudo apt purge anonx` or `sudo ./uninstall.sh --purge`. Both
restore your network first, so you can never uninstall yourself into a locked
firewall.

## Updating

```bash
sudo anonx update
```

Package installs go through apt. Source installs download the latest script,
verify it parses before replacing anything, and keep the previous copy in
`/var/lib/anonx/anonx.prev`. Point it somewhere else with
`echo 'UPDATE_URL=https://.../anonx' | sudo tee /etc/anonx.conf`.

## Building the package

```bash
./packaging/build-deb.sh        # -> packaging/dist/anonx_1.0_all.deb
./packaging/build-apt-repo.sh   # -> packaging/repo/  (publish with GitHub Pages)
```

## Usage

```bash
sudo anonx start          # go anonymous
sudo anonx start 30s      # ...and rotate the exit IP every 30 seconds
sudo anonx status         # live status, in plain words
sudo anonx ip             # new exit IP right now
sudo anonx mac            # new MAC right now (rebuilds Tor circuits after)
sudo anonx interval 2m    # change the rotation interval (saved for next time)
sudo anonx doctor         # layer-by-layer diagnosis when something is off
sudo anonx repair         # force-restore a half-broken state
sudo anonx stop           # back to your real identity, Tor service stopped
sudo anonx enable         # start automatically on boot   (disable = remove)
sudo anonx update         # fetch the latest version
anonx --help              # full help    (anonx version = version banner)
```

Interval accepts `10s`, `90s`, `2m`, `1h` or a plain number of seconds. The
minimum is 10s because Tor rate-limits `NEWNYM` below that.

`anonx` re-executes itself through `sudo` if you forget it. That matters: every
check it makes (iptables rules, the Tor control cookie, the permanent MAC) is
root-only, and as a normal user they all fail silently — you'd get a status
screen full of red crosses while everything was actually fine.

## Verifying it works

```bash
curl https://check.torproject.org/api/ip     # {"IsTor":true,"IP":"..."}
curl -6 https://ipv6.google.com              # must fail — v6 is blocked
dig +short whoami.akamai.net @ns1-1.akamaitech.net   # a Tor exit, not your ISP
```

The status screen shows the same three facts, plus your spoofed MAC and the
rotation state.

## Design notes

Two failure modes drove most of the code, both of which look identical from the
desk — *"the network is connected but nothing loads"*:

**Changing the MAC tears down Tor.** A MAC change bounces the link, every TCP
connection Tor holds dies with it, and Tor does not always rebuild its guard
connections on its own. If the firewall is already forcing all traffic into Tor
at that moment, the machine goes completely dark. So `start` randomizes the MAC
*first*, waits for the gateway to answer, and only then starts Tor; `anonx mac`
restarts Tor after the bounce and unlocks the firewall if Tor doesn't come back.

**`Bootstrapped 100%` is not the same as "the ports are open".** Tor's
`TransPort` accepts connections the instant the daemon starts, long before it has
a single circuit. Locking the firewall at that point produces a perfect blackout.
`anonx` polls `GETINFO status/bootstrap-phase` on the control port, then fetches a
real URL through SOCKS, and only locks after both succeed. After locking, it
fetches once more through the transparent path and **rolls the whole thing back**
if that fails — a failed `start` always leaves you with a working network.

The rotation daemon also watches itself: two dead cycles in a row and it restarts
Tor rather than leaving you offline.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "connected" but nothing loads | `sudo anonx doctor` — it tells you which layer died |
| status shows everything off/red but anonx is running | you ran it without `sudo` on an older build; re-install |
| DNS dead after a crash or reboot | `sudo anonx repair` (an interrupted run can leave `resolv.conf` immutable at `127.0.0.1`) |
| `tor` in the terminal prints "Address already in use" | that's the running service holding 9050/9040/9051; install the shell helper, or use `sudo anonx status` |
| Wi-Fi won't reconnect after a MAC change | `sudo anonx repair` resets `cloned-mac-address` back to `permanent` on every profile |

## Limitations

* ICMP can't travel over Tor — `ping 8.8.8.8` will fail while locked. That's the
  design, not a bug; the gateway still pings.
* UDP (except DNS, which is translated) is dropped. Video calls, WireGuard, most
  games won't work while locked.
* Tor hides your IP, not your habits. Logging into your own accounts, browser
  fingerprinting and timing correlation all still identify you. For serious
  browsing use the Tor Browser (it runs its own Tor on 9150 and is unaffected by
  anonx).
* MAC randomization only hides you from the local network segment.
* Tested on Kali (NetworkManager + `tor@default`). Other Debian derivatives should
  work; non-NM setups fall back to `macchanger`.

## Legal

For your own machines, lab networks and authorized testing only. Circumventing
network controls you don't own is illegal in most places, and Tor is not a
license to do it. You are responsible for what you send through it.

## License

MIT — see [LICENSE](LICENSE).
