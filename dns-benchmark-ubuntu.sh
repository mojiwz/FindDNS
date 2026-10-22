#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

# Ubuntu DNS benchmark + optional system-wide DNS change via systemd-resolved.
# This script DOES NOT modify Xray/Marzban configuration.
# Run: sudo bash dns-benchmark-ubuntu.sh

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

if ! command -v dig >/dev/null 2>&1; then
  echo "Missing 'dig'. Install it first with: sudo apt-get update && sudo apt-get install -y dnsutils"
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1 || ! systemctl is-active --quiet systemd-resolved; then
  echo "systemd-resolved is not active. No changes made."
  echo "This script intentionally avoids overwriting /etc/resolv.conf blindly."
  echo "Enable/configure your server's DNS manager first, or adapt the script for NetworkManager/netplan."
  exit 1
fi

# Label|IPv4. NextDNS generic addresses may not apply a personal profile;
# provider filters differ, and the fastest DNS is not necessarily an ad-blocking DNS.
DNS_LIST=(
  "cloudflare|1.1.1.1"
  "level3|4.2.2.1"
  "google|8.8.8.8"
  "quad9|9.9.9.9"
  "freenom|80.80.80.80"
  "opendns|208.67.222.222"
  "norton|199.85.126.10"
  "cleanbrowsing|185.228.168.9"
  "yandex|77.88.8.8"
  "adguard|94.140.14.14"
  "neustar|156.154.70.1"
  "comodo|8.26.56.26"
  "nextdns|45.90.28.0"
)

TEST_DOMAINS=("example.com" "cloudflare.com" "google.com")
REPEATS=3
TIMEOUT=2
RESULTS="$(mktemp)"
trap 'rm -f "$RESULTS"' EXIT

echo "DNS benchmark from this Ubuntu server"
echo "Tests: ${#TEST_DOMAINS[@]} domains x $REPEATS rounds per DNS; timeout ${TIMEOUT}s"
echo "This measures DNS query latency/reliability, not HTTP speed or ad-blocking quality."
echo

for item in "${DNS_LIST[@]}"; do
  name="${item%%|*}"
  ip="${item##*|}"
  success=0
  total=$(( ${#TEST_DOMAINS[@]} * REPEATS ))
  times=()
  ad_result="unknown"

  for domain in "${TEST_DOMAINS[@]}"; do
    for ((i=1; i<=REPEATS; i++)); do
      out="$(dig @"$ip" "$domain" A +time="$TIMEOUT" +tries=1 +noall +answer +comments 2>/dev/null || true)"
      status="$(printf '%s\n' "$out" | awk '/status:/ {for (i=1;i<=NF;i++) if ($i ~ /^status:/) {gsub(/[,;]/,"",$(i+1)); print $(i+1); exit}}')"
      ms="$(printf '%s\n' "$out" | awk '/Query time:/ {print $4; exit}')"
      # A successful DNS response may legitimately be NOERROR with an empty answer;
      # for these known public A records, require NOERROR and an answer.
      if [[ "$status" == "NOERROR" ]] && printf '%s\n' "$out" | grep -qE '^[^;[:space:]]+[[:space:]]+[0-9]+[[:space:]]+IN[[:space:]]+A[[:space:]]+'; then
        success=$((success+1))
        [[ "$ms" =~ ^[0-9]+$ ]] && times+=("$ms")
      fi
    done
  done

  # Median successful query time, more robust than mean for occasional spikes.
  if ((${#times[@]})); then
    sorted="$(printf '%s\n' "${times[@]}" | sort -n)"
    median="$(printf '%s\n' "$sorted" | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}')"
  else
    median=9999
  fi

  # Ad-filter check is informative only; a provider may return NXDOMAIN, 0.0.0.0,
  # or a sinkhole address. Do not use this result as the latency benchmark.
  ad_out="$(dig @"$ip" doubleclick.net A +time="$TIMEOUT" +tries=1 +noall +answer +comments 2>/dev/null || true)"
  ad_status="$(printf '%s\n' "$ad_out" | awk '/status:/ {for (i=1;i<=NF;i++) if ($i ~ /^status:/) {gsub(/[,;]/,"",$(i+1)); print $(i+1); exit}}')"
  ad_ips="$(printf '%s\n' "$ad_out" | awk '$4=="A" {print $5}' | paste -sd, -)"
  if [[ "$ad_status" == "NXDOMAIN" ]] || printf '%s\n' "$ad_ips" | grep -Eq '(^|,)(0\.0\.0\.0|127\.0\.0\.1)(,|$)'; then
    ad_result="possibly-blocked"
  elif [[ "$ad_status" == "NOERROR" && -n "$ad_ips" ]]; then
    ad_result="resolved"
  elif [[ -z "$ad_status" ]]; then
    ad_result="timeout/error"
  else
    ad_result="$ad_status"
  fi

  # Score prioritizes reliability, then median latency. Any resolver with <80%
  # successful normal lookups is excluded from automatic selection.
  if (( success * 100 / total < 80 )); then
    score=999999
  else
    score=$((median * 100 + (total-success) * 10000))
  fi
  printf '%s|%s|%s|%s|%s|%s\n' "$name" "$ip" "$success" "$total" "$median" "$ad_result" >> "$RESULTS"
done

echo "Results (sorted by reliability/median latency):"
printf '%-14s %-16s %-12s %-12s %-18s\n' "Provider" "DNS IP" "Success" "Median(ms)" "doubleclick test"
while IFS='|' read -r name ip success total median ad_result; do
  printf '%-14s %-16s %-12s %-12s %-18s\n' "$name" "$ip" "$success/$total" "$median" "$ad_result"
done < <(
  while IFS='|' read -r name ip success total median ad_result; do
    if (( success * 100 / total < 80 )); then score=999999; else score=$((median * 100 + (total-success) * 10000)); fi
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$score" "$name" "$ip" "$success" "$total" "$median" "$ad_result"
  done < "$RESULTS" | sort -t'|' -k1,1n
)

winner_line="$(
  while IFS='|' read -r name ip success total median ad_result; do
    if (( success * 100 / total >= 80 )); then
      score=$((median * 100 + (total-success) * 10000))
      printf '%s|%s|%s|%s|%s|%s|%s\n' "$score" "$name" "$ip" "$success" "$total" "$median" "$ad_result"
    fi
  done < "$RESULTS" | sort -t'|' -k1,1n | head -n1 || true
)"

if [[ -z "$winner_line" ]]; then
  echo
  echo "No DNS server reached 80% successful lookups. Nothing will be changed."
  exit 2
fi

IFS='|' read -r _ best_name best_ip best_success best_total best_median best_ad <<< "$winner_line"
echo
echo "Recommended by this test: $best_name ($best_ip)"
echo "Successful lookups: $best_success/$best_total; median latency: ${best_median} ms"
echo "Ad-block check: $best_ad (informational only; this test cannot certify an ad blocker)."
echo
echo "Note: the fastest DNS is not necessarily the best privacy/ad-blocking choice."
read -r -p "Apply $best_ip as the system-wide DNS via systemd-resolved? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Cancelled. No system configuration changed."
  exit 0
fi

CONF_DIR="/etc/systemd/resolved.conf.d"
CONF_FILE="$CONF_DIR/90-dns-benchmark.conf"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP=""
mkdir -p "$CONF_DIR"

if [[ -e "$CONF_FILE" ]]; then
  BACKUP="${CONF_FILE}.bak.${STAMP}"
  cp -a "$CONF_FILE" "$BACKUP"
  echo "Previous custom config backed up to: $BACKUP"
fi

TMP_FILE="$(mktemp "$CONF_DIR/.90-dns-benchmark.XXXXXX")"
cat > "$TMP_FILE" <<EOF
# Managed by dns-benchmark-ubuntu.sh
# Generated: $(date -Is)
[Resolve]
DNS=$best_ip
FallbackDNS=
Domains=~.
EOF
chmod 0644 "$TMP_FILE"
mv -f "$TMP_FILE" "$CONF_FILE"

if ! systemctl restart systemd-resolved; then
  echo "Restart failed; rolling back."
  if [[ -n "$BACKUP" ]]; then cp -a "$BACKUP" "$CONF_FILE"; else rm -f "$CONF_FILE"; fi
  systemctl restart systemd-resolved || true
  exit 3
fi

sleep 2
if resolvectl query example.com >/dev/null 2>&1; then
  echo "DNS configuration applied and test query succeeded."
  resolvectl status | sed -n '1,100p'
  echo
  echo "Xray/Marzban configuration was NOT modified."
  echo "To revert: remove $CONF_FILE and restart systemd-resolved."
  [[ -n "$BACKUP" ]] && echo "Prior custom config backup: $BACKUP"
else
  echo "Post-change test failed; rolling back."
  if [[ -n "$BACKUP" ]]; then cp -a "$BACKUP" "$CONF_FILE"; else rm -f "$CONF_FILE"; fi
  systemctl restart systemd-resolved || true
  echo "Previous configuration restored. Check your server's DNS/network setup."
  exit 4
fi
