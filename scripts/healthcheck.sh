#!/usr/bin/env bash
# Health check for the lab app: HTTP endpoint, disk usage and memory usage.
# Exit code 0 = all checks passed, 1 = at least one check failed (monitoring tools rely on this).
set -euo pipefail

URL="http://localhost:8080/app/health"
MAX_DISK=90   # maximum used disk space on / in percent
MAX_MEM=90    # maximum used memory in percent
FAILED=0

usage() {
  echo "Usage: $0 [-u url] [-d max_disk_percent] [-m max_memory_percent]"
}

while getopts "u:d:m:h" opt; do
  case "$opt" in
    u) URL="$OPTARG" ;;
    d) MAX_DISK="$OPTARG" ;;
    m) MAX_MEM="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

ok()   { echo "OK    $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }

check_http() {
  if body=$(curl -fsS --max-time 5 "$URL" 2>&1); then
    ok "http   $URL -> $(echo "$body" | head -n 1)"
  else
    fail "http   $URL -> $body"
  fi
}

check_disk() {
  local used
  used=$(df -P / | awk 'NR==2 { gsub("%", "", $5); print $5 }')
  if [ "$used" -le "$MAX_DISK" ]; then
    ok "disk   / ${used}% used (limit ${MAX_DISK}%)"
  else
    fail "disk   / ${used}% used (limit ${MAX_DISK}%)"
  fi
}

check_memory() {
  if [ ! -r /proc/meminfo ]; then
    echo "SKIP  memory (no /proc/meminfo - not Linux)"
    return
  fi
  local total available used
  total=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
  available=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
  used=$(( (total - available) * 100 / total ))
  if [ "$used" -le "$MAX_MEM" ]; then
    ok "memory ${used}% used (limit ${MAX_MEM}%)"
  else
    fail "memory ${used}% used (limit ${MAX_MEM}%)"
  fi
}

check_http
check_disk
check_memory

exit "$FAILED"
