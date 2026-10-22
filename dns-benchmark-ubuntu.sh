
#!/usr/bin/env bash
# AKDNS Manager - Ubuntu Server
# DNS status, benchmark, manual DNS, MTU test, backup and restore.
# No changes to Xray or Marzban.
# Requires root. DNS changes require explicit confirmation.

set -Eeuo pipefail
umask 077

APP="AKDNS System Manager"
BACKUP_ROOT="/var/backups/akdns"
DROPIN="/etc/systemd/resolved.conf.d/90-akdns.conf"

mkdir -p "$BACKUP_ROOT"

# ---------- Basic helpers ----------

need_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Run: sudo bash $0"
        exit 1
    fi
}

has() { command -v "$1" >/dev/null 2>&1; }

active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

pause() {
    read -r -p "Press Enter to continue..." _
}

confirm() {
    local answer
    read -r -p "$1 Type YES to continue: " answer
    [[ "$answer" == "YES" ]]
}

primary_iface() {
    ip -o route show default 2>/dev/null |
        awk 'NR == 1 {print $5; exit}'
}

iface_mtu() {
    local iface="${1:-}"
    if [[ -n "$iface" && -r "/sys/class/net/$iface/mtu" ]]; then
        cat "/sys/class/net/$iface/mtu"
    else
        echo "unknown"
    fi
}

netplan_present() {
    has netplan || compgen -G '/etc/netplan/*.yaml' >/dev/null
}

dns_backend() {
    if active systemd-resolved; then
        echo "systemd-resolved"
    elif active NetworkManager; then
        echo "NetworkManager"
    elif netplan_present; then
        echo "netplan"
    else
        echo "resolv.conf/unknown"
    fi
}

permanent_backend() {
    if netplan_present; then
        echo "netplan"
    elif active NetworkManager; then
        echo "NetworkManager"
    elif [[ -d /etc/systemd/resolved.conf.d ]]; then
        echo "systemd-resolved"
    else
        echo "resolv.conf/unknown"
    fi
}

current_dns() {
    if active systemd-resolved && has resolvectl; then
        resolvectl dns 2>/dev/null |
            awk '{
                for (i=2; i<=NF; i++)
                    if ($i ~ /^[0-9a-fA-F:.%]+$/) print $i
            }' | sort -u | paste -sd ' ' -
    else
        awk '$1 == "nameserver" {print $2}' /etc/resolv.conf \
            2>/dev/null | paste -sd ' ' -
    fi
}

# ---------- Backup ----------

backup_now() {
    local stamp dest iface mtu
    local -a paths=()

    stamp="$(date +%Y%m%d-%H%M%S)"
    dest="$BACKUP_ROOT/$stamp"

    # Avoid overwriting a backup if called twice within one second.
    if [[ -e "$dest" ]]; then
        stamp="${stamp}-$$"
        dest="$BACKUP_ROOT/$stamp"
    fi

    mkdir -p "$dest"

    for path in \
        etc/netplan \
        etc/NetworkManager/system-connections \
        etc/NetworkManager/NetworkManager.conf \
        etc/systemd/resolved.conf.d \
        etc/resolv.conf \
        etc/network/interfaces \
        etc/dhcpcd.conf
    do
        [[ -e "/$path" || -L "/$path" ]] && paths+=("$path")
    done

    if ((${#paths[@]})); then
        tar -C / -cpf "$dest/config.tar" "${paths[@]}" \
            || {
                echo "Warning: some configuration files could not be backed up."
                return 1
            }
    else
        tar -cpf "$dest/config.tar" --files-from /dev/null
    fi

    iface="$(primary_iface)"
    mtu="$(iface_mtu "$iface")"

    printf '%s\n' "$iface" > "$dest/interface"
    printf '%s\n' "$mtu" > "$dest/mtu"
    printf '%s\n' "$(current_dns)" > "$dest/current-dns.txt"
    printf '%s\n' "$(date --iso-8601=seconds)" > "$dest/created-at"
    printf '%s\n' "$DROPIN" > "$dest/akdns-dropin-path"

    if [[ -e "$DROPIN" ]]; then
        echo "present" > "$dest/akdns-dropin-state"
    else
        echo "absent" > "$dest/akdns-dropin-state"
    fi

    echo "$stamp" > "$BACKUP_ROOT/last-backup"
    echo "Backup created: $dest"
}

list_backups() {
    echo
    echo "Available backups:"
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
        -printf '%f\n' 2>/dev/null | sort -r
}

restart_dns_services() {
    if active systemd-resolved; then
        systemctl restart systemd-resolved || true
    fi

    if active NetworkManager && has nmcli; then
        nmcli connection reload || true
    fi
}

restore_backup() {
    local name src iface mtu
    list_backups
    echo

    read -r -p "Backup name to restore: " name

    # Permit the standard timestamp and the collision suffix.
    [[ "$name" =~ ^[0-9]{8}-[0-9]{6}(-[0-9]+)?$ ]] || {
        echo "Invalid backup name."
        return 1
    }

    src="$BACKUP_ROOT/$name"

    [[ -d "$src" && -f "$src/config.tar" ]] || {
        echo "Backup not found or incomplete."
        return 1
    }

    echo "WARNING: restoring network files may interrupt SSH."
    echo "Current settings will be backed up first."

    confirm "Restore this backup?" || {
        echo "Cancelled."
        return 0
    }

    backup_now || {
        echo "Could not create safety backup; restore cancelled."
        return 1
    }

    # Remove our own drop-in if it did not exist at backup time.
    if [[ -f "$src/akdns-dropin-state" ]] &&
       [[ "$(cat "$src/akdns-dropin-state")" == "absent" ]]; then
        rm -f "$DROPIN"
    fi

    if ! tar -C / -xpf "$src/config.tar"; then
        echo "Warning: archive restore reported an error."
        return 1
    fi

    restart_dns_services

    # Restore temporary MTU too, when the saved interface still exists.
    iface="$(cat "$src/interface" 2>/dev/null || true)"
    mtu="$(cat "$src/mtu" 2>/dev/null || true)"

    if [[ -n "$iface" && -e "/sys/class/net/$iface/mtu" &&
          "$mtu" =~ ^[0-9]+$ ]]; then
        ip link set dev "$iface" mtu "$mtu" ||
            echo "Warning: could not restore temporary MTU."
    fi

    echo "Restore attempt finished."
    echo "Verify DNS, routing, MTU and SSH connectivity."
    echo "Note: files created after the backup may still need manual review."
}

# ---------- System status ----------

show_status() {
    local distro distro_id init iface dns mtu backend perm backups last
    local target

    distro="$(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")"
    distro_id="$(. /etc/os-release; echo "${ID:-unknown}")"
    init="$(ps -p 1 -o comm= 2>/dev/null || echo unknown)"
    iface="$(primary_iface)"
    dns="$(current_dns)"
    mtu="$(iface_mtu "$iface")"
    backend="$(dns_backend)"
    perm="$(permanent_backend)"
    target="$(readlink -f /etc/resolv.conf 2>/dev/null || echo unknown)"

    backups="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 \
        -type d 2>/dev/null | wc -l)"
    last="none"
    [[ -f "$BACKUP_ROOT/last-backup" ]] &&
        last="$(cat "$BACKUP_ROOT/last-backup")"

    echo
    echo "====== AKDNS System Status ======"
    printf "%-22s %s\n" "Distro:" "$distro"
    printf "%-22s %s\n" "Distro ID:" "$distro_id"
    printf "%-22s %s\n" "init system:" "$init"
    printf "%-22s %s\n" "DNS backend(temp):" "$backend"
    printf "%-22s %s\n" "DNS backend(perm):" "$perm"
    printf "%-22s %s\n" "Current DNS:" "${dns:-unknown}"
    printf "%-22s %s\n" "resolv.conf target:" "$target"
    printf "%-22s %s\n" "Primary iface:" "${iface:-unknown}"
    printf "%-22s %s\n" "Current MTU:" "$mtu"
    printf "%-22s %s\n" "Backup count:" "$backups"
    printf "%-22s %s\n" "Last backup:" "$last"
    echo "================================="
    echo
}

# ---------- DNS benchmark ----------

benchmark_dns() {
    if ! has dig; then
        echo "dig is missing. Install dnsutils first:"
        echo "sudo apt-get update && sudo apt-get install dnsutils"
        return 1
    fi

    local ip domain output status ms median success score
    local winner="" best=""
    local -a times=()
    local -a resolvers=(
        1.1.1.1
        1.0.0.1
        8.8.8.8
        8.8.4.4
        9.9.9.9
        149.112.112.112
        94.140.14.14
        94.140.15.15
        208.67.222.222
        208.67.220.220
    )
    local -a domains=(
        example.com
        ubuntu.com
        cloudflare.com
    )

    echo
    echo "Benchmarking DNS: 3 domains x 3 rounds per resolver."
    echo "Time is extracted from the SAME dig invocation as the DNS response."
    echo

    printf '%-18s %-12s %-14s\n' "Resolver" "Success" "Median(ms)"

    # Avoid associative arrays: compatible with common Ubuntu Bash versions.
    local results_file
    results_file="$(mktemp)"
    trap 'rm -f "$results_file"' RETURN

    for ip in "${resolvers[@]}"; do
        times=()
        success=0

        for domain in "${domains[@]}"; do
            for round in 1 2 3; do
                # +stats is explicitly enabled; do not run a second dig
                # command to obtain Query time.
                output="$(dig @"$ip" "$domain" A \
                    +time=2 +tries=1 +comments +answer +stats \
                    2>/dev/null || true)"

                status="$(printf '%s\n' "$output" |
                    sed -n 's/.*status: \([^,]*\),.*/\1/p' |
                    head -n 1)"

                ms="$(printf '%s\n' "$output" |
                    awk '/Query time:/ {print $4; exit}')"

                # Count a successful test only when NOERROR and an answer
                # are present. Empty responses and SERVFAIL are not successes.
                if [[ "$status" == "NOERROR" ]] &&
                   printf '%s\n' "$output" |
                       awk '$0 !~ /^;/ && NF >= 5 {found=1} END {exit !found}'
                then
                    success=$((success + 1))
                    [[ "$ms" =~ ^[0-9]+$ ]] && times+=("$ms")
                fi
            done
        done

        if ((${#times[@]})); then
            median="$(printf '%s\n' "${times[@]}" | sort -n |
                awk '{
                    a[NR]=$1
                }
                END {
                    if (NR%2) print a[(NR+1)/2];
                    else printf "%.1f\n", (a[NR/2]+a[NR/2+1])/2
                }')"
        else
            median="N/A"
        fi

        printf '%-18s %-12s %-14s\n' "$ip" "$success/9" "$median"
        printf '%s|%s|%s\n' "$ip" "$success" "$median" >> "$results_file"
    done

    # Rank by success count first, then measured median latency.
    # Ignore entries with missing timing data or poor reliability.
    while IFS='|' read -r ip success median; do
        [[ "$success" =~ ^[0-9]+$ ]] || continue
        [[ "$median" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
        (( success >= 7 )) || continue

        score="$(awk -v s="$success" -v m="$median" \
            'BEGIN {printf "%.4f", (9-s)*1000 + m}')"

        if [[ -z "$winner" ]] ||
           awk -v a="$score" -v b="$best" 'BEGIN {exit !(a<b)}'
        then
            winner="$ip"
            best="$score"
        fi
    done < "$results_file"

    rm -f "$results_file"
    trap - RETURN

    echo
    if [[ -n "$winner" ]]; then
        echo "Recommended DNS: $winner"
        echo "$winner" > "$BACKUP_ROOT/recommended-dns"
        echo "This is a latency/reliability recommendation, not an ad-blocking guarantee."
    else
        rm -f "$BACKUP_ROOT/recommended-dns"
        echo "No resolver met the reliability and timing requirements."
        echo "No recommendation was saved; no settings were changed."
    fi
}

# ---------- DNS validation and application ----------

validate_dns_list() {
    local dns="$1"

    if ! has python3; then
        echo "python3 is required to validate DNS addresses."
        return 1
    fi

    DNS_INPUT="$dns" python3 - <<'PY'
import ipaddress
import os
import sys

items = os.environ.get("DNS_INPUT", "").split()
if not items:
    print("Enter at least one DNS address.", file=sys.stderr)
    sys.exit(1)

for item in items:
    try:
        ip = ipaddress.ip_address(item)
    except ValueError:
        print(f"Invalid IP address: {item}", file=sys.stderr)
        sys.exit(1)
    if ip.version != 4:
        print("This script's current DNS apply paths support IPv4 DNS only.",
              file=sys.stderr)
        sys.exit(1)
PY
}

apply_dns() {
    local dns="$1" backend conn

    validate_dns_list "$dns" || return 1
    backend="$(dns_backend)"

    echo "Detected DNS backend: $backend"
    echo "Requested DNS: $dns"

    case "$backend" in
        systemd-resolved)
            confirm "Back up and apply DNS?" || return 0
            backup_now || return 1

            mkdir -p "$(dirname "$DROPIN")"
            {
                echo "[Resolve]"
                echo "DNS=$dns"
                echo "FallbackDNS=1.1.1.1 9.9.9.9"
                echo "Domains=~."
            } > "$DROPIN"

            if ! systemctl restart systemd-resolved; then
                echo "systemd-resolved restart failed."
                echo "Use option 7 to restore a previous backup."
                return 1
            fi
            ;;
        NetworkManager)
            if ! has nmcli; then
                echo "nmcli is unavailable."
                return 1
            fi

            conn="$(nmcli -t -f NAME,DEVICE connection show --active |
                awk -F: '$2 != "" {print $1; exit}')"

            [[ -n "$conn" ]] || {
                echo "No active NetworkManager connection found."
                return 1
            }

            echo "Active connection: $conn"
            confirm "Back up and set DNS on this connection?" || return 0
            backup_now || return 1

            nmcli connection modify "$conn" \
                ipv4.ignore-auto-dns yes ipv4.dns "$dns" || return 1

            echo "Saved to NetworkManager profile."
            echo "Live DNS may require a reconnect; reconnecting can interrupt SSH."
            ;;
        netplan)
            echo "Netplan is present, but this script will not rewrite YAML blindly."
            echo "The existing YAML may contain routes, cloud-init settings, or SSH-critical configuration."
            echo "No DNS changes were made."
            echo "Configure nameservers in the existing interface definition and use:"
            echo "sudo netplan try"
            return 1
            ;;
        *)
            echo "DNS backend is static or unknown."
            echo "Refusing to overwrite /etc/resolv.conf."
            echo "No DNS changes were made."
            return 1
            ;;
    esac

    echo
    if getent ahosts ubuntu.com >/dev/null 2>&1; then
        echo "System DNS verification: PASS"
    else
        echo "System DNS verification FAILED."
        echo "Do not close your existing SSH session."
        echo "Use option 7 to restore a known-good backup if needed."
        return 1
    fi
}

manual_dns() {
    local dns
    echo "Enter IPv4 DNS addresses separated by spaces."
    echo "Example: 1.1.1.1 1.0.0.1"
    read -r -p "DNS: " dns
    apply_dns "$dns"
}

apply_recommended_dns() {
    local dns

    if [[ ! -s "$BACKUP_ROOT/recommended-dns" ]]; then
        echo "No valid recommendation. Run benchmark first."
        return 1
    fi

    dns="$(cat "$BACKUP_ROOT/recommended-dns")"
    echo "Recommended DNS: $dns"
    apply_dns "$dns"
}

# ---------- MTU ----------

test_mtu_candidate() {
    local target="$1" mtu="$2" payload="$3"
    local successes=0 i

    # Two successful probes out of three reduce sensitivity to one lost packet.
    for i in 1 2 3; do
        if ping -n -c 1 -W 2 -M do -s "$payload" "$target" \
            >/dev/null 2>&1; then
            successes=$((successes + 1))
        fi
    done

    (( successes >= 2 ))
}

detect_best_mtu() {
    local iface target low high mid payload current
    iface="$(primary_iface)"

    [[ -n "$iface" ]] || {
        echo "No default-route interface found."
        return 1
    }

    current="$(iface_mtu "$iface")"
    echo "Interface: $iface"
    echo "Current MTU: $current"

    if ! has ping; then
        echo "Install ping with: sudo apt-get install iputils-ping"
        return 1
    fi

    target="1.1.1.1"
    echo "Testing IPv4 path to $target."
    echo "ICMP filtering or rate limiting can make this estimate inconclusive."

    # IPv4 packet size = ICMP payload + 20-byte IPv4 header + 8-byte ICMP header.
    # Search standard Ethernet MTUs only; do not claim jumbo MTU detection.
    low=576
    high=1500

    if ! test_mtu_candidate "$target" 576 548; then
        echo "Even the minimum test did not pass reliably."
        echo "MTU estimate unavailable; ICMP may be blocked."
        return 1
    fi

    while (( low < high )); do
        mid=$(( (low + high + 1) / 2 ))
        payload=$((mid - 28))

        if test_mtu_candidate "$target" "$mid" "$payload"; then
            low="$mid"
        else
            high=$((mid - 1))
        fi
    done

    echo
    echo "Estimated path MTU: $low"
    echo "This is an ICMP-based estimate, not a guarantee for every destination."
    echo "No MTU setting was changed."
}

set_mtu_manually() {
    local iface mtu backend conn

    iface="$(primary_iface)"
    [[ -n "$iface" ]] || {
        echo "No default-route interface found."
        return 1
    }

    read -r -p "Interface [$iface]: " input_iface
    [[ -n "$input_iface" ]] && iface="$input_iface"

    [[ -e "/sys/class/net/$iface/mtu" ]] || {
        echo "Interface not found: $iface"
        return 1
    }

    read -r -p "New MTU (576-9000): " mtu
    [[ "$mtu" =~ ^[0-9]+$ ]] &&
        (( mtu >= 576 && mtu <= 9000 )) || {
            echo "Invalid MTU."
            return 1
        }

    echo "Interface: $iface"
    echo "Current MTU: $(iface_mtu "$iface")"
    echo "Requested MTU: $mtu"
    echo "Changing MTU can interrupt network connectivity."

    confirm "Back up and apply temporary MTU?" || return 0
    backup_now || return 1

    ip link set dev "$iface" mtu "$mtu" || {
        echo "Temporary MTU change failed."
        return 1
    }

    backend="$(dns_backend)"

    case "$backend" in
        NetworkManager)
            conn="$(nmcli -t -f NAME,DEVICE connection show --active |
                awk -F: -v i="$iface" '$2 == i {print $1; exit}')"

            if [[ -n "$conn" ]]; then
                # Ethernet profile property; Wi-Fi profiles may require
                # 802-11-wireless.mtu instead.
                if ! nmcli connection modify "$conn" \
                    802-3-ethernet.mtu "$mtu"; then
                    echo "Temporary MTU applied, but permanent save failed."
                else
                    echo "MTU saved to NetworkManager Ethernet profile."
                fi
            else
                echo "No active NetworkManager profile matched this interface."
                echo "MTU is temporary only."
            fi
            ;;
        *)
            echo "MTU is temporary only for this backend."
            echo "For persistent MTU, edit the existing Netplan or network profile."
            ;;
    esac

    echo "Current MTU: $(iface_mtu "$iface")"
}

# ---------- Menu ----------

main_menu() {
    while true; do
        echo
        echo "====== AKDNS System Manager ======"
        echo "1. System Status"
        echo "2. Benchmark DNS"
        echo "3. Set DNS Manually"
        echo "4. Detect Best MTU (estimate)"
        echo "5. Set MTU Manually"
        echo "6. Backup Current Settings"
        echo "7. Restore Previous Settings"
        echo "8. List Backups"
        echo "9. Apply Recommended DNS"
        echo "0. Exit"
        echo "=================================="

        read -r -p "Select option: " choice

        case "$choice" in
            1) show_status; pause ;;
            2) benchmark_dns; pause ;;
            3) manual_dns; pause ;;
            4) detect_best_mtu; pause ;;
            5) set_mtu_manually; pause ;;
            6) backup_now; pause ;;
            7) restore_backup; pause ;;
            8) list_backups; pause ;;
            9) apply_recommended_dns; pause ;;
            0) exit 0 ;;
            *) echo "Invalid option." ;;
        esac
    done
}

need_root
main_menu
