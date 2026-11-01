# macOS VPN split tunneling

Send only the hosts that need a VPN through it, and keep everything else on
its normal path — then make that survive reconnects, sleep, DHCP changes and
reboots.

Ships as a [Claude Code](https://claude.com/claude-code) skill, but the three
shell scripts are standalone and work on their own.

## Why this exists

A corporate VPN that captures all traffic is a bad default. It routes personal
browsing through someone else's network, breaks any other tunnel you depend
on, and slows down everything unrelated to work. Usually you need it for one
intranet host.

macOS can express that with ordinary routes. The reason this is a repository
and not a one-line `route add` is that three things get in the way:

**Identifying the VPN's interface is not obvious.** Several clients create
`utun` devices and the numbers shift between connections. The dynamic store
has an `InterfaceName` field, but it goes stale — a client can report `ppp0`
while its address actually lives on `ppp1`. Acting on that would push routes
into a different VPN's tunnel. What holds is the address: take the IPv4
address macOS assigned to the service, then ask the kernel which interface
owns it.

**Full-tunnel clients fight back.** They install `0.0.0.0/1` and
`128.0.0.0/1`, which together outrank the default route and capture
everything, and they reinstall them on every reconnect. A manual fix lasts
minutes.

**The VPN's own server often needs the opposite treatment.** Corporate
gateways frequently sit on a private address reachable only through your ISP
path. If another VPN owns the default route, the handshake vanishes into that
tunnel and the client reports a generic connection error that says nothing
about the real cause.

## What's here

```
SKILL.md                      instructions for Claude Code
scripts/vpn-discover.sh       read-only: every VPN service and its real interface
scripts/vpn-guard.sh          enforces one profile; run from a LaunchAgent
scripts/vpn-status.sh         where each destination actually goes
references/troubleshooting.md the three failure modes and how to tell them apart
examples/                     profile and LaunchAgent templates
```

## Quick start

```bash
git clone https://github.com/AzalHoseinian/macos-vpn-split-tunnel.git
cd macos-vpn-split-tunnel
chmod +x scripts/*.sh
```

Connect the VPN, then see what you have:

```bash
./scripts/vpn-discover.sh
```

```
=== Configured VPN services ===
  SERVICE ID                             PROVIDER                  NAME     STATE / INTERFACE
  00000000-1111-2222-3333-444444444444   com.example.vpnclient     work     Connected  -> utun4 (10.8.0.6)

=== Default routes (who currently owns the internet) ===
  0.0.0.0/1              utun4   <- full-tunnel VPN
```

Write a profile at `~/.config/vpn-split/work.conf` (see
`examples/work.conf.example`):

```sh
NAME="work"
MATCH="service:com.example.vpnclient"
VPN_SERVER="203.0.113.10"
DESTS="10.20.0.0/16 198.51.100.7"
KILL_DEFAULT=1
```

Apply it:

```bash
./scripts/vpn-guard.sh ~/.config/vpn-split/work.conf
```

Verify — and do not trust the routing table alone:

```bash
./scripts/vpn-status.sh
```

The line that matters is the public egress IP. If it is unchanged from before
the VPN came up, your general traffic is not entering the tunnel.

## Making it stick

Routes do not survive reconnects. Copy
`examples/local.vpn-split.plist.example` to
`~/Library/LaunchAgents/local.vpn-split-work.plist`, fill in the two
placeholders, and load it:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.vpn-split-work.plist
```

The guard re-asserts the profile every 20 seconds and exits silently when
nothing needs doing, so `/tmp/vpn-split-work.log` stays readable — each line
is a real repair.

Worth testing that it works rather than assuming: delete one of the routes and
watch it come back.

```bash
sudo route -n delete -host 198.51.100.7
# wait ~20s
./scripts/vpn-status.sh
```

### The sudo trade-off

`route` needs root and a LaunchAgent has no terminal to type a password into,
so unattended operation needs a narrow sudoers rule:

```bash
sudo visudo -f /etc/sudoers.d/vpn-split
```

```
yourname ALL=(root) NOPASSWD: /sbin/route
```

Be clear-eyed about this: it lets anything running as you modify the routing
table without a password, which means a compromised process could redirect
your traffic. It is not general root access and it is far narrower than
`NOPASSWD: ALL`, but it is a real widening of your exposure. Without it the
scripts still work — you just run them by hand and lose automatic repair.

Use `visudo` rather than writing the file directly; a syntax error in
`/etc/sudoers.d/` can lock you out of `sudo` entirely.

## When a VPN won't connect

Clients report the same generic error for unrelated causes, so the message is
not evidence. [`references/troubleshooting.md`](references/troubleshooting.md)
covers the three failure modes that account for nearly everything, and the
checks that tell them apart:

1. **The server is hidden behind another VPN.** `route -n get <server>` points
   at the wrong interface. Fix: pin it to the underlay.
2. **A stale route after the local IP changed.** Everything *looks* right —
   correct gateway, correct interface — and nothing works. The tell is
   `traceroute: bind: Can't assign requested address`. Fix: delete and re-add.
   Comparing gateways cannot detect this, which is why the guard records the
   underlay's local address too.
3. **The client's engine is dead and only its window is left.** No new lines in
   its log after the failure. Fix: quit and reopen the app; `launchctl
   bootstrap` if its daemons are unregistered.

It also lists the traps that waste the most time: empty logs read as healthy,
`pgrep -f` matching your own command, a terminal stuck at a password prompt
swallowing everything you send next.

## Use as a Claude Code skill

```bash
git clone https://github.com/AzalHoseinian/macos-vpn-split-tunnel.git \
  ~/.claude/skills/vpn-split
```

Then ask in plain language — "make this VPN only carry the 10.20 subnet", or
"my VPN won't connect while the other one is on" — and Claude will run the
discovery, write the profile, install the watchdog, and verify it end to end.

## Scope

Routing decides what enters the tunnel, so traffic that never enters it cannot
be logged by the VPN's gateway. That is a real property and the egress-IP check
demonstrates it.

It does not follow that the client is inert. Many ship system extensions —
content filters, proxies, packet filters — that run regardless of whether the
tunnel is up:

```bash
systemextensionsctl list
```

If your concern is privacy rather than convenience, quitting the client when
you don't need it is the honest answer. This tool manages routes; it does not
make a VPN client stop being a VPN client.

Tested on macOS 15 and 26 with IPsec, SSL-VPN (ppp) and L2TP clients.
IPv4 only.

## License

MIT
