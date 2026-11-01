#!/bin/bash
# vpn-discover.sh — show every VPN service on this Mac and the interface it
# actually uses right now. Read-only; changes nothing.
#
# Interface names alone tell you nothing on macOS: several clients create utun
# devices and the numbering shifts between connections. The dynamic store's
# InterfaceName field is not trustworthy either — it can report an interface a
# client no longer uses. What does hold is the address: take the IPv4 address
# macOS assigned to a service, then ask the kernel which interface owns it.

set -u

svc_addr() {
  scutil <<EOF 2>/dev/null | awk '/^[[:space:]]*Addresses[[:space:]]*:/{a=1;next} a&&/:/{print $3;exit}'
show State:/Network/Service/$1/IPv4
EOF
}

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

echo "=== Configured VPN services ==="
printf '  %-38s %-34s %-16s %s\n' "SERVICE ID" "PROVIDER" "NAME" "STATE / INTERFACE"
scutil --nc list 2>/dev/null | while read -r line; do
  id=$(printf '%s' "$line" | grep -oE '[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}')
  [ -z "$id" ] && continue
  state=$(printf '%s' "$line" | grep -oE '\((Connected|Disconnected|Connecting|Disconnecting)\)' | tr -d '()')
  kind=$(printf '%s' "$line" | grep -oE '\(([A-Za-z0-9._-]+\.[A-Za-z0-9._-]+)\)' | tr -d '()' | head -1)
  [ -z "$kind" ] && kind=$(printf '%s' "$line" | grep -oE 'PPP --> [A-Za-z0-9]+' | sed 's/PPP --> /PPP:/')
  name=$(printf '%s' "$line" | sed -n 's/.*"\(.*\)".*/\1/p')
  addr=$(svc_addr "$id")
  iface=$(iface_of_addr "$addr" || true)
  extra="${state:-?}"
  [ -n "$addr" ] && extra="$extra  -> $iface ($addr)"
  printf '  %-38s %-34s %-16s %s\n' "$id" "${kind:-?}" "${name:--}" "$extra"
done

echo
echo "=== Non-UUID service keys (some clients register their own) ==="
scutil <<'EOF' 2>/dev/null | awk -F/ '/subKey/{print $4}' | grep -vE '^[0-9A-Fa-f]{8}-' | while read -r k; do
list State:/Network/Service/.*/IPv4
EOF
  a=$(svc_addr "$k"); i=$(iface_of_addr "$a" || true)
  printf '  %-34s %-16s -> %s\n' "$k" "${a:--}" "${i:--}"
done

echo
echo "=== Active tunnel interfaces ==="
for i in $(ifconfig -l | tr ' ' '\n' | grep -E '^(utun|ppp|ipsec)[0-9]+$'); do
  ip=$(ifconfig "$i" 2>/dev/null | awk '/inet /{print $2; exit}')
  [ -n "$ip" ] && printf '  %-8s %s\n' "$i" "$ip"
done

echo
echo "=== Default routes (who currently owns the internet) ==="
netstat -rn -f inet | awk '$1=="default"{printf "  %-22s %s\n", $2, $NF}'
netstat -rn -f inet | awk '$1=="0.0.0.0/1"||$1=="128.0.0.0/1"{
  printf "  %-22s %s   <- full-tunnel VPN\n", $1, $NF}'

echo
echo "=== Underlay (physical) gateways ==="
for i in en0 en1 en2 en3 en4 en5 en6 en7; do
  g=$(ipconfig getoption "$i" router 2>/dev/null)
  [ -n "$g" ] && [ "$g" != "0.0.0.0" ] && {
    lip=$(ifconfig "$i" 2>/dev/null | awk '/inet /{print $2; exit}')
    printf '  %-6s gateway %-18s local %s\n' "$i" "$g" "${lip:--}"
  }
done
