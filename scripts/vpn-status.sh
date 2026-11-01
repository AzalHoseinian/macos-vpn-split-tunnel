#!/bin/bash
# vpn-status.sh — for every profile, show which interface each destination
# actually resolves to. This is the check that answers "is my split tunnel
# really doing what I think it is?"
#
# Reads ~/.config/vpn-split/*.conf (override with VPN_SPLIT_DIR).

set -u
DIR="${VPN_SPLIT_DIR:-$HOME/.config/vpn-split}"
ifof() { route -n get "$1" 2>/dev/null | awk '/interface:/{print $2; f=1} END{if(!f) print "-"}'; }

shopt -s nullglob
profiles=("$DIR"/*.conf)
if [ ${#profiles[@]} -eq 0 ]; then
  echo "no profiles in $DIR" >&2
  exit 1
fi

for p in "${profiles[@]}"; do
  NAME=""; VPN_SERVER=""; MATCH=""; DESTS=""; KILL_DEFAULT=0
  # shellcheck disable=SC1090
  . "$p"
  echo "-- $NAME --"
  for d in $DESTS; do
    printf '  %-26s %s\n' "$d" "$(ifof "${d%%/*}")"
  done
  [ -n "$VPN_SERVER" ] && \
    printf '  %-26s %s   (server: should use the underlay)\n' "$VPN_SERVER" "$(ifof "$VPN_SERVER")"
  echo
done

echo "-- reference --"
printf '  %-26s %s\n' "8.8.8.8 (general internet)" "$(ifof 8.8.8.8)"

echo
echo "-- active tunnel interfaces --"
for i in $(ifconfig -l | tr ' ' '\n' | grep -E '^(utun|ppp|ipsec)[0-9]+$'); do
  ip=$(ifconfig "$i" 2>/dev/null | awk '/inet /{print $2; exit}')
  [ -n "$ip" ] && echo "  $i -> $ip"
done

echo
echo -n "-- public egress IP: "
curl -s --max-time 8 https://api.ipify.org || printf '(unreachable)'
echo
