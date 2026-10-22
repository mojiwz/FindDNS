
#!/usr/bin/env bash
# AKDNS System Manager for Ubuntu
# DNS status, benchmark, manual configuration, MTU, backup and restore.
# Does not modify Xray or Marzban configuration.

set -Eeuo pipefail
umask 077

APP="AKDNS System Manager"
BACKUP_ROOT="/var/backups/akdns"
DROPIN="/etc/systemd/resolved.conf.d/90-akdns.conf"
mkdir -p "$BACKUP_ROOT"

# ---------- Helpers ----------

pause() {
    read -r -p "Press Enter to continue..." _
}

is_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Run as root: sudo bash $0"
        exit 1
    fi
}

has() {
    command -v "$1" >/dev/null 2>&1
}

active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

get_iface() {
    ip -o route show default 2>/dev/null |
        awk 'NR==1 {print $5; exit}'
}

get_dns() {
    if active systemd-resolved && has resolvectl; then
        resolvectl dns 2>/dev/null |
            awk '{
                for (i=2; i<=NF; i++)
                    if ($i ~ /^[0-9a-fA-F:.%]+$/) print $i
            }' | sort -u | paste -sd ' ' -
    else
        awk '/^[[:space:]]*nameserver[[:space:]]+/ {print $2}' \
            /etc/resolv.conf 2>/dev/null | paste -sd ' ' -
    fi
}

get_mtu() {
    local iface="${1:-}"
    [[ -n "$iface" && -r "/sys/class/net/$iface/mtu" ]] &&
        cat "/sys/class/net/$iface/mtu" || echo "unknown"
}

detect_backend() {
    if active systemd-resolved; then
        echo "systemd-resolved"
    elif active NetworkManager; then
        echo "NetworkManager"
    elif has netplan && compgen -G '/etc/netplan/*.yaml' >/dev/null; then
        echo "netplan"
    else
        echo "resolv.conf/unknown"
    fi
}

detect_permanent_backend() {
    if compgen -G '/etc/netplan/*.yaml' >/dev/null; then
        echo "netplan"
    elif active NetworkManager; then
        echo "NetworkManager"
    elif [[ -d /etc/systemd/resolved.conf.d ]]; then
        echo "systemd-resolved"
    else
        echo "resolv.conf/unknown"
    fi
}

# ---------- Backups ----------

backup_now() {
    local stamp dest
    stamp="$(date +%Y%m%d-%H%M%S)"
    dest="$BACKUP_ROOT/$stamp"
    mkdir -p "$dest"

    for path in \
        /etc/netplan \
        /etc/NetworkManager/system-connections \
        /etc/systemd/resolved.conf.d \
        /etc/resolv.conf \
        /etc/network/interfaces
    do
        if [[ -e "$path" || -L "$path" ]]; then
            mkdir -p "$dest$(dirname "$path")"
            cp -a "$path" "$dest$(dirname "$path")/" 2>/dev/null || true
        fi
    done

    if has nmcli; then
        nmcli -t -f NAME,UUID,TYPE,DEVICE connection show \
            > "$dest/nm-connections.txt" 2>/dev/null || true
    fi

    ip -details link show > "$dest/ip-link.txt" 2>/dev/null || true
    ip route show table all > "$dest/routes.txt" 2>/dev/null || true
    get_dns > "$dest/current-dns.txt" 2>/dev/null || true

    echo "$dest" > "$BACKUP_ROOT/last-backup"
    echo "Backup created: $dest"
}

list_backups() {
    echo "Available backups:"
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
        -printf '%f\n' 2>/dev/null | sort -r
}

restore_backup() {
    local name src answer
    list_backups
    echo
    read -r -p "Enter backup name to restore: " name
    [[ "$name" =~ ^[0-9]{8}-[0-9]{6}$ ]] || {
        echo "Invalid backup name."
        return
    }

    src="$BACKUP_ROOT/$name"
    [[ -d "$src" ]] || { echo "Backup not found."; return; }

    echo "WARNING: restoring network configuration can interrupt SSH."
    read -r -p "Type RESTORE to continue: " answer
    [[ "$answer" == "RESTORE" ]] || { echo "Cancelled."; return; }

    # Preserve the current state before attempting a restore.
    backup_now

    for path in \
        /etc/netplan \
        /etc/NetworkManager/system-connections \
        /etc/systemd/resolved.conf.d \
        /etc/resolv.conf \
        /etc/network/interfaces
    do
        if [[ -e "$src$path" || -L "$src$path" ]]; then
            rm -rf "$path"
            mkdir -p "$(dirname "$path")"
            cp -a "$src$path" "$path"
        fi
    done

    if has netplan && compgen -G '/etc/netplan/*.yaml' >/dev/null; then
        netplan generate || echo "Warning: netplan generate failed."
    fi

    if active systemd-resolved; then
        systemctl restart systemd-resolved || true
    fi
    if active NetworkManager; then
        nmcli connection reload || true
    fi

    echo "Restore attempt finished. Verify network and SSH connectivity."
}

# ---------- Status ----------

show_status() {
    local distro distro_id init iface dns mtu backend perm backups last
    distro="$(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")"
    distro_id="$(. /etc/os-release; echo "${ID:-unknown}")"
    init="$(ps -p 1 -o comm= 2>/dev/null || echo unknown)"
    iface="$(get_iface)"
    dns="$(get_dns)"
    mtu="$(get_mtu "$iface")"
    backend="$(detect_backend)"
    perm="$(detect_permanent_backend)"
    backups="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
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
        echo "Installing dnsutils..."
        apt-get update && apt-get install -y dnsutils || return
    fi

    local ip domain round out ms success median
    local winner="" best="" score
    local domains=(example.com ubuntu.com cloudflare.com)
    local resolvers=(
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

    echo
    printf "%-18s %-12s %-14s\n" "Resolver" "Success" "Median(ms)"

    for ip in "${resolvers[@]}"; do
        local -a times=()
        success=0

        for domain in "${domains[@]}"; do
            for round in 1 2 3; do
                out="$(dig +time=2 +tries=1 +noall +answer \
                    "$domain" @"$ip" 2>/dev/null || true)"

                if [[ -n "$out" ]]; then
                    success=$((success + 1))
                    ms="$(dig +time=2 +tries=1 +stats +noall \
                        "$domain" @"$ip" 2>/dev/null |
                        awk '/Query time:/ {print $4; exit}' || true)"
                    [[ "$ms" =~ ^[0-9]+$ ]] && times+=("$ms")
                fi
            done
        done

        if ((${#times[@]})); then
            median="$(printf '%s\n' "${times[@]}" | sort -n |
                awk '{a[NR]=$1}
                END {
                    if (NR%2) print a[(NR+1)/2];
                    else printf "%.1f\n", (a[NR/2]+a[NR/2+1])/2
                }')"
        else
            median=999999
        fi

        printf "%-18s %-12s %-14s\n" "$ip" "$success/9" "$median"

        if (( success >= 5 )); then
            score="$(awk -v s="$success" -v m="$median" \
                'BEGIN {printf "%.2f", (100-s*10)+m}')"
            if [[ -z "$winner" ]] ||
                awk -v a="$score" -v b="$best" 'BEGIN {exit !(a<b)}'
            then
                winner="$ip"
                best="$score"
            fi
        fi
    done

    if [[ -n "$winner" ]]; then
        echo
        echo "Recommended DNS: $winner"
        echo "$winner" > "$BACKUP_ROOT/recommended-dns"
    else
        echo "No resolver passed the reliability threshold."
    fi
}

# ---------- Apply DNS ----------

validate_dns_list() {
    local value="$1" ip
    local -a ips
    read -r -a ips <<< "$value"
    ((${#ips[@]} > 0)) || return 1

    for ip in "${ips[@]}"; do
        if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ||
                "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
            echo "Invalid DNS address: $ip"
            return 1
        fi
    done
}

apply_dns() {
    local dns="$1" mode iface conn
    validate_dns_list "$dns" || return 1
    mode="$(detect_backend)"

    echo "DNS backend: $mode"
    backup_now

    case "$mode" in
        systemd-resolved)
            mkdir -p "$(dirname "$DROPIN")"
            {
                echo "[Resolve]"
                echo "DNS=$dns"
                echo "FallbackDNS=1.1.1.1 9.9.9.9"
                echo "Domains=~."
            } > "$DROPIN"
            systemctl restart systemd-resolved
            ;;
        NetworkManager)
            conn="$(nmcli -t -f NAME,DEVICE connection show --active |
                awk -F: '$2!="" {print $1; exit}')"
            [[ -n "$conn" ]] || {
                echo "No active NetworkManager connection."
                return 1
            }
            nmcli connection modify "$conn" \
                ipv4.ignore-auto-dns yes ipv4.dns "$dns"
            echo "Saved DNS to connection: $conn"
            echo "Live activation may require a reconnect."
            ;;
        netplan)
            echo "Netplan is present but is not necessarily the active DNS resolver."
            echo "Automatic Netplan edits are disabled to protect SSH and existing routes."
            echo "No DNS change was made. Edit the existing YAML nameservers configuration,"
            echo "then use 'sudo netplan try' from a maintenance session."
            return 1
            ;;
        *)
            echo "Unknown/static DNS backend; refusing to overwrite /etc/resolv.conf."
            return 1
            ;;
    esac

    if getent ahosts ubuntu.com >/dev/null 2>&1; then
        echo "DNS verification: PASS"
    else
        echo "DNS verification failed. Review backup: $BACKUP_ROOT"
        return 1
    fi
}

manual_dns() {
    local dns
    echo "Enter DNS servers separated by spaces."
    echo "Example: 1.1.1.1 1.0.0.1"
    read -r -p "DNS: " dns
    apply_dns "$dns"
}

apply_recommended_dns() {
    local dns
    if [[ ! -s "$BACKUP_ROOT/recommended-dns" ]]; then
        echo "Run DNS benchmark first."
        return
    fi
    dns="$(cat "$BACKUP_ROOT/recommended-dns")"
    echo "Recommended DNS: $dns"
    read -r -p "Apply this DNS? Type YES: " answer
    [[ "$answer" == YES ]] || { echo "Cancelled."; return; }
    apply_dns "$dns"
}

# ---------- MTU ----------

validate_mtu() {
    [[ "$1" =~ ^[0-9]+$ ]] &&
        (( "$1" >= 576 && "$1" <= 9216 ))
}

detect_best_mtu() {
    local iface mtu target size low high mid payload result
    iface="$(get_iface)"
    [[ -n "$iface" ]] || { echo "No default-route interface found."; return; }
    mtu="$(get_mtu "$iface")"
    echo "Interface: $iface"
    echo "Current MTU: $mtu"

    if ! has ping; then
        echo "ping is unavailable; install iputils-ping."
        return
    fi

    echo "Testing common public endpoint using ICMP; ICMP may be filtered."
    target="1.1.1.1"
    low=576
    high=1500

    while (( low < high )); do
        mid=$(( (low + high + 1) / 2 ))
        payload=$((mid - 28))
        if ping -n -c 1 -W 2 -M do -s "$payload" "$target" \
            >/dev/null 2>&1; then
            low="$mid"
        else
            high=$((mid - 1))
        fi
    done

    echo "Largest MTU passing this ICMP test: $low"
    echo "This is only an estimate: ICMP filtering or the route can affect the result."
    echo "Do not apply automatically on a remote production server."
}

apply_mtu() {
    local iface mtu mode conn
    iface="$(get_iface)"
    [[ -n "$iface" ]] || { echo "No default-route interface found."; return; }

    read -r -p "Interface [$iface]: " input_iface
    [[ -n "$input_iface" ]] && iface="$input_iface"
    [[ -e "/sys/class/net/$iface/mtu" ]] ||
        { echo "Interface not found."; return; }

    read -r -p "New MTU (576-9216): " mtu
    validate_mtu "$mtu" || { echo "Invalid MTU."; return; }

    echo "Interface: $iface"
    echo "Current MTU: $(get_mtu "$iface")"
    echo "Requested MTU: $mtu"
    echo "Changing MTU may disrupt network connectivity."
    read -r -p "Type APPLY to continue: " answer
    [[ "$answer" == APPLY ]] || { echo "Cancelled."; return; }

    backup_now
    mode="$(detect_backend)"

    # Apply a temporary MTU first.
    ip link set dev "$iface" mtu "$mtu"

    case "$mode" in
        NetworkManager)
            conn="$(nmcli -t -f NAME,DEVICE connection show --active |
                awk -F: -v i="$iface" '$2==i {print $1; exit}')"
            if [[ -n "$conn" ]]; then
                nmcli connection modify "$conn" 802-3-ethernet.mtu "$mtu" ||
                    echo "Warning: could not save permanent MTU in NetworkManager."
            else
                echo "Warning: no active NetworkManager profile found for $iface."
            fi
            ;;
        systemd-resolved)
            echo "DNS backend is systemd-resolved; MTU persistence depends on the network manager."
            echo "Temporary MTU applied only. Configure MTU in Netplan/NetworkManager for persistence."
            ;;
        netplan)
            echo "Temporary MTU applied. Permanent Netplan editing is intentionally not automatic."
            echo "Add 'mtu: $mtu' under the correct interface in the existing Netplan YAML."
            ;;
        *)
            echo "Temporary MTU applied only; permanent backend is unknown."
            ;;
    esac

    echo "Current MTU after change: $(get_mtu "$iface")"
}

# ---------- Main menu ----------

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
            5) apply_mtu; pause ;;
            6) backup_now; pause ;;
            7) restore_backup; pause ;;
            8) list_backups; pause ;;
            9) apply_recommended_dns; pause ;;
            0) exit 0 ;;
            *) echo "Invalid option." ;;
        esac
    done
}

is_root
main_menu
