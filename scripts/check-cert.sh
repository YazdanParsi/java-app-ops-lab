#!/usr/bin/env bash
# TLS certificate expiry check: warns before a server certificate expires.
# Exit codes follow the Nagios/Zabbix convention:
#   0 = OK, 1 = WARNING (expires within the warning period), 2 = CRITICAL (expired), 3 = UNKNOWN (no certificate)
set -euo pipefail

HOST="localhost"
PORT=8443
DAYS=30   # warn when fewer days than this are left

usage() {
  echo "Usage: $0 [-H host] [-p port] [-d warn_days]"
}

while getopts "H:p:d:h" opt; do
  case "$opt" in
    H) HOST="$OPTARG" ;;
    p) PORT="$OPTARG" ;;
    d) DAYS="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 3 ;;
  esac
done

# Fetch the certificate the server presents (SNI = host name), keep only the PEM block.
# s_client's exit status differs between OpenSSL and LibreSSL (macOS), so judge by the output instead.
cert=$(openssl s_client -connect "${HOST}:${PORT}" -servername "$HOST" </dev/null 2>/dev/null | openssl x509 2>/dev/null || true)
if [ -z "$cert" ]; then
  echo "UNKNOWN  could not read a certificate from ${HOST}:${PORT}"
  exit 3
fi

subject=$(openssl x509 -noout -subject <<<"$cert" | sed 's/^subject= *//')
not_after=$(openssl x509 -noout -enddate <<<"$cert" | cut -d= -f2)

if openssl x509 -noout -checkend "$((DAYS * 86400))" <<<"$cert" >/dev/null; then
  echo "OK       ${HOST}:${PORT} ${subject} – expires ${not_after} (more than ${DAYS} days left)"
  exit 0
elif openssl x509 -noout -checkend 0 <<<"$cert" >/dev/null; then
  echo "WARNING  ${HOST}:${PORT} ${subject} – expires ${not_after} (less than ${DAYS} days left)"
  exit 1
else
  echo "CRITICAL ${HOST}:${PORT} ${subject} – EXPIRED on ${not_after}"
  exit 2
fi
