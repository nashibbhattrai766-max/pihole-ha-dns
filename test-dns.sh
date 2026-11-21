#!/bin/bash
# Quick health check for both Pi-holes and the Unbound behind them.
# Usage: ./test-dns.sh 10.0.0.2 10.0.0.20      (run anywhere with dig)
SERVERS=("$@"); [ ${#SERVERS[@]} -eq 0 ] && SERVERS=(10.0.0.2 10.0.0.20)
for S in "${SERVERS[@]}"; do
  printf '%-12s ' "$S"
  A=$(dig +short +time=2 +tries=1 @"$S" example.com A | head -1)
  B=$(dig +short +time=2 +tries=1 @"$S" doubleclick.net A | head -1)
  printf 'resolve:%-16s block:%-10s' "${A:-FAIL}" "${B:-FAIL}"
  # DNSSEC: a correctly validating resolver must refuse a deliberately broken domain
  F=$(dig +time=2 +tries=1 @"$S" dnssec-failed.org A | grep -o 'status: [A-Z]*')
  echo " dnssec-broken-domain:${F#status: } (want SERVFAIL)"
done

# Run this ON the Pi-hole host to test Unbound directly and see whether answers are genuine:
#   dig +norec @127.0.0.1 -p 5335 . NS     -> flags "qr aa" from a root server = real recursion
# If you get "qr ra" with an odd server IP instead, something on the network is intercepting DNS.
