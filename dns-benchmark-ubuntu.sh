#!/usr/bin/env bash
# ==============================================================================
# Project: AKDNS System Manager (v2.2.0 - Zero-Disk-Bloat Edition)
# Description: Enterprise-grade DNS & MTU Management, Benchmarking, and
#              Diagnostics Tool for Ubuntu Server (20.04 / 22.04 / 24.04+)
# Safety Rule: Strictly OS-level networking. Zero touch on Xray/Marzban configs.
# Disk Policy: No log files, no CSV files written to disk. Auto-pruned backups.
# ==============================================================================

umask 0077
export LC_ALL=C

# --- Global Constants & Directories ---
readonly VERSION="2.2.0-lean"
readonly SCRIPT_NAME="akdns-manager.sh"
readonly BASE_DIR="/var/lib/akdns"
readonly BACKUP_DIR="${BASE_DIR}/backups"
readonly STATE_FILE="${BASE_DIR}/last_operation.state"
readonly RESOLVED_DROPIN_DIR="/etc/systemd/resolved.conf.d"
readonly RESOLVED_DROPIN_FILE="${RESOLVED_DROPIN_DIR}/90-akdns.conf"
readonly MAX_BACKUPS=3

# --- In-Memory Session Log (RAM Only - Zero Disk Usage) ---
declare -a SESSION_LOGS=()

# --- Runtime Flags ---
DRY_RUN=0
ASSUME_YES=0

# --- Colors & Formatting ---
if [[ -t 1 ]]; then
    readonly C_RESET="\033[0m"
    readonly C_RED="\033[1;31m"
    readonly C_GREEN="\033[1;32m"
    readonly C_YELLOW="\033[1;33m"
    readonly C_BLUE="\033[1;34m"
    readonly C_CYAN="\033[1;36m"
    readonly C_BOLD="\033[1m"
else
    readonly C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN="" C_BOLD=""
fi

# --- System State Variables ---
SYS_DISTRO_NAME="unknown"
SYS_DISTRO_VER="unknown"
SYS_DISTRO_ID="unknown"
SYS_INIT="unknown"
SYS_BASH_VER="${BASH_VERSION:-unknown}"
SYS_IS_ROOT=0

NET_PRIMARY_IFACE="unknown"
NET_IPV4="not available"
NET_IPV6="not available"
NET_GATEWAY="unknown"
NET_CURRENT_MTU="unknown"
NET_PERSISTENT_MTU="unknown"

DNS_RUNTIME_BACKEND="unknown"
DNS_PERSISTENT_BACKEND="unknown"
DNS_NETPLAN_RENDERER="unknown"
DNS_NETPLAN_MAIN_FILE="none"
DNS_CLOUD_INIT_ACTIVE="no"
DNS_RESOLV_TARGET="unknown"
DNS_RESOLV_TYPE="unknown"

DNS_CURRENT_ACTIVE="unknown"
DNS_PER_LINK="unknown"
DNS_PERSISTENT_CFG="unknown"
DNS_DHCP_SERVERS="not available"
DNS_FALLBACK_SERVERS="unknown"

# --- Public DNS Resolvers Database ---
readonly PUBLIC_RESOLVERS=(
    "Cloudflare|1.1.1.1|1.0.0.1|high|none"
    "Google|8.8.8.8|8.8.4.4|standard|none"
    "Quad9|9.9.9.9|149.112.112.112|high|security"
    "AdGuard|94.140.14.14|94.140.15.15|high|adblock"
    "OpenDNS|208.67.222.222|208.67.220.220|standard|security"
    "CleanBrowsing|185.228.168.9|185.228.169.9|high|security"
    "ControlD|76.76.2.0|76.76.10.0|high|none"
)

readonly BENCHMARK_DOMAINS=(
    "google.com"
    "cloudflare.com"
    "ubuntu.com"
    "github.com"
)

# ==============================================================================
# Section 1: Core Utilities, In-Memory Logging & Safety Guards
# ==============================================================================

init_storage() {
    if [[ $EUID -eq 0 ]]; then
        mkdir -p "$BACKUP_DIR" 2>/dev/null
        chmod 700 "$BASE_DIR" "$BACKUP_DIR" 2>/dev/null
        # Clean up any legacy log/CSV directories from older script versions to free disk space
        if [[ -d "/var/log/akdns" ]]; then
            rm -rf "/var/log/akdns" 2>/dev/null
        fi
    fi
}

log_msg() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    SESSION_LOGS+=("[${ts}] [${level}] ${msg}")
    # Keep RAM array capped at 100 entries
    if (( ${#SESSION_LOGS[@]} > 100 )); then
        SESSION_LOGS=("${SESSION_LOGS[@]:1}")
    fi
}

record_operation() {
    local op_name="$1"
    local status="$2"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    log_msg "OPERATION" "${op_name} -> ${status}"
    if [[ $EUID -eq 0 && -d "$BASE_DIR" ]]; then
        printf "%s | %s (%s)\n" "$ts" "$op_name" "$status" > "$STATE_FILE"
    fi
}

print_info() { printf "${C_BLUE}[INFO]${C_RESET} %s\n" "$*"; log_msg "INFO" "$*"; }
print_ok()   { printf "${C_GREEN}[OK]${C_RESET} %s\n" "$*"; log_msg "OK" "$*"; }
print_warn() { printf "${C_YELLOW}[WARN]${C_RESET} %s\n" "$*"; log_msg "WARN" "$*"; }
print_err()  { printf "${C_RED}[ERROR]${C_RESET} %s\n" "$*" >&2; log_msg "ERROR" "$*"; }

confirm_action() {
    local prompt="${1:-Are you sure you want to proceed?}"
    if [[ $ASSUME_YES -eq 1 ]]; then
        return 0
    fi
    local ans
    printf "${C_YELLOW}[CONFIRM]${C_RESET} %s [y/N]: " "$prompt"
    read -r ans
    case "$ans" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) print_info "Operation cancelled by user."; return 1 ;;
    esac
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        print_err "This operation requires root privileges. Please run with sudo or as root."
        return 1
    fi
    return 0
}

check_not_dry_run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        print_warn "DRY-RUN MODE ACTIVE: No actual changes will be written to the system."
        return 1
    fi
    return 0
}

prune_old_backups() {
    [[ ! -d "$BACKUP_DIR" ]] && return 0
    local -a b_dirs=()
    while IFS= read -r -d '' d; do
        b_dirs+=("$d")
    done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)

    local total=${#b_dirs[@]}
    if (( total > MAX_BACKUPS )); then
        local to_delete=$(( total - MAX_BACKUPS ))
        local i
        for (( i=0; i<to_delete; i++ )); do
            rm -rf "${b_dirs[$i]}" 2>/dev/null
        done
    fi
}

# ==============================================================================
# Section 2: Validation & Dependency Management
# ==============================================================================

is_valid_ipv4() {
    local ip="$1"
    local IFS='.'
    local -a octets
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    read -r -a octets <<< "$ip"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    local o
    for o in "${octets[@]}"; do
        [[ "$o" =~ ^[0-9]+$ ]] || return 1
        if [[ ${#o} -gt 1 && "${o:0:1}" == "0" ]]; then return 1; fi
        (( o >= 0 && o <= 255 )) || return 1
    done
    [[ "$ip" == "0.0.0.0" || "$ip" == "255.255.255.255" ]] && return 1
    return 0
}

is_valid_ipv6() {
    local ip="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import ipaddress, sys; ip = ipaddress.IPv6Address(sys.argv[1]); sys.exit(0 if not (ip.is_unspecified or ip.is_multicast) else 1)" "$ip" 2>/dev/null
        return $?
    fi
    [[ "$ip" =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]] && [[ "$ip" != "::" ]]
}

is_valid_ip() {
    is_valid_ipv4 "$1" || is_valid_ipv6 "$1"
}

check_dependencies() {
    local -a missing_pkgs=()
    local -a missing_bins=()

    if ! command -v dig >/dev/null 2>&1; then
        missing_bins+=("dig")
        missing_pkgs+=("dnsutils")
    fi
    if ! command -v ip >/dev/null 2>&1; then
        missing_bins+=("ip")
        missing_pkgs+=("iproute2")
    fi
    if ! command -v ping >/dev/null 2>&1; then
        missing_bins+=("ping")
        missing_pkgs+=("iputils-ping")
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        missing_bins+=("python3")
        missing_pkgs+=("python3")
    else
        if ! python3 -c "import yaml" 2>/dev/null; then
            missing_bins+=("python3-yaml")
            missing_pkgs+=("python3-yaml")
        fi
    fi

    if [[ ${#missing_bins[@]} -gt 0 ]]; then
        print_warn "Missing recommended tools/libraries: ${missing_bins[*]}"
        if [[ $EUID -eq 0 ]]; then
            if confirm_action "Would you like to install (${missing_pkgs[*]}) via apt-get now?"; then
                apt-get update -y && apt-get install -y "${missing_pkgs[@]}"
                return $?
            else
                print_warn "Proceeding without installing missing packages."
                return 1
            fi
        else
            print_warn "Run as root to allow installation of: ${missing_pkgs[*]}"
            return 1
        fi
    fi
    return 0
}

# ==============================================================================
# Section 3: Comprehensive System & Network Detection
# ==============================================================================

detect_system() {
    [[ $EUID -eq 0 ]] && SYS_IS_ROOT=1 || SYS_IS_ROOT=0

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        SYS_DISTRO_NAME="${NAME:-Ubuntu}"
        SYS_DISTRO_VER="${VERSION_ID:-unknown}"
        SYS_DISTRO_ID="${ID:-ubuntu}"
    fi

    if [[ -d /run/systemd/system ]]; then
        SYS_INIT="systemd"
    elif [[ -f /sbin/init && "$(readlink -f /sbin/init 2>/dev/null)" == *systemd* ]]; then
        SYS_INIT="systemd"
    else
        SYS_INIT="other/unknown"
    fi

    if command -v ip >/dev/null 2>&1; then
        NET_PRIMARY_IFACE="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
        if [[ -z "$NET_PRIMARY_IFACE" ]]; then
            NET_PRIMARY_IFACE="$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
        fi
        [[ -z "$NET_PRIMARY_IFACE" ]] && NET_PRIMARY_IFACE="unknown"

        if [[ "$NET_PRIMARY_IFACE" != "unknown" ]]; then
            NET_GATEWAY="$(ip -4 route show default dev "$NET_PRIMARY_IFACE" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}')"
            [[ -z "$NET_GATEWAY" ]] && NET_GATEWAY="unknown"

            NET_IPV4="$(ip -4 -o addr show dev "$NET_PRIMARY_IFACE" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | paste -sd ' ' -)"
            [[ -z "$NET_IPV4" ]] && NET_IPV4="not available"

            NET_IPV6="$(ip -6 -o addr show dev "$NET_PRIMARY_IFACE" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | paste -sd ' ' -)"
            [[ -z "$NET_IPV6" ]] && NET_IPV6="not available"

            NET_CURRENT_MTU="$(ip link show dev "$NET_PRIMARY_IFACE" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="mtu") {print $(i+1); exit}}')"
            [[ -z "$NET_CURRENT_MTU" ]] && NET_CURRENT_MTU="unknown"
        fi
    fi

    if [[ -L /etc/resolv.conf ]]; then
        DNS_RESOLV_TARGET="$(readlink -f /etc/resolv.conf 2>/dev/null || readlink /etc/resolv.conf 2>/dev/null)"
        DNS_RESOLV_TYPE="symlink -> ${DNS_RESOLV_TARGET}"
    elif [[ -f /etc/resolv.conf ]]; then
        DNS_RESOLV_TARGET="/etc/resolv.conf"
        if grep -qi "Generated by NetworkManager" /etc/resolv.conf 2>/dev/null; then
            DNS_RESOLV_TYPE="regular file (Generated by NetworkManager)"
        elif grep -qi "systemd-resolved" /etc/resolv.conf 2>/dev/null; then
            DNS_RESOLV_TYPE="regular file (systemd-resolved header)"
        elif grep -qi "resolvconf" /etc/resolv.conf 2>/dev/null; then
            DNS_RESOLV_TYPE="regular file (resolvconf)"
        else
            DNS_RESOLV_TYPE="static regular file"
        fi
    else
        DNS_RESOLV_TARGET="missing"
        DNS_RESOLV_TYPE="missing"
    fi

    local resolved_active=0 nm_active=0 networkd_active=0
    if [[ "$SYS_INIT" == "systemd" ]]; then
        systemctl is-active --quiet systemd-resolved 2>/dev/null && resolved_active=1
        systemctl is-active --quiet NetworkManager 2>/dev/null && nm_active=1
        systemctl is-active --quiet systemd-networkd 2>/dev/null && networkd_active=1
    fi

    if [[ $resolved_active -eq 1 && "$DNS_RESOLV_TARGET" == *"/systemd/resolve/"* ]]; then
        DNS_RUNTIME_BACKEND="systemd-resolved"
    elif [[ $nm_active -eq 1 && "$DNS_RESOLV_TYPE" == *"NetworkManager"* ]]; then
        DNS_RUNTIME_BACKEND="NetworkManager"
    elif [[ $resolved_active -eq 1 ]] && grep -qE '^\s*nameserver\s+127\.0\.0\.53' /etc/resolv.conf 2>/dev/null; then
        DNS_RUNTIME_BACKEND="systemd-resolved"
    elif [[ "$DNS_RESOLV_TYPE" == "static regular file" ]]; then
        DNS_RUNTIME_BACKEND="static-resolv.conf"
    else
        DNS_RUNTIME_BACKEND="unknown"
    fi

    DNS_NETPLAN_MAIN_FILE="none"
    DNS_NETPLAN_RENDERER="unknown"
    DNS_CLOUD_INIT_ACTIVE="no"

    if [[ -d /etc/netplan ]]; then
        local -a np_files=()
        while IFS= read -r -d '' f; do
            np_files+=("$f")
        done < <(find /etc/netplan -maxdepth 1 -type f \( -name "*.yaml" -o -name "*.yml" \) -print0 2>/dev/null | sort -z)

        if [[ ${#np_files[@]} -gt 0 ]]; then
            DNS_NETPLAN_MAIN_FILE="${np_files[0]}"
            for f in "${np_files[@]}"; do
                if grep -qi "cloud-init" "$f" 2>/dev/null || [[ "$(basename "$f")" == *"cloud-init"* ]]; then
                    DNS_CLOUD_INIT_ACTIVE="yes (managed in $(basename "$f"))"
                fi
                if [[ "$NET_PRIMARY_IFACE" != "unknown" ]] && grep -q "$NET_PRIMARY_IFACE" "$f" 2>/dev/null; then
                    DNS_NETPLAN_MAIN_FILE="$f"
                fi
            done

            if command -v python3 >/dev/null 2>&1; then
                DNS_NETPLAN_RENDERER="$(python3 -c '
import sys, yaml
try:
    with open(sys.argv[1], "r") as f:
        data = yaml.safe_load(f) or {}
    net = data.get("network", {})
    r = net.get("renderer", "")
    if not r:
        eths = net.get("ethernets", {})
        if sys.argv[2] in eths and "renderer" in eths[sys.argv[2]]:
            r = eths[sys.argv[2]]["renderer"]
    print(r if r else "networkd (default)")
except Exception:
    print("unknown")
' "$DNS_NETPLAN_MAIN_FILE" "$NET_PRIMARY_IFACE" 2>/dev/null)"
            fi
        fi
    fi

    if [[ "$DNS_NETPLAN_MAIN_FILE" != "none" && -f "$DNS_NETPLAN_MAIN_FILE" ]]; then
        if [[ "$DNS_NETPLAN_RENDERER" == *"NetworkManager"* && $nm_active -eq 1 ]]; then
            DNS_PERSISTENT_BACKEND="netplan (renderer: NetworkManager)"
        elif [[ $networkd_active -eq 1 || "$DNS_NETPLAN_RENDERER" == *"networkd"* ]]; then
            DNS_PERSISTENT_BACKEND="netplan (renderer: systemd-networkd)"
        else
            DNS_PERSISTENT_BACKEND="netplan"
        fi
    elif [[ $nm_active -eq 1 ]]; then
        DNS_PERSISTENT_BACKEND="NetworkManager"
    elif [[ $networkd_active -eq 1 ]]; then
        DNS_PERSISTENT_BACKEND="systemd-networkd"
    elif [[ "$DNS_RUNTIME_BACKEND" == "static-resolv.conf" ]]; then
        DNS_PERSISTENT_BACKEND="static-resolv.conf"
    else
        DNS_PERSISTENT_BACKEND="unknown"
    fi

    extract_detailed_dns_and_mtu
}

extract_detailed_dns_and_mtu() {
    DNS_CURRENT_ACTIVE="unknown"
    DNS_PER_LINK="not available"
    DNS_DHCP_SERVERS="not available"
    DNS_FALLBACK_SERVERS="unknown"
    DNS_PERSISTENT_CFG="not configured"
    NET_PERSISTENT_MTU="not configured"

    if [[ "$DNS_RUNTIME_BACKEND" == "systemd-resolved" ]] && command -v resolvectl >/dev/null 2>&1; then
        DNS_CURRENT_ACTIVE="$(resolvectl dns 2>/dev/null | awk -F': ' 'NF>1 && $2!="" {print $2}' | tr '\n' ' ' | xargs)"
        if [[ "$NET_PRIMARY_IFACE" != "unknown" ]]; then
            DNS_PER_LINK="$(resolvectl dns "$NET_PRIMARY_IFACE" 2>/dev/null | awk -F': ' 'NF>1 {print $2}' | xargs)"
            [[ -z "$DNS_PER_LINK" ]] && DNS_PER_LINK="none"
        fi
        DNS_FALLBACK_SERVERS="$(resolvectl status 2>/dev/null | awk '/Fallback DNS Servers:/ {for(i=4;i<=NF;i++) printf "%s ", $i; while(getline && $0 ~ /^[[:space:]]+[0-9a-fA-F.:]+$/){printf "%s ", $1}} END{print ""}' | xargs)"
        [[ -z "$DNS_FALLBACK_SERVERS" ]] && DNS_FALLBACK_SERVERS="none"
    fi

    if [[ -z "$DNS_CURRENT_ACTIVE" || "$DNS_CURRENT_ACTIVE" == "unknown" ]]; then
        if [[ -f /etc/resolv.conf ]]; then
            DNS_CURRENT_ACTIVE="$(awk '/^[[:space:]]*nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf 2>/dev/null | paste -sd ' ' -)"
            [[ -z "$DNS_CURRENT_ACTIVE" ]] && DNS_CURRENT_ACTIVE="none"
        fi
    fi

    if [[ "$NET_PRIMARY_IFACE" != "unknown" ]]; then
        local ifindex
        ifindex="$(cat "/sys/class/net/${NET_PRIMARY_IFACE}/ifindex" 2>/dev/null)"
        if [[ -n "$ifindex" && -f "/run/systemd/netif/leases/${ifindex}" ]]; then
            DNS_DHCP_SERVERS="$(awk -F= '/^DNS=/ {print $2}' "/run/systemd/netif/leases/${ifindex}" 2>/dev/null)"
        elif command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
            DNS_DHCP_SERVERS="$(nmcli -t -f IP4.DNS dev show "$NET_PRIMARY_IFACE" 2>/dev/null | awk -F: '{print $2}' | paste -sd ' ' -)"
        fi
        [[ -z "$DNS_DHCP_SERVERS" ]] && DNS_DHCP_SERVERS="not available"
    fi

    local np_dns="" np_mtu=""
    if [[ "$DNS_NETPLAN_MAIN_FILE" != "none" && -f "$DNS_NETPLAN_MAIN_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        read -r np_dns np_mtu < <(python3 -c '
import sys, yaml
try:
    with open(sys.argv[1], "r") as f:
        data = yaml.safe_load(f) or {}
    eths = data.get("network", {}).get("ethernets", {})
    iface = sys.argv[2]
    target = eths.get(iface, {})
    if not target and len(eths) == 1:
        target = list(eths.values())[0]
    addrs = target.get("nameservers", {}).get("addresses", [])
    dns_str = ",".join(str(x) for x in addrs) if addrs else "none"
    mtu_str = str(target.get("mtu", "none"))
    print(f"{dns_str} {mtu_str}")
except Exception:
    print("unknown unknown")
' "$DNS_NETPLAN_MAIN_FILE" "$NET_PRIMARY_IFACE" 2>/dev/null)
        np_dns="${np_dns//,/ }"
    fi

    local dropin_dns=""
    if [[ -f "$RESOLVED_DROPIN_FILE" ]]; then
        dropin_dns="$(awk -F= '/^[[:space:]]*DNS=/ {print $2}' "$RESOLVED_DROPIN_FILE" 2>/dev/null | xargs)"
    fi

    if [[ -n "$np_dns" && "$np_dns" != "none" && "$np_dns" != "unknown" ]]; then
        DNS_PERSISTENT_CFG="netplan: ${np_dns}"
    fi
    if [[ -n "$dropin_dns" ]]; then
        if [[ "$DNS_PERSISTENT_CFG" != "not configured" ]]; then
            DNS_PERSISTENT_CFG="${DNS_PERSISTENT_CFG} | resolved-dropin: ${dropin_dns}"
        else
            DNS_PERSISTENT_CFG="resolved-dropin: ${dropin_dns}"
        fi
    fi

    if [[ -n "$np_mtu" && "$np_mtu" != "none" && "$np_mtu" != "unknown" ]]; then
        NET_PERSISTENT_MTU="$np_mtu (netplan)"
    elif command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
        local nm_mtu
        nm_mtu="$(nmcli -g 802-3-ethernet.mtu connection show --active 2>/dev/null | head -n1)"
        if [[ -n "$nm_mtu" && "$nm_mtu" != "0" && "$nm_mtu" != "auto" ]]; then
            NET_PERSISTENT_MTU="${nm_mtu} (NetworkManager)"
        fi
    fi
}

# ==============================================================================
# Section 4: System Status Display
# ==============================================================================

show_system_status() {
    detect_system

    local b_count=0
    local b_last="never"
    if [[ -d "$BACKUP_DIR" ]]; then
        b_count="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
        if (( b_count > 0 )); then
            local latest_dir
            latest_dir="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1)"
            b_last="$(basename "$latest_dir")"
        fi
    fi

    local last_op="none recorded"
    if [[ -f "$STATE_FILE" ]]; then
        last_op="$(tail -n 1 "$STATE_FILE" 2>/dev/null)"
    fi

    printf "\n${C_CYAN}================ AKDNS System Status ================${C_RESET}\n"
    printf "Distro:                  %s %s\n" "$SYS_DISTRO_NAME" "$SYS_DISTRO_VER"
    printf "Distro ID:               %s\n" "$SYS_DISTRO_ID"
    printf "Bash version:            %s\n" "$SYS_BASH_VER"
    printf "Init system:             %s\n" "$SYS_INIT"
    printf "Root privileges:         %s\n" "$([[ $SYS_IS_ROOT -eq 1 ]] && echo "yes" || echo "no (read-only)")"
    printf "DNS backend (runtime):   %s\n" "$DNS_RUNTIME_BACKEND"
    printf "DNS backend (persist):   %s\n" "$DNS_PERSISTENT_BACKEND"
    printf "Cloud-init network mgmt: %s\n" "$DNS_CLOUD_INIT_ACTIVE"
    printf "Current Active DNS:      %s\n" "$DNS_CURRENT_ACTIVE"
    printf "Per-link DNS (%s):     %s\n" "$NET_PRIMARY_IFACE" "$DNS_PER_LINK"
    printf "Persistent DNS config:   %s\n" "$DNS_PERSISTENT_CFG"
    printf "DHCP DNS:                %s\n" "$DNS_DHCP_SERVERS"
    printf "Fallback DNS:            %s\n" "$DNS_FALLBACK_SERVERS"
    printf "Primary interface:       %s\n" "$NET_PRIMARY_IFACE"
    printf "IPv4 address:            %s\n" "$NET_IPV4"
    printf "IPv6 address:            %s\n" "$NET_IPV6"
    printf "Gateway:                 %s\n" "$NET_GATEWAY"
    printf "Current MTU (runtime):   %s\n" "$NET_CURRENT_MTU"
    printf "Persistent MTU:          %s\n" "$NET_PERSISTENT_MTU"
    printf "resolv.conf target:      %s\n" "$DNS_RESOLV_TYPE"
    printf "Backup count:            %s (Max Auto-Cap: %s)\n" "$b_count" "$MAX_BACKUPS"
    printf "Last backup:             %s\n" "$b_last"
    printf "Last operation:          %s\n" "$last_op"
    printf "${C_CYAN}=====================================================${C_RESET}\n\n"
}

# ==============================================================================
# Section 5: Lightweight Auto-Pruned Backup & Restore Engine
# ==============================================================================

create_backup() {
    local op_reason="${1:-manual_backup}"
    require_root || return 1
    detect_system

    local ts
    ts="$(date '+%Y%m%d_%H%M%S')"
    local target_dir="${BACKUP_DIR}/${ts}_${op_reason// /_}"

    if ! check_not_dry_run; then
        print_info "[DRY-RUN] Would create backup in: ${target_dir}"
        return 0
    fi

    mkdir -p "${target_dir}/netplan" "${target_dir}/resolved.conf.d" "${target_dir}/nm_connections" "${target_dir}/etc" || {
        print_err "Failed to create backup directory at ${target_dir}"
        return 1
    }
    chmod 700 "$target_dir"

    [[ -d /etc/netplan ]] && cp -a /etc/netplan/. "${target_dir}/netplan/" 2>/dev/null
    [[ -f /etc/systemd/resolved.conf ]] && cp -a /etc/systemd/resolved.conf "${target_dir}/etc/resolved.conf" 2>/dev/null
    [[ -d /etc/systemd/resolved.conf.d ]] && cp -a /etc/systemd/resolved.conf.d/. "${target_dir}/resolved.conf.d/" 2>/dev/null
    [[ -d /etc/NetworkManager/system-connections ]] && cp -a /etc/NetworkManager/system-connections/. "${target_dir}/nm_connections/" 2>/dev/null

    if [[ -L /etc/resolv.conf ]]; then
        readlink /etc/resolv.conf > "${target_dir}/resolv_symlink.target"
    elif [[ -f /etc/resolv.conf ]]; then
        cp -a /etc/resolv.conf "${target_dir}/etc/resolv.conf.file"
    fi

    cat <<EOF > "${target_dir}/metadata.env"
BACKUP_TIMESTAMP="${ts}"
BACKUP_REASON="${op_reason}"
PRIMARY_IFACE="${NET_PRIMARY_IFACE}"
RUNTIME_MTU="${NET_CURRENT_MTU}"
PERSISTENT_MTU="${NET_PERSISTENT_MTU}"
RUNTIME_BACKEND="${DNS_RUNTIME_BACKEND}"
PERSISTENT_BACKEND="${DNS_PERSISTENT_BACKEND}"
ACTIVE_DNS="${DNS_CURRENT_ACTIVE}"
PER_LINK_DNS="${DNS_PER_LINK}"
EOF
    chmod 600 "${target_dir}/metadata.env"

    # Automatically delete older backups beyond MAX_BACKUPS (3) to prevent disk usage growth
    prune_old_backups

    print_ok "Backup snapshot created: $(basename "$target_dir") (Auto-capped at ${MAX_BACKUPS} snapshots)"
    record_operation "Backup (${op_reason})" "SUCCESS"
    echo "$target_dir"
    return 0
}

list_backups() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        print_info "No backup directory found."
        return 0
    fi

    local -a b_dirs=()
    while IFS= read -r -d '' d; do
        b_dirs+=("$d")
    done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z -r)

    if [[ ${#b_dirs[@]} -eq 0 ]]; then
        print_info "No backups available."
        return 0
    fi

    printf "\n${C_BOLD}%-4s %-20s %-20s %-10s %-10s %-25s${C_RESET}\n" "ID" "Timestamp" "Reason" "Iface" "MTU" "Active DNS (at backup)"
    printf "%s\n" "----------------------------------------------------------------------------------------------"

    local idx=1 d
    for d in "${b_dirs[@]}"; do
        local b_ts="unknown" b_reason="unknown" b_if="?" b_mtu="?" b_dns="?"
        if [[ -f "${d}/metadata.env" ]]; then
            b_ts="$(awk -F'"' '/^BACKUP_TIMESTAMP=/ {print $2}' "${d}/metadata.env")"
            b_reason="$(awk -F'"' '/^BACKUP_REASON=/ {print $2}' "${d}/metadata.env")"
            b_if="$(awk -F'"' '/^PRIMARY_IFACE=/ {print $2}' "${d}/metadata.env")"
            b_mtu="$(awk -F'"' '/^RUNTIME_MTU=/ {print $2}' "${d}/metadata.env")"
            b_dns="$(awk -F'"' '/^ACTIVE_DNS=/ {print $2}' "${d}/metadata.env")"
        else
            b_ts="$(basename "$d")"
        fi
        printf "%-4d %-20s %-20s %-10s %-10s %-25s\n" "$idx" "$b_ts" "${b_reason:0:19}" "$b_if" "$b_mtu" "${b_dns:0:24}"
        ((idx++))
    done
    printf "\n"
}

compare_with_backup() {
    local target_dir="$1"
    if [[ -z "$target_dir" ]]; then
        list_backups
        printf "Enter Backup ID to compare with current system (or 0 to cancel): "
        local choice
        read -r choice
        [[ "$choice" == "0" || -z "$choice" ]] && return 0
        local -a b_dirs=()
        while IFS= read -r -d '' d; do b_dirs+=("$d"); done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z -r)
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#b_dirs[@]} )); then
            print_err "Invalid Backup ID."
            return 1
        fi
        target_dir="${b_dirs[$((choice-1))]}"
    fi

    detect_system
    printf "\n${C_CYAN}=== Comparing Current Configuration with Backup: $(basename "$target_dir") ===${C_RESET}\n"
    if [[ -f "${target_dir}/metadata.env" ]]; then
        local b_mtu b_dns
        b_mtu="$(awk -F'"' '/^RUNTIME_MTU=/ {print $2}' "${target_dir}/metadata.env")"
        b_dns="$(awk -F'"' '/^ACTIVE_DNS=/ {print $2}' "${target_dir}/metadata.env")"
        printf "  MTU:        Backup=[%s]  vs  Current=[%s]\n" "$b_mtu" "$NET_CURRENT_MTU"
        printf "  Active DNS: Backup=[%s]  vs  Current=[%s]\n\n" "$b_dns" "$DNS_CURRENT_ACTIVE"
    fi

    printf "${C_BOLD}[Netplan Configuration Diff]${C_RESET}\n"
    if [[ -d "${target_dir}/netplan" && -d /etc/netplan ]]; then
        diff -u "${target_dir}/netplan" /etc/netplan 2>/dev/null || true
    else
        echo "  No Netplan files to compare."
    fi

    printf "\n${C_BOLD}[systemd-resolved Drop-in Diff]${C_RESET}\n"
    if [[ -d "${target_dir}/resolved.conf.d" && -d /etc/systemd/resolved.conf.d ]]; then
        diff -u "${target_dir}/resolved.conf.d" /etc/systemd/resolved.conf.d 2>/dev/null || true
    else
        echo "  No systemd-resolved drop-ins to compare."
    fi
    printf "${C_CYAN}=========================================================================${C_RESET}\n"
}

restore_backup() {
    require_root || return 1
    local target_dir="$1"

    if [[ -z "$target_dir" ]]; then
        list_backups
        printf "Enter Backup ID to restore (or 0 to cancel): "
        local choice
        read -r choice
        [[ "$choice" == "0" || -z "$choice" ]] && return 0
        local -a b_dirs=()
        while IFS= read -r -d '' d; do b_dirs+=("$d"); done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z -r)
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#b_dirs[@]} )); then
            print_err "Invalid selection."
            return 1
        fi
        target_dir="${b_dirs[$((choice-1))]}"
    fi

    if [[ ! -d "$target_dir" || ! -f "${target_dir}/metadata.env" ]]; then
        print_err "Backup directory is corrupted or missing metadata.env: ${target_dir}"
        record_operation "Restore Backup" "FAILED (Corrupt Backup)"
        return 1
    fi

    compare_with_backup "$target_dir"
    if ! confirm_action "Restore configuration from $(basename "$target_dir")?"; then
        return 1
    fi

    check_not_dry_run || return 0

    local restore_errors=0

    if [[ -d "${target_dir}/netplan" ]]; then
        cp -a "${target_dir}/netplan/." /etc/netplan/ 2>/dev/null || ((restore_errors++))
        if command -v netplan >/dev/null 2>&1; then
            if netplan generate 2>/dev/null; then
                netplan apply 2>/dev/null || ((restore_errors++))
            else
                print_err "Restored Netplan files failed 'netplan generate' validation!"
                ((restore_errors++))
            fi
        fi
    fi

    if [[ -d "${target_dir}/resolved.conf.d" ]]; then
        if [[ ! -f "${target_dir}/resolved.conf.d/90-akdns.conf" && -f "$RESOLVED_DROPIN_FILE" ]]; then
            rm -f "$RESOLVED_DROPIN_FILE"
        fi
        cp -a "${target_dir}/resolved.conf.d/." /etc/systemd/resolved.conf.d/ 2>/dev/null || ((restore_errors++))
    fi

    if [[ -f "${target_dir}/resolv_symlink.target" ]]; then
        local sym_t
        sym_t="$(cat "${target_dir}/resolv_symlink.target")"
        ln -snf "$sym_t" /etc/resolv.conf 2>/dev/null || ((restore_errors++))
    elif [[ -f "${target_dir}/etc/resolv.conf.file" ]]; then
        rm -f /etc/resolv.conf 2>/dev/null
        cp -a "${target_dir}/etc/resolv.conf.file" /etc/resolv.conf 2>/dev/null || ((restore_errors++))
    fi

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        systemctl restart systemd-resolved 2>/dev/null || ((restore_errors++))
    fi

    local b_if b_mtu
    b_if="$(awk -F'"' '/^PRIMARY_IFACE=/ {print $2}' "${target_dir}/metadata.env")"
    b_mtu="$(awk -F'"' '/^RUNTIME_MTU=/ {print $2}' "${target_dir}/metadata.env")"
    if [[ -n "$b_if" && "$b_if" != "unknown" && "$b_mtu" =~ ^[0-9]+$ ]]; then
        ip link set dev "$b_if" mtu "$b_mtu" 2>/dev/null || ((restore_errors++))
    fi

    if (( restore_errors == 0 )); then
        print_ok "Restore completed successfully."
        record_operation "Restore ($(basename "$target_dir"))" "SUCCESS"
        return 0
    else
        print_warn "Restore completed with ${restore_errors} partial error(s). Please check System Status."
        record_operation "Restore ($(basename "$target_dir"))" "PARTIAL_FAILURE"
        return 1
    fi
}

# ==============================================================================
# Section 6: DNS Benchmark Engine (Fixed Dig Option Order & Zero Disk Writes)
# ==============================================================================

LAST_BENCHMARK_BEST_PROVIDER=""
LAST_BENCHMARK_BEST_IPV4_1=""
LAST_BENCHMARK_BEST_IPV4_2=""

run_dns_benchmark() {
    check_dependencies || {
        if ! command -v dig >/dev/null 2>&1; then
            print_err "'dig' command is required for accurate DNS benchmarking."
            return 1
        fi
    }

    local timeout_sec=2
    local retries=1
    local rounds=2
    local test_ipv6=0
    local pref_privacy="any"
    local pref_filter="any"
    local custom_resolvers=()

    if [[ "${1:-interactive}" == "interactive" ]]; then
        printf "\n${C_CYAN}--- DNS Benchmark Configuration ---${C_RESET}\n"
        printf "Query Timeout in seconds [default: 2]: "
        local in_t; read -r in_t
        [[ "$in_t" =~ ^[1-9][0-9]*$ ]] && timeout_sec="$in_t"

        printf "Number of test rounds per domain [default: 2]: "
        local in_r; read -r in_r
        [[ "$in_r" =~ ^[1-9][0-9]*$ ]] && rounds="$in_r"

        printf "Filter by Privacy (any / high) [default: any]: "
        local in_p; read -r in_p
        [[ "$in_p" == "high" ]] && pref_privacy="high"

        printf "Filter by Content Filtering (any / none / security / adblock) [default: any]: "
        local in_f; read -r in_f
        [[ "$in_f" =~ ^(none|security|adblock)$ ]] && pref_filter="$in_f"

        printf "Add custom DNS IPs to test (space-separated, or press Enter to skip): "
        local in_c; read -r in_c
        if [[ -n "$in_c" ]]; then
            local cip
            for cip in $in_c; do
                if is_valid_ipv4 "$cip"; then
                    custom_resolvers+=("Custom_${cip}|${cip}||custom|none")
                else
                    print_warn "Skipping invalid custom IP: ${cip}"
                fi
            done
        fi
    fi

    detect_system
    [[ "$NET_IPV6" != "not available" ]] && test_ipv6=1

    local -a all_entries=("${PUBLIC_RESOLVERS[@]}" "${custom_resolvers[@]}")

    LAST_BENCHMARK_BEST_PROVIDER=""
    LAST_BENCHMARK_BEST_IPV4_1=""
    LAST_BENCHMARK_BEST_IPV4_2=""
    local best_score=99999999

    printf "\n${C_BLUE}[INFO]${C_RESET} Running DNS benchmark across %d domains (%d rounds, timeout=%ds)...\n\n" "${#BENCHMARK_DOMAINS[@]}" "$rounds" "$timeout_sec"
    printf "${C_BOLD}%-15s %-16s %-8s %-7s %-7s %-7s %-7s %-8s %-8s %-12s${C_RESET}\n" \
        "Provider" "Resolver IP" "Success" "T/O" "Min" "Median" "Avg" "Jitter" "Cold/Wrm" "Verdict"
    printf "%s\n" "------------------------------------------------------------------------------------------------------"

    local entry
    for entry in "${all_entries[@]}"; do
        IFS='|' read -r prov ip1 ip2 priv filt <<< "$entry"

        if [[ "$pref_privacy" != "any" && "$priv" != "$pref_privacy" && "$priv" != "custom" ]]; then
            continue
        fi
        if [[ "$pref_filter" != "any" && "$filt" != "$pref_filter" ]]; then
            continue
        fi

        local -a valid_times=()
        local -a cold_times=()
        local -a warm_times=()
        local total_q=0
        local success_q=0
        local timeout_q=0
        local bad_resp_q=0

        local r d qtype
        for (( r=1; r<=rounds; r++ )); do
            for d in "${BENCHMARK_DOMAINS[@]}"; do
                for qtype in A $([[ $test_ipv6 -eq 1 ]] && echo "AAAA"); do
                    ((total_q++))
                    local dig_out=""
                    local dig_rc=0
                    # CRITICAL FIX: '+noall' MUST come BEFORE '+answer +comments +stats'
                    # Otherwise '+noall' wipes out the '+stats' section (Query time)!
                    dig_out="$(dig @"${ip1}" "$d" "$qtype" +tries="$retries" +time="$timeout_sec" +noall +answer +comments +stats 2>&1)" || dig_rc=$?

                    if [[ $dig_rc -eq 9 ]] || grep -qiE "connection timed out|communications error|network unreachable|no servers could be reached" <<< "$dig_out"; then
                        ((timeout_q++))
                        continue
                    elif [[ $dig_rc -ne 0 ]]; then
                        ((bad_resp_q++))
                        continue
                    fi

                    local r_status=""
                    if [[ "$dig_out" =~ status:[[:space:]]*([A-Z]+), ]]; then
                        r_status="${BASH_REMATCH[1]}"
                    fi

                    local q_time=""
                    if [[ "$dig_out" =~ Query[[:space:]]+time:[[:space:]]*([0-9]+)[[:space:]]*msec ]]; then
                        q_time="${BASH_REMATCH[1]}"
                    fi

                    local ans_count=0
                    if [[ "$dig_out" =~ ANSWER:[[:space:]]*([0-9]+) ]]; then
                        ans_count="${BASH_REMATCH[1]}"
                    fi

                    if [[ "$r_status" == "NOERROR" && "$ans_count" -gt 0 && "$q_time" =~ ^[0-9]+$ ]]; then
                        ((success_q++))
                        valid_times+=("$q_time")
                        if (( r == 1 )); then
                            cold_times+=("$q_time")
                        else
                            warm_times+=("$q_time")
                        fi
                    else
                        ((bad_resp_q++))
                    fi
                done
            done
        done

        local s_rate=0
        (( total_q > 0 )) && s_rate=$(( (success_q * 100) / total_q ))

        local min_ms="N/A" max_ms="N/A" avg_ms="N/A" med_ms="N/A" jitter_ms="N/A"
        local cold_avg="N/A" warm_avg="N/A"
        local verdict="UNRELIABLE"
        local score="N/A"

        if (( ${#valid_times[@]} > 0 )); then
            local -a sorted=()
            mapfile -t sorted < <(printf "%s\n" "${valid_times[@]}" | sort -n)
            local cnt=${#sorted[@]}
            min_ms="${sorted[0]}"
            max_ms="${sorted[$((cnt-1))]}"

            local sum=0 t
            for t in "${sorted[@]}"; do (( sum += t )); done
            avg_ms=$(( sum / cnt ))

            if (( cnt % 2 == 1 )); then
                med_ms="${sorted[$((cnt/2))]}"
            else
                med_ms=$(( (sorted[cnt/2 - 1] + sorted[cnt/2]) / 2 ))
            fi

            local dev_sum=0 diff_val
            for t in "${sorted[@]}"; do
                diff_val=$(( t - avg_ms ))
                (( diff_val < 0 )) && diff_val=$(( -diff_val ))
                (( dev_sum += diff_val ))
            done
            jitter_ms=$(( dev_sum / cnt ))

            if (( ${#cold_times[@]} > 0 )); then
                local c_sum=0
                for t in "${cold_times[@]}"; do (( c_sum += t )); done
                cold_avg=$(( c_sum / ${#cold_times[@]} ))
            fi
            if (( ${#warm_times[@]} > 0 )); then
                local w_sum=0
                for t in "${warm_times[@]}"; do (( w_sum += t )); done
                warm_avg=$(( w_sum / ${#warm_times[@]} ))
            fi

            if (( s_rate >= 75 && cnt >= 4 )); then
                verdict="HEALTHY"
                local loss_penalty=$(( (100 - s_rate) * 15 ))
                score=$(( (med_ms * 5) + (avg_ms * 2) + (jitter_ms * 3) + loss_penalty ))
                if (( jitter_ms > avg_ms && avg_ms > 20 )); then
                    verdict="HIGH-JITTER"
                fi
                if (( score < best_score )); then
                    best_score=$score
                    LAST_BENCHMARK_BEST_PROVIDER="$prov"
                    LAST_BENCHMARK_BEST_IPV4_1="$ip1"
                    LAST_BENCHMARK_BEST_IPV4_2="$ip2"
                fi
            else
                verdict="DEGRADED"
            fi
        else
            verdict="UNREACHABLE"
        fi

        printf "%-15s %-16s %-8s %-7d %-7s %-7s %-7s %-8s %-8s %-12s\n" \
            "${prov:0:14}" "$ip1" "${s_rate}%" "$timeout_q" \
            "${min_ms}" "${med_ms}" "${avg_ms}" "${jitter_ms}" \
            "${cold_avg}/${warm_avg}" "$verdict"
    done

    printf "%s\n" "------------------------------------------------------------------------------------------------------"
    if [[ -n "$LAST_BENCHMARK_BEST_IPV4_1" ]]; then
        printf "${C_GREEN}[RECOMMENDED]${C_RESET} Best Performing DNS: ${C_BOLD}%s${C_RESET} (%s %s)\n" \
            "$LAST_BENCHMARK_BEST_PROVIDER" "$LAST_BENCHMARK_BEST_IPV4_1" "$LAST_BENCHMARK_BEST_IPV4_2"
    else
        printf "${C_RED}[ALERT]${C_RESET} No DNS resolver met the minimum reliability threshold (>=75%% success). No automatic DNS change is advised.\n"
    fi
    record_operation "DNS Benchmark" "SUCCESS"
    return 0
}

# ==============================================================================
# Section 7: DNS Management & Safe Application (Backend-Aware)
# ==============================================================================

verify_dns_resolution() {
    local test_ip="${1:-}"
    if command -v dig >/dev/null 2>&1; then
        if [[ -n "$test_ip" ]]; then
            dig @"$test_ip" cloudflare.com A +time=2 +tries=1 +short >/dev/null 2>&1 && return 0
        else
            dig cloudflare.com A +time=2 +tries=1 +short >/dev/null 2>&1 && return 0
            dig google.com A +time=2 +tries=1 +short >/dev/null 2>&1 && return 0
        fi
        return 1
    elif command -v getent >/dev/null 2>&1; then
        getent hosts cloudflare.com >/dev/null 2>&1 && return 0
        return 1
    fi
    return 0
}

update_netplan_yaml_safely() {
    local yaml_file="$1"
    local iface="$2"
    local mode="$3"
    local value="$4"
    local out_tmp="$5"

    python3 - "$yaml_file" "$iface" "$mode" "$value" "$out_tmp" << 'PYEOF'
import sys, yaml

yaml_file, iface, mode, value, out_tmp = sys.argv[1:6]

with open(yaml_file, 'r') as f:
    data = yaml.safe_load(f) or {}

if 'network' not in data or not isinstance(data['network'], dict):
    sys.exit(2)

net = data['network']
target_dict = None

for section in ('ethernets', 'bonds', 'bridges', 'vlans'):
    if section in net and isinstance(net[section], dict):
        if iface in net[section]:
            target_dict = net[section][iface]
            break

if target_dict is None and 'ethernets' in net and len(net['ethernets']) == 1:
    only_key = list(net['ethernets'].keys())[0]
    target_dict = net['ethernets'][only_key]

if target_dict is None or not isinstance(target_dict, dict):
    sys.exit(3)

if mode == "dns":
    ips = [x.strip() for x in value.split() if x.strip()]
    if 'nameservers' not in target_dict or not isinstance(target_dict['nameservers'], dict):
        target_dict['nameservers'] = {}
    target_dict['nameservers']['addresses'] = ips
elif mode == "mtu":
    target_dict['mtu'] = int(value)

with open(out_tmp, 'w') as f:
    yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
PYEOF
}

apply_dns_servers() {
    require_root || return 1
    local dns_list="$*"
    if [[ -z "$dns_list" ]]; then
        print_err "No DNS servers provided."
        return 1
    fi

    detect_system

    if [[ "$DNS_RUNTIME_BACKEND" == "unknown" && "$DNS_PERSISTENT_BACKEND" == "unknown" ]]; then
        print_err "Network/DNS backend is 'unknown'. Refusing to modify system configuration blindly."
        record_operation "Apply DNS" "ABORTED (Unknown Backend)"
        return 1
    fi

    if [[ "$DNS_CLOUD_INIT_ACTIVE" == yes* ]]; then
        print_warn "Cloud-init network management detected: ${DNS_CLOUD_INIT_ACTIVE}"
    fi

    printf "\n${C_CYAN}--- Proposed DNS Configuration ---${C_RESET}\n"
    printf "Target DNS Servers:    %s\n" "$dns_list"
    printf "Runtime Backend:       %s\n" "$DNS_RUNTIME_BACKEND"
    printf "Persistent Backend:    %s\n" "$DNS_PERSISTENT_BACKEND"
    printf "Target Interface:      %s\n" "$NET_PRIMARY_IFACE"

    local tmp_dropin
    tmp_dropin="$(mktemp /tmp/akdns_resolved.XXXXXX)"
    cat <<EOF > "$tmp_dropin"
# Managed by AKDNS System Manager
[Resolve]
DNS=${dns_list}
EOF

    local tmp_netplan=""
    local update_np=0
    if [[ "$DNS_PERSISTENT_BACKEND" == netplan* && -f "$DNS_NETPLAN_MAIN_FILE" ]]; then
        tmp_netplan="$(mktemp /tmp/akdns_netplan.XXXXXX)"
        if update_netplan_yaml_safely "$DNS_NETPLAN_MAIN_FILE" "$NET_PRIMARY_IFACE" "dns" "$dns_list" "$tmp_netplan"; then
            update_np=1
            printf "\n${C_BOLD}[Diff for %s]${C_RESET}\n" "$DNS_NETPLAN_MAIN_FILE"
            diff -u "$DNS_NETPLAN_MAIN_FILE" "$tmp_netplan" || true
        else
            print_warn "Could not safely locate interface '${NET_PRIMARY_IFACE}' inside ${DNS_NETPLAN_MAIN_FILE}. Skipping YAML edit."
            rm -f "$tmp_netplan"
        fi
    fi

    if [[ "$DNS_RUNTIME_BACKEND" == "systemd-resolved" ]]; then
        printf "\n${C_BOLD}[Diff for %s]${C_RESET}\n" "$RESOLVED_DROPIN_FILE"
        if [[ -f "$RESOLVED_DROPIN_FILE" ]]; then
            diff -u "$RESOLVED_DROPIN_FILE" "$tmp_dropin" || true
        else
            cat "$tmp_dropin"
        fi
    fi

    if ! confirm_action "Apply these DNS changes now?"; then
        rm -f "$tmp_dropin" "$tmp_netplan"
        return 1
    fi

    if ! check_not_dry_run; then
        rm -f "$tmp_dropin" "$tmp_netplan"
        return 0
    fi

    local backup_path
    backup_path="$(create_backup "pre_dns_change" | tail -n 1)"
    if [[ -z "$backup_path" || ! -d "$backup_path" ]]; then
        print_err "Mandatory backup failed! Aborting DNS modification."
        rm -f "$tmp_dropin" "$tmp_netplan"
        return 1
    fi

    local apply_err=0

    if [[ $update_np -eq 1 && -f "$tmp_netplan" ]]; then
        cp -f "$tmp_netplan" "$DNS_NETPLAN_MAIN_FILE"
        chmod 600 "$DNS_NETPLAN_MAIN_FILE"
        if ! netplan generate 2>/dev/null; then
            print_err "'netplan generate' failed validation! Rolling back immediately."
            restore_backup "$backup_path"
            rm -f "$tmp_dropin" "$tmp_netplan"
            return 1
        fi
    fi

    if [[ "$DNS_RUNTIME_BACKEND" == "systemd-resolved" ]]; then
        mkdir -p "$RESOLVED_DROPIN_DIR"
        cp -f "$tmp_dropin" "$RESOLVED_DROPIN_FILE"
        chmod 644 "$RESOLVED_DROPIN_FILE"
        if [[ "$NET_PRIMARY_IFACE" != "unknown" ]] && command -v resolvectl >/dev/null 2>&1; then
            # shellcheck disable=SC2086
            resolvectl dns "$NET_PRIMARY_IFACE" $dns_list 2>/dev/null || true
        fi
        systemctl restart systemd-resolved 2>/dev/null || ((apply_err++))
    elif [[ "$DNS_RUNTIME_BACKEND" == "NetworkManager" || "$DNS_PERSISTENT_BACKEND" == "NetworkManager" ]]; then
        local active_con
        active_con="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: -v dev="$NET_PRIMARY_IFACE" '$2==dev {print $1; exit}')"
        if [[ -n "$active_con" ]]; then
            nmcli connection modify "$active_con" ipv4.dns "$dns_list" ipv4.ignore-auto-dns yes 2>/dev/null || ((apply_err++))
            nmcli device reapply "$NET_PRIMARY_IFACE" 2>/dev/null || true
        else
            print_err "Could not identify active NetworkManager connection profile."
            ((apply_err++))
        fi
    elif [[ "$DNS_RUNTIME_BACKEND" == "static-resolv.conf" ]]; then
        {
            echo "# Generated by AKDNS System Manager"
            local ip
            for ip in $dns_list; do
                echo "nameserver ${ip}"
            done
        } > /etc/resolv.conf
        chmod 644 /etc/resolv.conf
    fi

    rm -f "$tmp_dropin" "$tmp_netplan"

    sleep 1
    if (( apply_err == 0 )) && verify_dns_resolution; then
        print_ok "DNS successfully updated and verified ($dns_list)."
        record_operation "Set DNS ($dns_list)" "SUCCESS"
        return 0
    else
        print_err "Post-application DNS verification failed! Initiating automatic rollback..."
        restore_backup "$backup_path"
        record_operation "Set DNS ($dns_list)" "FAILED_ROLLED_BACK"
        return 1
    fi
}

set_dns_automatically() {
    require_root || return 1
    print_info "Running DNS Benchmark to determine the optimal resolver for this server..."
    run_dns_benchmark "auto" || return 1

    if [[ -z "$LAST_BENCHMARK_BEST_IPV4_1" ]]; then
        print_err "Benchmark did not find any reliable DNS server. No changes will be made."
        return 1
    fi

    local target_ips="${LAST_BENCHMARK_BEST_IPV4_1}"
    [[ -n "$LAST_BENCHMARK_BEST_IPV4_2" ]] && target_ips="${target_ips} ${LAST_BENCHMARK_BEST_IPV4_2}"

    printf "\nRecommended Provider: ${C_BOLD}%s${C_RESET} (%s)\n" "$LAST_BENCHMARK_BEST_PROVIDER" "$target_ips"
    apply_dns_servers "$target_ips"
}

set_dns_manually() {
    require_root || return 1
    printf "\n${C_CYAN}--- Manual DNS Configuration ---${C_RESET}\n"
    printf "Enter Primary DNS (IPv4 or IPv6): "
    local dns1; read -r dns1
    if ! is_valid_ip "$dns1"; then
        print_err "Invalid IP address format: '${dns1}'"
        return 1
    fi

    printf "Enter Secondary DNS (optional, press Enter to skip): "
    local dns2; read -r dns2
    local final_dns="$dns1"
    if [[ -n "$dns2" ]]; then
        if ! is_valid_ip "$dns2"; then
            print_err "Invalid Secondary IP address format: '${dns2}'"
            return 1
        fi
        if [[ "$dns1" == "$dns2" ]]; then
            print_warn "Secondary DNS is identical to Primary DNS. Keeping single entry."
        else
            final_dns="${dns1} ${dns2}"
        fi
    fi

    if ! verify_dns_resolution "$dns1"; then
        print_warn "Primary DNS (${dns1}) did not respond to a test query right now."
        if ! confirm_action "Do you still want to force applying this unresponsive DNS?"; then
            return 1
        fi
    fi

    apply_dns_servers "$final_dns"
}

reset_dns_previous() {
    require_root || return 1
    local latest_dir
    latest_dir="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1)"
    if [[ -z "$latest_dir" ]]; then
        print_err "No previous backup found to reset DNS."
        return 1
    fi
    print_info "Resetting DNS to most recent backup: $(basename "$latest_dir")"
    restore_backup "$latest_dir"
}

# ==============================================================================
# Section 8: Path MTU Discovery (DF-bit Probing) & Safe MTU Management
# ==============================================================================

probe_payload_df() {
    local target="$1"
    local proto="$2"
    local payload="$3"
    local success=0
    local i

    for i in 1 2 3; do
        if [[ "$proto" == "4" ]]; then
            if ping -4 -M do -s "$payload" -c 1 -W 1 "$target" >/dev/null 2>&1; then
                ((success++))
            fi
        else
            if ping -6 -M do -s "$payload" -c 1 -W 1 "$target" >/dev/null 2>&1; then
                ((success++))
            fi
        fi
        (( success >= 2 )) && return 0
    done
    return 1
}

detect_best_mtu() {
    detect_system
    local iface="$NET_PRIMARY_IFACE"
    printf "\n${C_CYAN}--- Path MTU Discovery (PMTU Probing) ---${C_RESET}\n"
    printf "Primary Interface: %s (Current MTU: %s, Persistent: %s)\n" "$iface" "$NET_CURRENT_MTU" "$NET_PERSISTENT_MTU"

    printf "Enter target IP for MTU path probing [default: 1.1.1.1]: "
    local target_ip; read -r target_ip
    [[ -z "$target_ip" ]] && target_ip="1.1.1.1"

    local proto=4
    local header_size=28
    local min_mtu=576
    local max_mtu=1500

    if is_valid_ipv6 "$target_ip"; then
        proto=6
        header_size=48
        min_mtu=1280
    elif ! is_valid_ipv4 "$target_ip"; then
        print_err "Invalid target IP address: ${target_ip}"
        return 1
    fi

    if [[ "$NET_CURRENT_MTU" =~ ^[0-9]+$ ]] && (( NET_CURRENT_MTU > 1500 )); then
        max_mtu="$NET_CURRENT_MTU"
    fi

    print_info "Testing baseline ICMP reachability to ${target_ip} (IPv${proto}, Header=${header_size}B)..."
    local base_payload=$(( min_mtu - header_size ))
    if ! probe_payload_df "$target_ip" "$proto" "$base_payload"; then
        print_warn "Result: INCONCLUSIVE. Target ${target_ip} does not respond to baseline DF-ping (${min_mtu}B) or ICMP is blocked."
        return 1
    fi

    local low="$base_payload"
    local high=$(( max_mtu - header_size ))
    local best_payload="$low"

    print_info "Performing binary search with Don't Fragment (DF) bit enabled (Range: ${min_mtu}..${max_mtu} bytes)..."
    while (( low <= high )); do
        local mid=$(( (low + high) / 2 ))
        printf "  Probing payload=%d bytes (Total Frame MTU=%d)... " "$mid" "$((mid + header_size))"
        if probe_payload_df "$target_ip" "$proto" "$mid"; then
            printf "${C_GREEN}PASS${C_RESET}\n"
            best_payload="$mid"
            low=$(( mid + 1 ))
        else
            printf "${C_YELLOW}FRAGMENT/DROP${C_RESET}\n"
            high=$(( mid - 1 ))
        fi
    done

    local discovered_mtu=$(( best_payload + header_size ))
    printf "\n${C_CYAN}================ MTU Discovery Summary ================${C_RESET}\n"
    printf "Probe Target:                %s (IPv%s)\n" "$target_ip" "$proto"
    printf "Header Overhead:             %d bytes (IP + ICMP)\n" "$header_size"
    printf "Max Unfragmented Payload:    %d bytes\n" "$best_payload"
    printf "Discovered Path MTU:         ${C_GREEN}%d${C_RESET} bytes\n" "$discovered_mtu"
    printf "${C_CYAN}=======================================================${C_RESET}\n"
    record_operation "Detect MTU (${discovered_mtu})" "SUCCESS"
    return 0
}

set_mtu_manually() {
    require_root || return 1
    detect_system

    printf "\n${C_CYAN}--- Manual MTU Configuration ---${C_RESET}\n"
    printf "Available network interfaces:\n"
    ip -o link show | awk -F': ' '{print "  - " $2}'
    printf "Enter target interface [default: %s]: " "$NET_PRIMARY_IFACE"
    local iface; read -r iface
    [[ -z "$iface" ]] && iface="$NET_PRIMARY_IFACE"

    if ! ip link show dev "$iface" >/dev/null 2>&1; then
        print_err "Interface '${iface}' does not exist."
        return 1
    fi

    printf "Enter desired MTU value (576 - 9000): "
    local new_mtu; read -r new_mtu
    if ! [[ "$new_mtu" =~ ^[0-9]+$ ]] || (( new_mtu < 576 || new_mtu > 9000 )); then
        print_err "Invalid MTU value '${new_mtu}'. Allowed safe range: 576 to 9000."
        return 1
    fi

    if (( new_mtu < 1280 )); then
        print_warn "WARNING: Setting MTU below 1280 bytes will disable IPv6!"
        confirm_action "Are you certain you want an MTU below 1280?" || return 1
    fi

    printf "Apply scope: [1] Runtime Only (Temporary)  [2] Both Runtime & Persistent: "
    local scope_choice; read -r scope_choice
    if [[ "$scope_choice" != "1" && "$scope_choice" != "2" ]]; then
        print_err "Invalid scope selection."
        return 1
    fi

    check_not_dry_run || return 0

    local backup_path
    backup_path="$(create_backup "pre_mtu_${new_mtu}" | tail -n 1)"
    if [[ -z "$backup_path" || ! -d "$backup_path" ]]; then
        print_err "Backup failed! Aborting MTU change."
        return 1
    fi

    print_info "Applying runtime MTU ${new_mtu} on ${iface}..."
    if ! ip link set dev "$iface" mtu "$new_mtu" 2>/dev/null; then
        print_err "Kernel rejected MTU ${new_mtu} on interface ${iface}."
        return 1
    fi

    sleep 1
    local health_ok=1
    if [[ "$NET_GATEWAY" != "unknown" ]]; then
        ping -4 -c 2 -W 1 "$NET_GATEWAY" >/dev/null 2>&1 || health_ok=0
    fi
    verify_dns_resolution || health_ok=0

    if [[ $health_ok -eq 0 ]]; then
        print_err "Connectivity check failed after changing MTU! Rolling back immediately..."
        restore_backup "$backup_path"
        return 1
    fi

    if [[ "$scope_choice" == "2" ]]; then
        if [[ "$DNS_PERSISTENT_BACKEND" == netplan* && -f "$DNS_NETPLAN_MAIN_FILE" ]]; then
            local tmp_np
            tmp_np="$(mktemp /tmp/akdns_mtu.XXXXXX)"
            if update_netplan_yaml_safely "$DNS_NETPLAN_MAIN_FILE" "$iface" "mtu" "$new_mtu" "$tmp_np"; then
                printf "\n${C_BOLD}[Diff for %s]${C_RESET}\n" "$DNS_NETPLAN_MAIN_FILE"
                diff -u "$DNS_NETPLAN_MAIN_FILE" "$tmp_np" || true
                if confirm_action "Write persistent MTU to Netplan configuration?"; then
                    cp -f "$tmp_np" "$DNS_NETPLAN_MAIN_FILE"
                    chmod 600 "$DNS_NETPLAN_MAIN_FILE"
                    if ! netplan generate 2>/dev/null; then
                        print_err "netplan generate failed! Reverting file."
                        restore_backup "$backup_path"
                        rm -f "$tmp_np"
                        return 1
                    fi
                fi
            else
                print_warn "Could not update Netplan YAML automatically for interface ${iface}."
            fi
            rm -f "$tmp_np"
        elif [[ "$DNS_PERSISTENT_BACKEND" == "NetworkManager" ]]; then
            local active_con
            active_con="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: -v dev="$iface" '$2==dev {print $1; exit}')"
            if [[ -n "$active_con" ]]; then
                nmcli connection modify "$active_con" 802-3-ethernet.mtu "$new_mtu" 2>/dev/null || true
            fi
        fi
    fi

    print_ok "MTU on ${iface} successfully set to ${new_mtu}."
    record_operation "Set MTU (${iface}=${new_mtu})" "SUCCESS"
    return 0
}

restore_mtu_previous() {
    require_root || return 1
    local latest_dir
    latest_dir="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1)"
    if [[ -z "$latest_dir" || ! -f "${latest_dir}/metadata.env" ]]; then
        print_err "No backup metadata available to restore MTU."
        return 1
    fi
    restore_backup "$latest_dir"
}

# ==============================================================================
# Section 9: Diagnostics, Connectivity Tests & Session Logs
# ==============================================================================

dns_connectivity_test() {
    detect_system
    printf "\n${C_CYAN}--- Comprehensive DNS Connectivity Test ---${C_RESET}\n"
    local -a test_servers=()
    local s
    for s in $DNS_CURRENT_ACTIVE 1.1.1.1 8.8.8.8 9.9.9.9; do
        is_valid_ip "$s" && test_servers+=("$s")
    done

    printf "${C_BOLD}%-18s %-12s %-12s %-15s %-10s${C_RESET}\n" "Server" "UDP/53" "TCP/53" "Resolution" "Latency"
    printf "%s\n" "-------------------------------------------------------------------------"

    local srv
    for srv in "${test_servers[@]}"; do
        local udp_st="FAIL" tcp_st="FAIL" res_st="FAIL" lat="N/A"
        local out_u out_t
        if command -v dig >/dev/null 2>&1; then
            out_u="$(dig @"$srv" cloudflare.com A +notcp +time=2 +tries=1 +noall +answer +comments +stats 2>/dev/null)"
            if grep -q "status: NOERROR" <<< "$out_u"; then
                udp_st="OK"
                res_st="OK"
                if [[ "$out_u" =~ Query[[:space:]]+time:[[:space:]]*([0-9]+)[[:space:]]*msec ]]; then
                    lat="${BASH_REMATCH[1]} ms"
                fi
            fi
            out_t="$(dig @"$srv" cloudflare.com A +tcp +time=2 +tries=1 +noall +comments 2>/dev/null)"
            grep -q "status: NOERROR" <<< "$out_t" && tcp_st="OK"
        fi
        printf "%-18s %-12s %-12s %-15s %-10s\n" "$srv" "$udp_st" "$tcp_st" "$res_st" "$lat"
    done
    printf "\n"
}

network_diagnostics() {
    detect_system
    printf "\n${C_CYAN}================ Network & Routing Diagnostics ================${C_RESET}\n"
    printf "${C_BOLD}1. Interface & Link Statistics (%s):${C_RESET}\n" "$NET_PRIMARY_IFACE"
    ip -s link show dev "$NET_PRIMARY_IFACE" 2>/dev/null || true

    printf "\n${C_BOLD}2. Routing Table (IPv4):${C_RESET}\n"
    ip -4 route show 2>/dev/null || true

    printf "\n${C_BOLD}3. Gateway Reachability (${NET_GATEWAY}):${C_RESET}\n"
    if [[ "$NET_GATEWAY" != "unknown" ]]; then
        ping -4 -c 3 -W 1 "$NET_GATEWAY" 2>/dev/null || print_warn "Gateway did not respond to ICMP echo."
    else
        echo "No IPv4 default gateway detected."
    fi

    printf "\n${C_BOLD}4. Public WAN Reachability (1.1.1.1):${C_RESET}\n"
    ping -4 -c 3 -W 1 1.1.1.1 2>/dev/null || print_warn "1.1.1.1 unreachable via ICMP."

    printf "\n${C_BOLD}5. Resolver Status Summary:${C_RESET}\n"
    if command -v resolvectl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        resolvectl status "$NET_PRIMARY_IFACE" 2>/dev/null || resolvectl status 2>/dev/null
    else
        cat /etc/resolv.conf 2>/dev/null
    fi
    printf "${C_CYAN}===============================================================${C_RESET}\n"
}

show_configuration_diff() {
    local latest_dir
    latest_dir="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1)"
    if [[ -z "$latest_dir" ]]; then
        print_info "No backups exist yet to diff against. Showing active configuration files instead:"
        [[ -f "$DNS_NETPLAN_MAIN_FILE" ]] && { printf "\n--- %s ---\n" "$DNS_NETPLAN_MAIN_FILE"; cat "$DNS_NETPLAN_MAIN_FILE"; }
        [[ -f "$RESOLVED_DROPIN_FILE" ]] && { printf "\n--- %s ---\n" "$RESOLVED_DROPIN_FILE"; cat "$RESOLVED_DROPIN_FILE"; }
        return 0
    fi
    compare_with_backup "$latest_dir"
}

view_logs() {
    printf "\n${C_CYAN}--- AKDNS In-Memory Session Logs (Zero Disk Usage) ---${C_RESET}\n"
    if (( ${#SESSION_LOGS[@]} > 0 )); then
        printf "%s\n" "${SESSION_LOGS[@]}"
    else
        print_info "No events logged in current session yet."
    fi
    printf "${C_CYAN}------------------------------------------------------${C_RESET}\n"
}

# ==============================================================================
# Section 10: Interactive Menu & CLI Argument Dispatcher
# ==============================================================================

show_menu() {
    printf "\n${C_BOLD}${C_CYAN}┌──────────────────────────────────────────────────────────┐${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}│          AKDNS System Manager (${VERSION})             │${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}│      Ubuntu Server DNS & MTU Reliability Controller      │${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}└──────────────────────────────────────────────────────────┘${C_RESET}\n"
    [[ $DRY_RUN -eq 1 ]] && printf "  ${C_YELLOW}[MODE: DRY-RUN / READ-ONLY SIMULATION]${C_RESET}\n"
    printf "  1.  System Status\n"
    printf "  2.  DNS Benchmark\n"
    printf "  3.  Set DNS Automatically (Benchmark-Driven)\n"
    printf "  4.  Set DNS Manually\n"
    printf "  5.  Reset DNS to Previous Configuration\n"
    printf "  6.  Detect Best MTU (DF-Bit Path Probing)\n"
    printf "  7.  Set MTU Manually\n"
    printf "  8.  Restore MTU\n"
    printf "  9.  Backup Current Configuration\n"
    printf "  10. Restore Backup\n"
    printf "  11. List Backups\n"
    printf "  12. Compare Current Configuration with Backup\n"
    printf "  13. DNS Connectivity Test\n"
    printf "  14. Network Diagnostics\n"
    printf "  15. Show Configuration Diff\n"
    printf "  16. View Session Logs (In-Memory)\n"
    printf "  17. Exit\n"
    printf "────────────────────────────────────────────────────────────\n"
}

main_loop() {
    init_storage
    detect_system

    while true; do
        show_menu
        printf "Select an option [1-17]: "
        local opt
        if ! read -r opt; then
            echo ""
            break
        fi
        case "$opt" in
            1)  show_system_status ;;
            2)  run_dns_benchmark "interactive" ;;
            3)  set_dns_automatically ;;
            4)  set_dns_manually ;;
            5)  reset_dns_previous ;;
            6)  detect_best_mtu ;;
            7)  set_mtu_manually ;;
            8)  restore_mtu_previous ;;
            9)  create_backup "user_manual" ;;
            10) restore_backup ;;
            11) list_backups ;;
            12) compare_with_backup ;;
            13) dns_connectivity_test ;;
            14) network_diagnostics ;;
            15) show_configuration_diff ;;
            16) view_logs ;;
            17|q|exit) print_info "Exiting AKDNS System Manager."; exit 0 ;;
            *)  print_warn "Invalid selection '${opt}'. Please enter a number between 1 and 17." ;;
        esac
    done
}

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]
Options:
  --dry-run       Run in safe simulation mode (no system files or settings modified)
  --status        Display System Status and exit
  --benchmark     Run DNS benchmark and exit
  --detect-mtu    Run Path MTU discovery and exit
  --help          Display this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=1; shift ;;
        --status)     init_storage; show_system_status; exit 0 ;;
        --benchmark)  init_storage; run_dns_benchmark "auto"; exit $? ;;
        --detect-mtu) init_storage; detect_best_mtu; exit $? ;;
        --help|-h)    usage; exit 0 ;;
        *)            print_err "Unknown parameter: $1"; usage; exit 1 ;;
    esac
done

main_loop
