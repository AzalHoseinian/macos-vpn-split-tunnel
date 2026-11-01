---
name: vpn-split
description: Set up and repair per-destination VPN routing (split tunneling) on macOS — send only chosen hosts or subnets through a VPN while everything else keeps its normal path, and keep it that way across reconnects and reboots. Use this whenever someone wants a VPN to carry only certain traffic, wants to stop a VPN from capturing all their internet, needs two or more VPNs to coexist, or hits a VPN that "won't connect" or fails with a generic error while another VPN or tunnel is active. Also use it to diagnose macOS VPN connection failures in general, since the usual causes (a server hidden behind another tunnel, a stale route after the IP changed, a dead client daemon) all look identical from the error message.
---

# Split-tunnel VPN routing on macOS

A VPN that captures all traffic is often the wrong default: it sends personal
browsing through a corporate network, breaks other tunnels, and slows
everything that has nothing to do with work. The fix is per-destination
routing — only the hosts that need the VPN go through it.

macOS can express this with ordinary routes, but three things make it harder
than it looks, and they are the reason this skill exists rather than a
one-line `route add`:

1. **Identifying the VPN's interface is not obvious.** Several clients create
   `utun` devices and the numbers move between connections.
2. **VPN clients fight back.** Full-tunnel clients re-install their
   catch-all routes on every reconnect, so a manual fix lasts minutes.
3. **The VPN's own server often needs the opposite treatment** — it must stay
   reachable over the physical path, or the client cannot connect at all.

## Before changing anything

Read the client's own log first. Some gateways already enforce split
tunneling server-side; a line like `split tunnel is specified` followed by a
destination list means the routing work is already done and adding routes on
top will only cause confusion. In that case the profile needs `VPN_SERVER`
and nothing else.

Then run the discovery script, which changes nothing:

```bash
scripts/vpn-discover.sh
```

It prints every VPN service with the interface it currently owns, the active
tunnel interfaces, who holds the default route, and the underlay gateways.
Work from this output rather than assumptions — ask the person to connect the
VPN first if it is not up, because an interface that does not exist yet cannot
be identified.

## What to ask

Keep this short; most of it is usually already clear from context.

- **Which VPN**, and what should go through it — hosts, subnets, or a service
  they name (resolve names to addresses, since routes are numeric).
- **What should NOT go through it.** Usually "everything else", which is the
  default.
- **Is the VPN's server on a private address?** If `scutil`/the client config
  shows something like `10.x` or `192.168.x`, it will need pinning. This is
  the single most common cause of "it won't connect when my other VPN is on".
- **Is this client full-tunnel?** If `vpn-discover.sh` shows `0.0.0.0/1` and
  `128.0.0.0/1` on its interface, yes — set `KILL_DEFAULT=1`.

## Writing the profile

One file per VPN in `~/.config/vpn-split/<name>.conf`:

```sh
NAME="work"                              # also names the log and state files
MATCH="service:com.example.vpnclient"    # how to find the interface
VPN_SERVER="203.0.113.10"                # optional; pinned to the underlay
DESTS="10.20.0.0/16 198.51.100.7"        # only these go through the VPN
KILL_DEFAULT=0                           # 1 for full-tunnel clients
```

`MATCH` has three forms, and preferring the most reliable one that works
matters more than it may seem — a wrong match means pushing routes into some
other VPN's tunnel:

| Form | When to use |
|---|---|
| `service:<provider-id>` | Preferred. Take the provider id from `vpn-discover.sh`. Resolves through the system VPN service, so it survives interface renumbering. |
| `subnet:<prefix>` | When the client registers no visible service. Use the prefix the VPN hands its clients, e.g. `subnet:10.8.` |
| `iface:<name>` | Only when the name is known to be stable. Fragile. |

`DESTS` accepts hosts (`198.51.100.7`) and CIDR subnets (`10.20.0.0/16`),
space-separated.

## Installing the watchdog

Routes do not survive reconnects, sleep, or DHCP changes, so a periodic check
is what makes this stick. The guard re-asserts the profile and exits silently
when nothing needs doing.

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.vpn-split-<name>.plist
```

The plist runs `scripts/vpn-guard.sh <profile>` with `StartInterval` of 20 and
`RunAtLoad`, logging to `/tmp/vpn-split-<name>.log`. Put the scripts somewhere
stable (`~/bin` or `/usr/local/bin`) rather than pointing launchd at a skill
directory that may move.

### The sudo question

`route` needs root, and a LaunchAgent has no terminal to type a password into.
A narrowly scoped sudoers rule is what makes unattended operation possible:

```
<username> ALL=(root) NOPASSWD: /sbin/route
```

Be straight with the person about the trade-off rather than installing this
quietly: it allows passwordless modification of the routing table by anything
running as them. That is a real widening of what a compromised process could
do — it could redirect their traffic. It does not grant general root access,
and it is far narrower than `NOPASSWD: ALL`. If they would rather not, the
scripts still work when run by hand; they just lose the automatic repair.

Install it with `visudo -f /etc/sudoers.d/vpn-split` so a syntax error cannot
lock them out of sudo.

## Verifying

Never declare this working from the routing table alone:

```bash
scripts/vpn-status.sh
```

Then confirm end to end — reach something that should go through the VPN, and
check that the public egress IP is *unchanged* from before the VPN came up.
That second check is what proves general traffic is not entering the tunnel.
If the person has a specific service in mind, test that service, not a proxy
for it.

A useful final test is to break it deliberately: delete one of the routes and
confirm the watchdog restores it within its interval. A watchdog nobody has
seen working is an assumption.

## When something fails

VPN clients report the same generic error for unrelated causes, so the message
is not evidence. **Read `references/troubleshooting.md`** — it covers the three
failure modes that account for nearly everything:

1. The VPN server is hidden behind another VPN (routing).
2. A stale route after the local IP changed — looks correct, does not work.
3. The client's engine is dead and only its window remains.

It also lists the checks that separate them, and several traps that waste time
otherwise (empty logs, `pgrep -f` false positives, a terminal stuck at a
password prompt, `launchctl bootstrap` vs `kickstart`).

Work through that classification before trying fixes. Repeatedly restarting
things in the hope that one sticks is how an afternoon disappears.

## A note on what this does and does not protect

Routing decides what enters the tunnel, so traffic that never enters it cannot
be logged by the VPN's gateway. That is a real and verifiable property — the
egress IP check demonstrates it.

It does not follow that the VPN client is inert. Many ship system extensions
(content filters, proxies, packet filters) that operate regardless of whether
the tunnel is up. If someone's actual concern is privacy rather than
convenience, say plainly what routing does and does not cover, show them
`systemextensionsctl list`, and let them decide. Quitting the client entirely
is the honest answer when the tunnel is not needed.
