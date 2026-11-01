# Diagnosing VPN failures on macOS

VPN clients almost always report the same generic thing — "Connection Error",
"the VPN connection terminates unexpectedly", some numeric code — no matter
what actually went wrong. Causes that have nothing to do with each other
produce identical messages, so the message itself is not evidence.

Rather than guessing, classify the failure first. These three checks separate
every case below:

```bash
# 1) Is the client's own engine running?
pgrep -f "^/full/path/to/the/client/daemon"

# 2) Is the VPN server reachable over the underlay?
route -n get <server-ip> | grep -E "gateway|interface"
nc -z -G 6 -w 6 <server-ip> <port>

# 3) Did the client log anything new?
tail -5 <client-log-path>
```

---

## Case 1 — the VPN server is hidden behind another VPN

**Symptom:** `route -n get <server>` shows another VPN's interface (`ppp0`,
`utun4`, …) instead of the physical one, and `nc` reports the port closed.

**Why:** corporate gateways frequently sit on a private address — `10.x`,
`192.168.x` — reachable only through the local ISP path. When a second VPN
takes the default route, the handshake packets go into that tunnel, where no
such destination exists. The client cannot distinguish this from the server
being down, so you get the generic error.

**Fix:** pin the server's own route to the underlay gateway.

```bash
sudo route -n delete -host <server>
sudo route -n add    -host <server> <underlay-gateway>
```

Do not treat this as a one-time fix. Every reconnection of the other VPN
removes it again, which is the entire reason the watchdog exists. Set
`VPN_SERVER` in the profile and let it hold.

---

## Case 2 — a stale route after the local IP changed

**The misleading part:** `route -n get <server>` shows the *correct* gateway
and the *correct* interface, ordinary internet works fine, and yet `nc` says
the port is closed.

**The decisive sign:**

```
traceroute: bind: Can't assign requested address
```

**Why:** a host route created while the interface held one address stays bound
to that address. When DHCP hands out a different one — Wi-Fi reconnect, lease
renewal, moving between networks — the route still *looks* right but can no
longer be used.

**Fix:** delete and re-add the same route. Nothing more.

Comparing gateways cannot detect this, because the gateway never changed. That
is why `vpn-guard.sh` records the underlay's local address in
`/tmp/vpn-split-<name>.state` and rebuilds the routes when it differs.

---

## Case 3 — the engine is dead and only the window is left

**Symptom:** the app window is open and responsive, but `pgrep` finds none of
its background daemons and the client log has **no new lines** after the last
disconnect. Clicking Connect never reaches anything.

**Why:** many clients ship their daemons with `KeepAlive=false` and
`RunAtLoad=false`. Once they stop, neither launchd nor a reboot brings them
back — only launching the app does.

**Fix, in order:**

```bash
osascript -e 'quit app "<App Name>"' && sleep 3 && open -a "<App Name>"
```

If that is not enough, check whether the daemon is even registered:

```bash
sudo launchctl print system/<label>
sudo launchctl bootstrap system /Library/LaunchDaemons/<file>.plist
```

Things worth knowing here:

- `kickstart` cannot start a service that is not loaded, and its error
  ("Could not find service") reads like the service is missing entirely.
  Use `bootstrap` first.
- `Bootstrap failed: 5: Input/output error` usually means **already loaded**,
  not a failure.
- A plist's `Label` often differs from its filename; read it with
  `/usr/libexec/PlistBuddy -c "Print :Label" <plist>`.
- Components under `/Library/LaunchAgents` live in the user domain and need no
  sudo: `launchctl bootstrap gui/$(id -u) <plist>`.
- `launchctl print-disabled system | grep <vendor>` shows whether something was
  deliberately disabled. Unlike `bootout`, which lasts until reboot, `disable`
  persists across reboots.

**If none of that works, the installation itself is broken.** The giveaway is
GUI processes alive while no window appears. Stop spending time on launchd:
uninstall with the vendor's own uninstaller, reboot, reinstall. Dragging the
app to the Trash is not enough — system extensions survive it:

```bash
systemextensionsctl list | grep -i <vendor>
```

---

## Traps worth remembering

**An empty log is not a healthy log.** If the client logged nothing after the
moment of failure, the request never reached it — that is Case 3, not a
network problem.

**A router that ignores `ping` is not down.** Plenty of home gateways drop
ICMP. Test reachability with `nc -z` against a port that should be open.

**Be careful with `pgrep -f`.** A loose pattern matches the very command you
are running — `sudo launchctl kickstart … com.vendor.daemon` contains the
daemon's name — and reports a false positive. Anchor on the full path:

```bash
pgrep -f "^/Library/Application Support/<Vendor>/…/<daemon>"
```

**A terminal stuck at `Password:` swallows whatever you send next** as invisible
password input. If someone says "the terminal isn't doing anything", check for
a pending `sudo` first and release it with `kill -INT <pid>`.

**Some servers already enforce split tunneling.** Read the client log before
writing any routes: a line like `split tunnel is specified` followed by a list
of destinations means the work is already done server-side, and all you need is
`VPN_SERVER`. Adding your own routes on top only creates confusion.

**Check the egress IP, not just the routing table.** `curl https://api.ipify.org`
with the VPN up is the end-to-end proof that general traffic is not entering
the tunnel. A routing table can look right while something else intercepts.
