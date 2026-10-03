#!/bin/sh
# Helper for the WireGuard bar widget (Panel.qml). Every external command the
# widget runs goes through here, always as
#
#   timeout -k 3 <deadline> sh wg-helper.sh <command> [args...]
#
# so each operation has a wall-clock deadline that covers its whole process
# group, fixed argv (nothing is ever re-tokenised by a shell), and bounded
# output: every value is validated and clipped on the producer side before the
# widget sees it. Exit 65 means an argument was rejected.
#
# Commands
#   list                      JSON array of WireGuard profiles known to
#                             NetworkManager: [{name, active, iface, host, since}]
#   stats IFACE               rx and tx byte counters of a kernel interface
#   ip                        the exit IPv4 address, or nothing
#   up NAME [OTHER...]        bring OTHERs down, then NAME up (undone on failure)
#   down NAME...              bring every NAME down
#   notify URGENCY BODY       desktop toast
#   notify-connect LEAD [IP]  connect toast that reports the exit IP and flags
#                             a mismatch with the expected gateway IP, unless
#                             the tunnel is split (internet not routed via it)
#   route                     the interface that carries traffic to the
#                             exit-IP probe (1.1.1.1), or nothing

set -u

MAX_PROFILES=32        # profiles listed and accepted as arguments
MAX_NAME_BYTES=256     # a NetworkManager connection id
MAX_HOST_BYTES=253     # a DNS name
MAX_TEXT_BYTES=300     # a toast line
MAX_LIST_BYTES=65536   # nmcli output consumed by `list`
MAX_PEERS_BYTES=8192   # nmcli output consumed per profile
MAX_HTTP_BYTES=4096    # Cloudflare trace response
NM_DOWN_WAIT=10        # seconds nmcli waits for a deactivation
NM_UP_WAIT=20          # seconds nmcli waits for an activation
GLYPH="󰖂"

clip() { printf '%s' "$1" | tr -d '\000-\037\177' | head -c "$2"; }
json_str() { clip "$1" "$2" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
bytes() { printf '%s' "$1" | wc -c; }

# A profile name: non-empty, no control characters, bounded.
valid_name() {
  [ -n "$1" ] || return 1
  [ "$(bytes "$1")" -le "$MAX_NAME_BYTES" ] || return 1
  [ "$(printf '%s' "$1" | tr -d '\000-\037\177')" = "$1" ]
}

# The kernel's dev_valid_name(): 1-15 bytes, not "." or "..", no "/", ":" or
# whitespace. Checked before the name goes anywhere near /sys/class/net.
valid_iface() {
  case "$1" in ''|.|..|*/*|*:*|*[[:space:]]*) return 1 ;; esac
  [ "$(bytes "$1")" -le 15 ]
}

# Exactly four decimal octets 0-255, no leading zeros.
valid_ipv4() {
  printf '%s' "$1" | grep -Eq '^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$'
}

# A peer endpoint host: DNS label characters, or an IPv4/IPv6 literal.
valid_host() {
  printf '%s' "$1" | grep -Eq '^[][A-Za-z0-9.:-]{1,253}$'
}

cmd_list() {
  # One nmcli call for identity and state. NAME goes last because nmcli
  # escapes ":" and "\" inside it in terse mode; the fields before it never
  # contain a colon, so the name is everything after the fifth one.
  nmcli -t -f UUID,TYPE,ACTIVE,TIMESTAMP,DEVICE,NAME connection show 2>/dev/null \
    | head -c "$MAX_LIST_BYTES" \
    | {
      n=0
      sep=''
      printf '['
      while IFS= read -r line; do
        uuid=${line%%:*}; rest=${line#*:}
        type=${rest%%:*}; rest=${rest#*:}
        [ "$type" = wireguard ] || continue
        case "$uuid" in ''|*[!0-9a-fA-F-]*) continue ;; esac
        n=$((n + 1))
        [ "$n" -le "$MAX_PROFILES" ] || break
        active=${rest%%:*}; rest=${rest#*:}
        ts=${rest%%:*}; rest=${rest#*:}
        dev=${rest%%:*}
        name=$(printf '%s' "${rest#*:}" | sed 's/\\\(.\)/\1/g')
        valid_name "$name" || continue
        [ "$active" = yes ] && active=true || active=false
        case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
        [ "$(bytes "$ts")" -le 12 ] || ts=0
        valid_iface "$dev" || dev=''
        # The first peer endpoint, host part only. nmcli escapes the ":" before
        # the port; a bracketed IPv6 literal keeps its own colons.
        host=$(nmcli -g wireguard.peers connection show uuid "$uuid" 2>/dev/null \
          | head -c "$MAX_PEERS_BYTES" | tr -d '\\' \
          | sed -n 's/.*endpoint=\([^ ]*\):[0-9]\{1,5\}.*/\1/p' | head -n 1)
        valid_host "$host" || host=''
        printf '%s{"name":"%s","active":%s,"iface":"%s","host":"%s","since":%s}' \
          "$sep" "$(json_str "$name" "$MAX_NAME_BYTES")" "$active" "$dev" "$host" "$ts"
        sep=','
      done
      printf ']\n'
    }
}

cmd_stats() {
  valid_iface "$1" || exit 65
  dir="/sys/class/net/$1/statistics"
  for f in rx_bytes tx_bytes; do
    v=$(head -c 32 "$dir/$f" 2>/dev/null | tr -d '\n')
    case "$v" in ''|*[!0-9]*) v=-1 ;; esac
    printf '%s\n' "$v"
  done
}

# Prints the exit IPv4 address, or nothing. HTTPS only, no redirects,
# connect and total deadlines, response capped by curl and again by head;
# accepted only when the trace has exactly one canonical ip= line.
cmd_ip() {
  out=$(curl -4 -s -f --proto '=https' --max-redirs 0 --connect-timeout 3 -m 6 \
        --max-filesize "$MAX_HTTP_BYTES" https://1.1.1.1/cdn-cgi/trace 2>/dev/null \
        | head -c "$MAX_HTTP_BYTES" | tr -d '\r')
  ips=$(printf '%s\n' "$out" | sed -n 's/^ip=//p')
  [ "$(printf '%s\n' "$ips" | grep -c .)" -eq 1 ] || return 1
  ip=$(printf '%s\n' "$ips" | head -n 1)
  valid_ipv4 "$ip" || return 1
  printf '%s\n' "$ip"
}

cmd_up() {
  [ $# -ge 1 ] && [ $# -le "$MAX_PROFILES" ] || exit 65
  for x in "$@"; do valid_name "$x" || exit 65; done
  target=$1; shift
  for x in "$@"; do nmcli -w "$NM_DOWN_WAIT" connection down "$x" >/dev/null 2>&1; done
  nmcli -w "$NM_UP_WAIT" connection up "$target" >/dev/null 2>&1 && exit 0
  # Take a failed activation back down so NetworkManager does not keep
  # retrying what the user just watched fail.
  nmcli -w "$NM_DOWN_WAIT" connection down "$target" >/dev/null 2>&1
  exit 1
}

cmd_down() {
  [ $# -ge 1 ] && [ $# -le "$MAX_PROFILES" ] || exit 65
  for x in "$@"; do valid_name "$x" || exit 65; done
  rc=0
  for x in "$@"; do nmcli -w "$NM_DOWN_WAIT" connection down "$x" >/dev/null 2>&1 || rc=1; done
  exit "$rc"
}

cmd_notify() {
  case "$1" in normal|critical) ;; *) exit 65 ;; esac
  exec omarchy-notification-send -u "$1" -g "$GLYPH" WireGuard "$(clip "$2" "$MAX_TEXT_BYTES")"
}

# Prints the interface the kernel would use to reach the exit-IP probe, or
# nothing. A split tunnel (AllowedIPs narrower than 0.0.0.0/0) leaves this on
# the normal uplink, so its exit IP is legitimately not the gateway's.
cmd_route() {
  dev=$(ip -o -4 route get 1.1.1.1 2>/dev/null | head -c 1024 \
        | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1)
  valid_iface "$dev" || return 1
  printf '%s\n' "$dev"
}

# True when IFACE is a WireGuard link.
is_wireguard() {
  valid_iface "$1" || return 1
  ip -d -o link show dev "$1" 2>/dev/null | head -c 4096 | grep -q ' wireguard '
}

cmd_notify_connect() {
  lead=$(clip "$1" "$MAX_TEXT_BYTES")
  expected=${2:-}
  valid_ipv4 "$expected" || expected=''
  ip=$(cmd_ip) || ip=''
  u=normal
  if [ -z "$ip" ]; then body="$lead · exit IP not verified"
  elif [ -n "$expected" ] && [ "$ip" != "$expected" ]; then
    dev=$(cmd_route) || dev=''
    if [ -n "$dev" ] && ! is_wireguard "$dev"; then body="$lead · split tunnel, exit IP $ip"
    else body="$lead · exit IP $ip, expected $expected"; u=critical
    fi
  else body="$lead · exit IP $ip"
  fi
  exec omarchy-notification-send -u "$u" -g "$GLYPH" WireGuard "$body"
}

[ $# -ge 1 ] || exit 64
cmd=$1; shift
case "$cmd" in
  list)           [ $# -eq 0 ] || exit 64; cmd_list ;;
  stats)          [ $# -eq 1 ] || exit 64; cmd_stats "$1" ;;
  ip)             [ $# -eq 0 ] || exit 64; cmd_ip ;;
  up)             cmd_up "$@" ;;
  down)           cmd_down "$@" ;;
  notify)         [ $# -eq 2 ] || exit 64; cmd_notify "$1" "$2" ;;
  notify-connect) [ $# -ge 1 ] && [ $# -le 2 ] || exit 64; cmd_notify_connect "$@" ;;
  route)          [ $# -eq 0 ] || exit 64; cmd_route ;;
  *)              exit 64 ;;
esac
