#!/bin/bash
# vpn-guard.sh — keep one split-tunnel profile in its desired state.
#
# Usage: vpn-guard.sh <profile-file>
#
# Designed to run every ~20s from a LaunchAgent. It re-asserts the desired
# routing and exits silently when there is nothing to do, so the log stays
# readable instead of filling up with repetition.
#
# Order matters here. The server pin is maintained whether or not the VPN is
# up, because its whole purpose is to let the client connect in the first
# place — checking "is the VPN connected?" first and giving up would withhold
# the fix exactly when it is needed. Per-destination routing is the opposite:
# it needs a live tunnel interface to point at.

set -u
PROFILE="${1:-}"
if [ -z "$PROFILE" ] || [ ! -r "$PROFILE" ]; then
  echo "usage: $(basename "$0") <profile-file>" >&2
  exit 2
fi

NAME=""; VPN_SERVER=""; VPN_SERVER_PORT=""; MATCH=""; DESTS=""; KILL_DEFAULT=0
UNDERLAY_IFACES="en0 en1 en2 en3 en4 en5 en6 en7"
# shellcheck disable=SC1090
. "$PROFILE"
[ -z "$NAME" ] && { echo "profile has no NAME" >&2; exit 2; }

STATE="/tmp/vpn-split-$NAME.state"
log() { echo "$(date '+%H:%M:%S') $*"; }
VIF=""; UIF=""

# ---------- helpers ----------

svc_ids() {
  scutil --nc list 2>/dev/null | grep -F "($1)" \
    | grep -oE '[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}'
}

svc_addr() {
  scutil <<EOF 2>/dev/null | awk '/^[[:space:]]*Addresses[[:space:]]*:/{a=1;next} a&&/:/{print $3;exit}'
show State:/Network/Service/$1/IPv4
EOF
}

# Ask the kernel which interface owns an address rather than trusting the
# InterfaceName field in the dynamic store. That field can go stale: a client
# may report ppp0 while its address actually lives on ppp1, and acting on the
# wrong interface would push routes into somebody else's tunnel.
iface_of_addr() {
  [ -z "${1:-}" ] && return 1
  local i
  for i in $(ifconfig -l | tr ' ' '\n'); do
    if ifconfig "$i" 2>/dev/null | awk -v a="$1" '/inet /{if($2==a) f=1} END{exit !f}'; then
      echo "$i"; return 0
    fi
  done
  return 1
}

# One destination can accumulate several routes at once: an ordinary one, an
# interface-scoped one, and cached clones another interface created. `route
# delete` removes a single entry per call and whichever is left keeps winning,
# so repeat until none remains. Scoped entries only match with -ifscope.
purge_route() {   # $1 = -host|-net   $2 = destination
  local i
  for i in 1 2 3 4 5; do
    sudo route -n delete "$1" "$2" >/dev/null 2>&1 || break
  done
  for i in $UIF $VIF; do
    [ -n "$i" ] && sudo route -n delete "$1" "$2" -ifscope "$i" >/dev/null 2>&1
  done
  return 0
}

# ---------- the underlay ----------
GW=""
for i in $UNDERLAY_IFACES; do
  g=$(ipconfig getoption "$i" router 2>/dev/null)
  [ -n "$g" ] && [ "$g" != "0.0.0.0" ] && { GW=$g; UIF=$i; break; }
done
[ -z "$GW" ] && { log "[$NAME] no underlay gateway found"; exit 1; }

# The underlay's own local address matters too. When DHCP changes it, pinned
# routes go stale: `route -n get` still prints the right gateway and
# interface, yet nothing reaches the destination. The telltale sign is
# `traceroute: bind: Can't assign requested address`. Comparing gateways alone
# cannot catch that, so the local address is part of the recorded state.
LIP=$(ifconfig "$UIF" 2>/dev/null | awk '/inet /{print $2; exit}')
changed=""

# ---------- 1) the VPN's own server, connected or not ----------
# Corporate gateways often sit on a private address only the local ISP path
# can route. If another VPN owns the default route, the handshake disappears
# into that tunnel and the client reports a generic failure.
if [ -n "$VPN_SERVER" ]; then
  sgw=$(route -n get "$VPN_SERVER" 2>/dev/null | awk '/gateway:/{print $2}')
  if [ "$sgw" != "$GW" ]; then
    purge_route -host "$VPN_SERVER"
    sudo route -n add -host "$VPN_SERVER" "$GW" >/dev/null 2>&1 \
      && changed="$changed server->$GW"
  fi
fi

# ---------- 2) locate the VPN interface ----------
# MATCH takes one of three forms, most reliable first:
#   service:<provider-id>  resolve through the system VPN service (preferred)
#   subnet:<prefix>        e.g. subnet:10.8.   when the service is not visible
#   iface:<name>           when you already know and it is stable
case "$MATCH" in
  service:*)
    key="${MATCH#service:}"
    # Services in `scutil --nc list` are keyed by UUID, but some clients
    # register a fixed key of their own in the dynamic store instead and never
    # appear in that list at all. Try the UUIDs first, then the literal key.
    for id in $(svc_ids "$key") "$key"; do
      a=$(svc_addr "$id"); [ -z "$a" ] && continue
      VIF=$(iface_of_addr "$a") && [ -n "$VIF" ] && break
      VIF=""
    done
    ;;
  subnet:*)
    pfx="${MATCH#subnet:}"
    for i in $(ifconfig -l | tr ' ' '\n' | grep -E '^(utun|ppp|ipsec)[0-9]+$'); do
      ifconfig "$i" 2>/dev/null | awk '/inet /{print $2}' | grep -q "^$pfx" && { VIF="$i"; break; }
    done
    ;;
  iface:*)
    i="${MATCH#iface:}"
    ifconfig "$i" 2>/dev/null | grep -q 'inet ' && VIF="$i"
    ;;
  *)
    echo "invalid MATCH: $MATCH (expected service:/subnet:/iface:)" >&2; exit 2;;
esac

# Not connected is the normal resting state, not an error worth logging every
# 20 seconds. The server pin above has already been handled, which is what
# makes connecting possible at all.
if [ -z "$VIF" ]; then
  [ -n "$changed" ] && log "[$NAME] underlay $UIF/$GW |$changed"
  [ -t 1 ] && echo "$NAME is not connected"
  exit 1
fi

# ---------- 3) does the per-destination routing need work? ----------
want="$VIF $GW $UIF $LIP"
have=$(cat "$STATE" 2>/dev/null || true)
need=0
[ "$have" != "$want" ] && need=1

if [ $need -eq 0 ] && [ -n "$DESTS" ]; then
  for d in $DESTS; do
    got=$(route -n get "${d%%/*}" 2>/dev/null | awk '/interface:/{print $2}')
    [ "$got" != "$VIF" ] && { need=1; break; }
  done
fi

if [ $need -eq 0 ] && [ "$KILL_DEFAULT" = "1" ]; then
  netstat -rn -f inet | awk '$1=="0.0.0.0/1"||$1=="128.0.0.0/1"{f=1} END{exit !f}' && need=1
fi

if [ $need -eq 0 ]; then
  [ -n "$changed" ] && log "[$NAME] underlay $UIF/$GW |$changed"
  exit 0
fi

# ---------- 4) re-assert the tunnel routing ----------

# Full-tunnel clients install 0.0.0.0/1 and 128.0.0.0/1, which together
# outrank the default route and capture everything, and they reinstall them on
# every reconnect. Removing both turns a full tunnel into a split one.
if [ "$KILL_DEFAULT" = "1" ]; then
  for n in 0.0.0.0/1 128.0.0.0/1; do
    sudo route -n delete -net "$n" >/dev/null 2>&1 \
      || sudo route -n delete -net "$n" -interface "$VIF" >/dev/null 2>&1
  done
  # Cached per-host clones already pointing at the tunnel would keep sending
  # traffic there. Drop them; the kernel recreates them on the correct path.
  netstat -rn -f inet \
    | awk -v k="$VIF" '$NF==k && $3 ~ /W/ && $1 ~ /^[0-9]+(\.[0-9]+){3}$/ {print $1}' \
    | while read -r h; do sudo route -n delete -host "$h" >/dev/null 2>&1; done
  changed="$changed default-released"
fi

for d in $DESTS; do
  case "$d" in
    */*) purge_route -net "$d"
         sudo route -n add -net "$d" -interface "$VIF" >/dev/null 2>&1 \
           && changed="$changed $d";;
    *)   purge_route -host "$d"
         sudo route -n add -host "$d" -interface "$VIF" >/dev/null 2>&1 \
           && changed="$changed $d";;
  esac
done

printf '%s\n' "$want" > "$STATE"
log "[$NAME] $VIF | underlay $UIF/$GW (local $LIP) |$changed"
