#!/bin/bash
# MRM Manager ssl.sh v1.4.27

# ═══════════════════════════════════════════════════════════════════════════
# SSL MANAGEMENT MODULE v1.4.27
# ═══════════════════════════════════════════════════════════════════════════
# Author: MRM Manager Team
# License: GPL-3.0
# Requires: Bash 4.0+, certbot, openssl, curl
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Dependency missing
#   3 - Permission denied
#   4 - Network error
#   5 - Certificate error
# ═══════════════════════════════════════════════════════════════════════════

set -o pipefail

# ═══════════════════════════════════════════════════════════════════════════
# CONSTANTS & CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

# Version

# Guard against double-source (prevents "readonly: variable is read only" error)
if [[ -z "${_SSL_MODULE_INITIALIZED:-}" ]]; then
_SSL_MODULE_INITIALIZED=1

# Colors (not readonly: utils.sh exports the same names when both are sourced — MRM-036)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
ORANGE='\033[0;33m'
NC='\033[0m'
BOLD='\033[1m'

# Paths (can be overridden via environment)
readonly SSL_LOG_DIR="${SSL_LOG_DIR:-/var/log/ssl-manager}"
readonly SSL_LOG_FILE="${SSL_LOG_DIR}/ssl-manager.log"
readonly CERTBOT_DEBUG_LOG="${SSL_LOG_DIR}/certbot-debug.log"
readonly SERVERS_FILE="${SERVERS_FILE:-/opt/mrm-manager/ssl-servers.conf}"
readonly SSL_BACKUP_DIR="${SSL_BACKUP_DIR:-/opt/mrm-manager/ssl-backups}"
readonly CONFIG_DIR="${CONFIG_DIR:-/opt/mrm-manager}"

[ -r "$CONFIG_DIR/versions.conf" ] && source "$CONFIG_DIR/versions.conf"
SSL_VERSION="${SSL_VERSION:-1.0.9}"

# Thresholds
readonly EXPIRY_WARNING_DAYS=14
readonly EXPIRY_CRITICAL_DAYS=7

# Timeouts
readonly CURL_TIMEOUT=15
readonly SSH_TIMEOUT=10
readonly DNS_TIMEOUT=5

# Ports
readonly HTTP_PORT=80
readonly HTTPS_PORT=443

fi # end _SSL_MODULE_INITIALIZED guard

# ═══════════════════════════════════════════════════════════════════════════
# GLOBAL STATE
# ═══════════════════════════════════════════════════════════════════════════

declare -g PANEL_DIR="${PANEL_DIR:-}"
declare -g PANEL_DEF_CERTS="${PANEL_DEF_CERTS:-}"
declare -g PANEL_ENV="${PANEL_ENV:-}"
declare -g NODE_DIR="${NODE_DIR:-}"
declare -g NODE_DEF_CERTS="${NODE_DEF_CERTS:-}"
declare -g NODE_ENV="${NODE_ENV:-}"

# Service states - use local in functions when possible
declare -g _SERVICES_STOPPED=()
# Docker containers stopped for certificate work (MRM-037)
declare -g _CONTAINERS_STOPPED=()

# ═══════════════════════════════════════════════════════════════════════════
# LOAD EXTERNAL MODULES
# ═══════════════════════════════════════════════════════════════════════════

_load_external_modules() {
    local modules=("utils.sh" "ui.sh")
    local module path should_load
    for module in "${modules[@]}"; do
        path="${CONFIG_DIR}/${module}"
        should_load=false

        case "$module" in
            utils.sh)
                declare -f load_panel_config >/dev/null 2>&1 || should_load=true
                ;;
            ui.sh)
                declare -f ui_header >/dev/null 2>&1 || should_load=true
                ;;
        esac

        if [[ "$should_load" == "true" && -f "$path" && -r "$path" ]]; then
            # shellcheck source=/dev/null
            source "$path"
        fi
    done
}
_load_external_modules

# ═══════════════════════════════════════════════════════════════════════════
# UI FALLBACK FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

if ! declare -f ui_header >/dev/null 2>&1; then
    ui_header() {
        local title="$1"
        local width=58
        local line
        local padding

        printf -v line '%*s' "$width" ''
        line=${line// /═}
        padding=$(( (width - ${#title}) / 2 ))
        [ "$padding" -lt 1 ] && padding=1

        # FIX: only clear on a real terminal (MRM-034)
        if [ -t 1 ]; then
            clear
        fi
        echo -e "${CYAN}╔${line}╗${NC}"
        printf '%b║%*s%b%s%b%*s%b║%b\n' \
            "$CYAN" "$padding" '' "$BOLD" "$title" "$NC" \
            "$((width - padding - ${#title}))" '' "$CYAN" "$NC"
        echo -e "${CYAN}╚${line}╝${NC}"
        echo ""
    }
fi

if ! declare -f ui_error >/dev/null 2>&1; then
    ui_error() { echo -e "${RED}[✘] $1${NC}" >&2; }
fi

if ! declare -f ui_success >/dev/null 2>&1; then
    ui_success() { echo -e "${GREEN}[✔] $1${NC}"; }
fi

if ! declare -f ui_warning >/dev/null 2>&1; then
    ui_warning() { echo -e "${YELLOW}[⚠] $1${NC}"; }
fi

if ! declare -f ui_info >/dev/null 2>&1; then
    ui_info() { echo -e "${BLUE}[ℹ] $1${NC}"; }
fi

if ! declare -f pause >/dev/null 2>&1; then
    pause() {
        echo ""
        read -r -p "Press Enter to continue..."
    }
fi

# ═══════════════════════════════════════════════════════════════════════════
# LOGGING SYSTEM
# ═══════════════════════════════════════════════════════════════════════════

init_logging() {
    mkdir -p "$SSL_LOG_DIR" "$SSL_BACKUP_DIR" 2>/dev/null || {
        ui_error "Cannot create log directories"
        return 1
    }
    touch "$SSL_LOG_FILE" 2>/dev/null || return 1
    chmod 640 "$SSL_LOG_FILE" 2>/dev/null
}

log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$SSL_LOG_FILE" 2>/dev/null
}

log_info() { log_message "INFO" "$1"; }
log_error() { log_message "ERROR" "$1"; }
log_success() { log_message "SUCCESS" "$1"; }
log_warning() { log_message "WARNING" "$1"; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && log_message "DEBUG" "$1"; }

# ═══════════════════════════════════════════════════════════════════════════
# CLEANUP & SIGNAL HANDLING
# ═══════════════════════════════════════════════════════════════════════════

cleanup_on_exit() {
    local exit_code=$?
    
    # Restore all stopped services
    for service in "${_SERVICES_STOPPED[@]}"; do
        if [[ -n "$service" ]]; then
            systemctl start "$service" 2>/dev/null
            log_info "Restored service: $service"
        fi
    done
    _SERVICES_STOPPED=()
    
    # Restore stopped Docker containers (MRM-037)
    local container
    for container in "${_CONTAINERS_STOPPED[@]}"; do
        if [[ -n "$container" ]]; then
            docker start "$container" >/dev/null 2>&1
            log_info "Restored container: $container"
        fi
    done
    _CONTAINERS_STOPPED=()
    
    # Remove temp files
    rm -f /tmp/ssl-manager-*.tmp 2>/dev/null
    
    exit $exit_code
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ═══════════════════════════════════════════════════════════════════════════
# INPUT VALIDATION & SANITIZATION
# ═══════════════════════════════════════════════════════════════════════════

# Validate domain format (strict)
validate_domain() {
    local domain="$1"
    
    # Empty check
    [[ -z "$domain" ]] && return 1
    
    # Length check (max 253 chars)
    [[ ${#domain} -gt 253 ]] && return 1
    
    # Format check (RFC 1123)
    local pattern='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
    [[ "$domain" =~ $pattern ]]
}

# Validate email format
validate_email() {
    local email="$1"
    [[ -z "$email" ]] && return 1
    local pattern='^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
    [[ "$email" =~ $pattern ]]
}

# Validate path (prevent traversal)
validate_path() {
    local path="$1"
    
    # Check for traversal attempts
    [[ "$path" == *".."* ]] && return 1
    
    # Check for dangerous characters
    [[ "$path" =~ [[:cntrl:]] ]] && return 1
    
    # Must be absolute path
    [[ "$path" == /* ]] || return 1
    
    return 0
}

# Sanitize input (remove dangerous characters)
sanitize_input() {
    local input="$1"
    # Remove control chars, semicolons, pipes, backticks, etc.
    echo "$input" | tr -d '\000-\037' | sed 's/[;&|`$(){}[\]<>!]//g'
}

# Validate IP address
validate_ip() {
    local ip="$1"
    local pattern='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    
    if [[ ! "$ip" =~ $pattern ]]; then
        return 1
    fi
    
    # Check each octet
    IFS='.' read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        [[ "$octet" -gt 255 ]] && return 1
    done
    
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# DEPENDENCY CHECKING
# ═══════════════════════════════════════════════════════════════════════════

check_dependencies() {
    local -a missing=()
    local -a required=("certbot" "openssl" "curl" "ss")
    local -a optional=("dig" "jq")
    
    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        ui_error "Missing required dependencies: ${missing[*]}"
        echo -e "${YELLOW}Install with: apt install ${missing[*]}${NC}"
        return 2
    fi
    
    # Check optional
    for cmd in "${optional[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log_warning "Optional dependency missing: $cmd"
        fi
    done
    
    # Check bash version
    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
        ui_error "Bash 4.0+ required. Current: ${BASH_VERSION}"
        return 2
    fi
    
    return 0
}

# Check root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        ui_error "This script must be run as root"
        return 3
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# PANEL DETECTION
# ═══════════════════════════════════════════════════════════════════════════

detect_active_panel() {
    local panel_name=""

    if declare -f load_panel_config >/dev/null 2>&1; then
        if load_panel_config >/dev/null 2>&1; then
            panel_name=$(cat "$CONFIG_FILE" 2>/dev/null || true)
            if [[ -n "$panel_name" && -n "$PANEL_DIR" ]]; then
                echo "$panel_name"
                return 0
            fi
        fi
    fi

    local -A panels=(
        ["pasarguard"]="/opt/pasarguard:/var/lib/pasarguard/certs:/opt/pasarguard/.env:/opt/pg-node:/var/lib/pg-node/certs:/opt/pg-node/.env"
    )

    for panel in "${!panels[@]}"; do
        IFS=':' read -r dir certs env node_dir node_certs node_env <<< "${panels[$panel]}"
        if [[ -d "$dir" ]]; then
            PANEL_DIR="$dir"
            PANEL_DEF_CERTS="$certs"
            PANEL_ENV="$env"
            NODE_DIR="$node_dir"
            NODE_DEF_CERTS="$node_certs"
            NODE_ENV="$node_env"
            echo "$panel"
            return 0
        fi
    done

    # Default fallback (project is scoped to PasarGuard)
    PANEL_DIR="/opt/pasarguard"
    PANEL_DEF_CERTS="/var/lib/pasarguard/certs"
    PANEL_ENV="/opt/pasarguard/.env"
    NODE_DIR="/opt/pg-node"
    NODE_DEF_CERTS="/var/lib/pg-node/certs"
    NODE_ENV="/opt/pg-node/.env"
    echo "pasarguard"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# SERVICE MANAGEMENT (Centralized)
# ═══════════════════════════════════════════════════════════════════════════

# Stop a service and track it for restoration
stop_service() {
    local service="$1"
    
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        if systemctl stop "$service" 2>/dev/null; then
            _SERVICES_STOPPED+=("$service")
            log_info "Stopped service: $service"
            return 0
        else
            log_error "Failed to stop service: $service"
            return 1
        fi
    fi
    return 0
}

# Start a service
start_service() {
    local service="$1"
    
    if systemctl start "$service" 2>/dev/null; then
        # Remove from stopped list
        local -a new_list=()
        for s in "${_SERVICES_STOPPED[@]}"; do
            [[ "$s" != "$service" ]] && new_list+=("$s")
        done
        _SERVICES_STOPPED=("${new_list[@]}")
        log_info "Started service: $service"
        return 0
    fi
    return 1
}

# Stop web services for certbot
stop_web_services() {
    local stopped=0
    
    # 1) systemd-managed web servers
    for service in nginx apache2 httpd lighttpd; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            stop_service "$service" && stopped=$((stopped + 1))
        fi
    done
    
    # 2) Docker containers owning the challenge port (MRM-037)
    #    A container publishing :80 keeps an iptables DNAT rule that routes
    #    incoming HTTP traffic into the container even when the host port
    #    looks free — certbot --standalone would never see the Let's
    #    Encrypt HTTP-01 challenge. Such containers MUST be stopped.
    if _docker_available; then
        _stop_docker_listeners
    fi
    
    # 3) Last resort: non-container processes still on the port
    if command -v fuser &>/dev/null && _port_in_use "$HTTP_PORT"; then
        log_warning "Port $HTTP_PORT still busy after stopping known services — killing residual listener(s)"
        fuser -k "${HTTP_PORT}/tcp" 2>/dev/null
    fi
    
    # Wait for ports to be released
    sleep 2
    
    return 0
}

# ── Docker helpers (MRM-037) ────────────────────────────────────────────────

_docker_available() {
    command -v docker >/dev/null 2>&1 || return 1
    docker info >/dev/null 2>&1
}

# Map a host PID to its Docker container name (empty + rc 1 if not in a container)
_container_of_pid() {
    local pid="$1" cgroup cid
    cgroup=$(tr -s '[:space:]' '\n' < "/proc/$pid/cgroup" 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -1)
    [[ -n "$cgroup" ]] || return 1
    cid="${cgroup:0:12}"
    docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||'
}

# Stop containers that own the HTTP challenge port:
#  a) published :80 (Ports column) — DNAT keeps hijacking traffic
#  b) still listening on :80 after (a) — e.g. network_mode: host
_stop_docker_listeners() {
    local name ports
    while IFS='|' read -r name ports; do
        [[ -z "$name" ]] && continue
        if [[ "$ports" == *":${HTTP_PORT}->"* ]]; then
            if docker stop -t 10 "$name" >/dev/null 2>&1; then
                _CONTAINERS_STOPPED+=("$name")
                log_info "Stopped container (publishes :$HTTP_PORT): $name"
            fi
        fi
    done < <(docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null)
    
    local pids pid cname
    pids=$(ss -tlnp 2>/dev/null | awk -v p=":${HTTP_PORT}$" 'NR>1 && $4 ~ p' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
    for pid in $pids; do
        cname=$(_container_of_pid "$pid" 2>/dev/null) || cname=""
        if [[ -n "$cname" && " ${_CONTAINERS_STOPPED[*]:-} " != *" $cname "* ]]; then
            if docker stop -t 10 "$cname" >/dev/null 2>&1; then
                _CONTAINERS_STOPPED+=("$cname")
                log_info "Stopped container (host listener :$HTTP_PORT): $cname"
            fi
        fi
    done
}

# Restore all stopped services (systemd + Docker containers)
restore_services() {
    local -a services_to_restore=("${_SERVICES_STOPPED[@]}")
    
    for service in "${services_to_restore[@]}"; do
        start_service "$service"
    done
    
    # Containers: `docker start` (compose restart would fail on stopped
    # containers) — MRM-037
    local -a containers_to_restore=("${_CONTAINERS_STOPPED[@]}")
    _CONTAINERS_STOPPED=()
    
    local container
    for container in "${containers_to_restore[@]}"; do
        if docker start "$container" >/dev/null 2>&1; then
            log_info "Started container: $container"
        else
            log_error "Failed to start container: $container"
            echo -e "  ${RED}✘ Container $container did not start — run: docker start $container${NC}"
        fi
    done
}

# Get compose file for a service directory
get_compose_file_for_dir() {
    local target_dir="$1"
    local compose_file=""
    local candidate

    if [[ -z "$target_dir" || ! -d "$target_dir" ]]; then
        return 1
    fi

    if declare -f find_compose_file >/dev/null 2>&1; then
        compose_file=$(find_compose_file "$target_dir" 2>/dev/null) || true
    fi

    if [[ -z "$compose_file" ]]; then
        for candidate in \
            "$target_dir/docker-compose.yml" \
            "$target_dir/docker-compose.yaml" \
            "$target_dir/compose.yml" \
            "$target_dir/compose.yaml"
        do
            if [[ -f "$candidate" ]]; then
                compose_file="$candidate"
                break
            fi
        done
    fi

    [[ -n "$compose_file" ]] || return 1
    printf '%s\n' "$compose_file"
}

# Restart panel/node services
restart_panel_services() {
    local service_type="$1"  # panel or node
    local target_dir=""
    local compose_file=""

    case "$service_type" in
        panel) target_dir="$PANEL_DIR" ;;
        node)
            if [[ -n "$NODE_DIR" ]]; then
                target_dir="$NODE_DIR"
            elif [[ -n "$NODE_ENV" ]]; then
                target_dir="$(dirname "$NODE_ENV" 2>/dev/null)"
            fi
            ;;
        *) return 1 ;;
    esac

    [[ -d "$target_dir" ]] || return 1

    compose_file=$(get_compose_file_for_dir "$target_dir" 2>/dev/null) || true
    if [[ -n "$compose_file" ]]; then
        (cd "$target_dir" && docker compose restart 2>/dev/null) || \
        (cd "$target_dir" && docker-compose restart 2>/dev/null)
    else
        local service_name
        service_name=$(basename "$target_dir")
        systemctl restart "$service_name" 2>/dev/null
    fi
}

# Recreate a compose service so env_file changes take effect — `restart` reuses
# the existing container config, but env_file/environment is applied when the
# container is created (MRM-031)
recreate_service() {
    local service_type="$1"
    local target_dir="" compose_file="" service_name=""

    case "$service_type" in
        panel)
            target_dir="$PANEL_DIR"
            service_name="pasarguard"
            ;;
        node)
            target_dir="$NODE_DIR"
            service_name="node"
            ;;
        *) return 1 ;;
    esac

    [[ -d "$target_dir" ]] || return 1

    compose_file=$(get_compose_file_for_dir "$target_dir" 2>/dev/null) || true
    if [[ -n "$compose_file" ]]; then
        (cd "$target_dir" && docker compose up -d "$service_name" 2>/dev/null) || \
        (cd "$target_dir" && docker-compose up -d "$service_name" 2>/dev/null)
    else
        # systemd-managed fallback (e.g. node-serviced)
        systemctl restart "$(basename "$target_dir")" 2>/dev/null
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# PORT CHECKING
# ═══════════════════════════════════════════════════════════════════════════

# True (rc 0) when the TCP port has a local listener
_port_in_use() {
    local port="$1"
    ss -tlnp 2>/dev/null | awk -v p=":${port}$" 'NR>1 && $4 ~ p { found = 1 } END { exit !found }'
}

check_port_availability() {
    local port="$1"
    local max_retries="${2:-3}"
    local retry=0
    
    while [[ $retry -lt $max_retries ]]; do
        if ! _port_in_use "$port"; then
            return 0
        fi
        retry=$((retry + 1))
        sleep 1
    done
    
    local service
    service=$(ss -tlnp 2>/dev/null | awk -v p=":${port}$" 'NR>1 && $4 ~ p { print $NF; exit }')
    ui_warning "Port $port is in use by: ${service:-unknown process}"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════
# DNS VALIDATION
# ═══════════════════════════════════════════════════════════════════════════

is_ipv6_address() {
    local address="$1"

    [[ "$address" == *:* ]] || return 1
    [[ "$address" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    [[ "$address" != *":::"* ]] || return 1
    return 0
}

get_server_ipv4() {
    local endpoint candidate
    local -a endpoints=(
        "https://api.ipify.org"
        "https://icanhazip.com"
        "https://ifconfig.co/ip"
    )

    for endpoint in "${endpoints[@]}"; do
        candidate="$(curl -4 -fsS --connect-timeout "$DNS_TIMEOUT" --max-time "$DNS_TIMEOUT" "$endpoint" 2>/dev/null | tr -d '[:space:]')"
        if validate_ip "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done

    candidate="$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1 {split($4, address, "/"); print address[1]}')"
    if validate_ip "$candidate"; then
        echo "$candidate"
        return 0
    fi

    return 1
}

get_server_ipv6() {
    local endpoint candidate
    local -a endpoints=(
        "https://api64.ipify.org"
        "https://icanhazip.com"
        "https://ifconfig.co/ip"
    )

    for endpoint in "${endpoints[@]}"; do
        candidate="$(curl -6 -fsS --connect-timeout "$DNS_TIMEOUT" --max-time "$DNS_TIMEOUT" "$endpoint" 2>/dev/null | tr -d '[:space:]')"
        if is_ipv6_address "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done

    candidate="$(ip -6 -o addr show scope global 2>/dev/null | awk 'NR==1 {split($4, address, "/"); print address[1]}')"
    if is_ipv6_address "$candidate"; then
        echo "$candidate"
        return 0
    fi

    return 1
}

get_domain_ipv4() {
    local domain="$1"
    local addresses=""

    if command -v dig >/dev/null 2>&1; then
        addresses="$(dig +short +timeout="$DNS_TIMEOUT" "$domain" A 2>/dev/null | while IFS= read -r address; do validate_ip "$address" && echo "$address"; done)"
    fi

    if [[ -z "$addresses" ]]; then
        addresses="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | while IFS= read -r address; do validate_ip "$address" && echo "$address"; done)"
    fi

    printf '%s\n' "$addresses" | awk 'NF && !seen[$0]++'
}

get_domain_ipv6() {
    local domain="$1"
    local addresses=""

    if command -v dig >/dev/null 2>&1; then
        addresses="$(dig +short +timeout="$DNS_TIMEOUT" "$domain" AAAA 2>/dev/null | while IFS= read -r address; do is_ipv6_address "$address" && echo "$address"; done)"
    fi

    if [[ -z "$addresses" ]]; then
        addresses="$(getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1}' | while IFS= read -r address; do is_ipv6_address "$address" && echo "$address"; done)"
    fi

    printf '%s\n' "$addresses" | awk 'NF && !seen[$0]++'
}

all_records_match_server() {
    local server_address="$1"
    shift
    local dns_address

    for dns_address in "$@"; do
        [[ "$dns_address" == "$server_address" ]] || return 1
    done

    return 0
}

validate_domain_dns() {
    local domain="$1"
    local skip_mismatch="${2:-false}"
    local server_ipv4=""
    local server_ipv6=""
    local mismatch=false
    local -a domain_ipv4=()
    local -a domain_ipv6=()

    ui_info "Validating DNS for: $domain"

    mapfile -t domain_ipv4 < <(get_domain_ipv4 "$domain")
    mapfile -t domain_ipv6 < <(get_domain_ipv6 "$domain")

    if [[ ${#domain_ipv4[@]} -eq 0 && ${#domain_ipv6[@]} -eq 0 ]]; then
        ui_error "Cannot resolve A or AAAA record for: $domain"
        log_error "DNS resolution failed for $domain"
        return 1
    fi

    server_ipv4="$(get_server_ipv4 2>/dev/null || true)"
    server_ipv6="$(get_server_ipv6 2>/dev/null || true)"

    log_info "DNS Check - Domain: $domain, Server IPv4: ${server_ipv4:-none}, Server IPv6: ${server_ipv6:-none}, A: ${domain_ipv4[*]:-none}, AAAA: ${domain_ipv6[*]:-none}"

    if [[ ${#domain_ipv4[@]} -gt 0 ]]; then
        if [[ -z "$server_ipv4" ]]; then
            ui_error "Domain has an A record, but no public IPv4 was detected on this server."
            mismatch=true
        elif ! all_records_match_server "$server_ipv4" "${domain_ipv4[@]}"; then
            ui_error "One or more A records do not match this server's IPv4."
            mismatch=true
        fi
    fi

    if [[ ${#domain_ipv6[@]} -gt 0 ]]; then
        if [[ -z "$server_ipv6" ]]; then
            ui_error "Domain has an AAAA record, but no public IPv6 was detected on this server."
            mismatch=true
        elif ! all_records_match_server "$server_ipv6" "${domain_ipv6[@]}"; then
            ui_error "One or more AAAA records do not match this server's IPv6."
            mismatch=true
        fi
    fi

    if [[ "$mismatch" == "true" ]]; then
        echo -e "${YELLOW}A records:    ${domain_ipv4[*]:-none}${NC}"
        echo -e "${YELLOW}AAAA records: ${domain_ipv6[*]:-none}${NC}"
        echo -e "${YELLOW}Server IPv4:  ${server_ipv4:-none}${NC}"
        echo -e "${YELLOW}Server IPv6:  ${server_ipv6:-none}${NC}"
        log_warning "DNS mismatch for $domain"

        if [[ "$skip_mismatch" == "true" ]]; then
            return 1
        fi

        read -r -p "Continue anyway? (y/N): " response
        [[ "$response" =~ ^[Yy]$ ]] || return 1
        log_warning "User chose to continue despite DNS mismatch"
    fi

    if [[ ${#domain_ipv4[@]} -gt 0 && ${#domain_ipv6[@]} -gt 0 ]]; then
        ui_success "DNS OK: $domain (IPv4 and IPv6)"
    elif [[ ${#domain_ipv6[@]} -gt 0 ]]; then
        ui_success "DNS OK: $domain (IPv6)"
    else
        ui_success "DNS OK: $domain (IPv4)"
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# CERTIFICATE EXPIRY FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

# Get certificate expiry date
get_cert_expiry_date() {
    local cert_path="$1"
    
    [[ ! -f "$cert_path" ]] && echo "NOT_FOUND" && return 1
    
    openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2
}

# Get days until certificate expires
get_cert_days_remaining() {
    local cert_path="$1"
    
    [[ ! -f "$cert_path" ]] && echo "-999" && return 1
    
    local expiry_date expiry_epoch current_epoch
    expiry_date=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2)
    
    [[ -z "$expiry_date" ]] && echo "-999" && return 1
    
    # Use portable date parsing
    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null) || \
    expiry_epoch=$(date -j -f "%b %d %T %Y %Z" "$expiry_date" +%s 2>/dev/null)
    
    [[ -z "$expiry_epoch" ]] && echo "-999" && return 1
    
    current_epoch=$(date +%s)
    echo $(( (expiry_epoch - current_epoch) / 86400 ))
}

# Get certificate status based on days remaining
get_cert_status() {
    local days="$1"
    
    if [[ "$days" -le -999 ]]; then echo "UNKNOWN"
    elif [[ "$days" -lt 0 ]]; then echo "EXPIRED"
    elif [[ "$days" -le "$EXPIRY_CRITICAL_DAYS" ]]; then echo "CRITICAL"
    elif [[ "$days" -le "$EXPIRY_WARNING_DAYS" ]]; then echo "WARNING"
    else echo "VALID"
    fi
}

# Get color for status
get_status_color() {
    case "$1" in
        EXPIRED|CRITICAL) echo "$RED" ;;
        WARNING) echo "$YELLOW" ;;
        VALID) echo "$GREEN" ;;
        *) echo "$NC" ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════
# CERTIFICATE DISCOVERY
# ═══════════════════════════════════════════════════════════════════════════

# Get all certificates with their info
# Output format: source|domain|cert_path|days|status
# MRM-044: domain of the certificate referenced by a .env variable
# (UVICORN_SSL_CERTFILE for the panel, SSL_CERT_FILE for the node).
# Handles every layout: LE live dir, per-domain subdir, or the official
# flat <domain>.cer naming from the docs. Prints the domain; rc 1 unknown.
_env_cert_domain() {
    local env_file="$1" var_name="$2"
    [[ -f "$env_file" ]] || return 1
    local path
    path=$(grep -oE "^[[:space:]]*${var_name}[[:space:]]*=[[:space:]]*\"?[^\"]+" "$env_file" 2>/dev/null | head -1 | sed -E "s/^[^=]*=[[:space:]]*\"?//")
    [[ -n "$path" ]] || return 1
    local base
    base=$(basename "$path")
    if [[ "$base" == *.cer ]]; then
        printf '%s' "${base%.cer}"
        return 0
    fi
    local dom
    dom=$(basename "$(dirname "$path")")
    [[ -n "$dom" && "$dom" != "certs" ]] || return 1
    printf '%s' "$dom"
}

discover_all_certificates() {
    local -a results=()
    local -A seen_domains=()
    
    # 1. Let's Encrypt certificates
    if [[ -d "/etc/letsencrypt/live" ]]; then
        for dir in /etc/letsencrypt/live/*/; do
            [[ ! -d "$dir" ]] && continue
            local domain
            domain=$(basename "$dir")
            [[ "$domain" == "README" ]] && continue
            
            local cert_path="$dir/fullchain.pem"
            [[ ! -f "$cert_path" ]] && continue
            
            local days status
            days=$(get_cert_days_remaining "$cert_path")
            status=$(get_cert_status "$days")
            
            results+=("le|$domain|$cert_path|$days|$status")
            seen_domains["$domain"]=1
        done
    fi
    
    # 2. Panel certificates (not in LE)
    if [[ -d "$PANEL_DEF_CERTS" ]]; then
        for dir in "$PANEL_DEF_CERTS"/*/; do
            [[ ! -d "$dir" ]] && continue
            local domain
            domain=$(basename "$dir")
            
            # Skip if already seen
            [[ -n "${seen_domains[$domain]}" ]] && continue
            
            local cert_path="$dir/fullchain.pem"
            [[ ! -f "$cert_path" ]] && continue
            
            local days status
            days=$(get_cert_days_remaining "$cert_path")
            status=$(get_cert_status "$days")
            
            results+=("panel|$domain|$cert_path|$days|$status")
            seen_domains["$domain"]=1
        done
    fi
    
    # 3. Node certificates (not already seen)
    if [[ -d "$NODE_DEF_CERTS" && "$NODE_DEF_CERTS" != "$PANEL_DEF_CERTS" ]]; then
        for dir in "$NODE_DEF_CERTS"/*/; do
            [[ ! -d "$dir" ]] && continue
            local domain
            domain=$(basename "$dir")
            
            [[ -n "${seen_domains[$domain]}" ]] && continue
            
            local cert_path="$dir/fullchain.pem"
            [[ ! -f "$cert_path" ]] && continue
            
            local days status
            days=$(get_cert_days_remaining "$cert_path")
            status=$(get_cert_status "$days")
            
            results+=("node|$domain|$cert_path|$days|$status")
        done
    fi

    # 4. Default/flat certificates at the certs root — the official node layout
    # uses ssl_cert.pem/ssl_key.pem directly, not per-domain subdirs (MRM-033)
    if [[ -d "$PANEL_DEF_CERTS" ]]; then
        for flat in fullchain.pem ssl_cert.pem; do
            [[ -f "$PANEL_DEF_CERTS/$flat" ]] || continue
            local flat_days flat_status
            flat_days=$(get_cert_days_remaining "$PANEL_DEF_CERTS/$flat")
            flat_status=$(get_cert_status "$flat_days")
            results+=("panel|default|$PANEL_DEF_CERTS/$flat|$flat_days|$flat_status")
        done
    fi
    if [[ -d "$NODE_DEF_CERTS" && "$NODE_DEF_CERTS" != "$PANEL_DEF_CERTS" ]]; then
        for flat in ssl_cert.pem fullchain.pem; do
            [[ -f "$NODE_DEF_CERTS/$flat" ]] || continue
            local flat_days flat_status
            flat_days=$(get_cert_days_remaining "$NODE_DEF_CERTS/$flat")
            flat_status=$(get_cert_status "$flat_days")
            results+=("node|default|$NODE_DEF_CERTS/$flat|$flat_days|$flat_status")
        done
    fi

    # 5. Flat per-domain certs — the OFFICIAL docs layout
    # (/var/lib/pasarguard/certs/<domain>.cer + <domain>.cer.key), produced
    # by the official installer's --ssl-domain wizard (MRM-044)
    local cert_base cert_label cer_file cer_domain cer_days cer_status
    for cert_base in "$PANEL_DEF_CERTS" "$NODE_DEF_CERTS"; do
        [[ -d "$cert_base" ]] || continue
        if [[ "$cert_base" == "$PANEL_DEF_CERTS" ]]; then
            cert_label="panel"
        elif [[ "$cert_base" == "$NODE_DEF_CERTS" ]]; then
            cert_label="node"
        else
            continue
        fi
        for cer_file in "$cert_base"/*.cer; do
            [[ -f "$cer_file" ]] || continue
            cer_domain=$(basename "$cer_file" .cer)
            [[ -n "${seen_domains[$cer_domain]}" ]] && continue
            cer_days=$(get_cert_days_remaining "$cer_file")
            cer_status=$(get_cert_status "$cer_days")
            results+=("$cert_label|$cer_domain|$cer_file|$cer_days|$cer_status")
            seen_domains["$cer_domain"]=1
        done
    done

    printf '%s\n' "${results[@]}"
}

# ═══════════════════════════════════════════════════════════════════════════
# SHOW CERTIFICATE EXPIRY STATUS
# ═══════════════════════════════════════════════════════════════════════════

show_certificate_expiry() {
    ui_header "📅 CERTIFICATE EXPIRY STATUS"
    detect_active_panel > /dev/null
    
    local -a all_certs
    local -a expired_domains=()
    local -a expiring_domains=()
    
    # MRM-044: mark the ACTIVE dashboard / node-gRPC domains taken from the
    # .env files so the operator can see at a glance which cert serves what
    local panel_dom node_dom
    panel_dom=$(_env_cert_domain "$PANEL_ENV" "UVICORN_SSL_CERTFILE" 2>/dev/null) || panel_dom=""
    node_dom=$(_env_cert_domain "$NODE_ENV" "SSL_CERT_FILE" 2>/dev/null) || node_dom=""

    # Discover all certificates
    mapfile -t all_certs < <(discover_all_certificates)
    
    if [[ ${#all_certs[@]} -eq 0 ]]; then
        ui_warning "No certificates found."
        pause
        return
    fi
    
    # Display header
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
    printf "${CYAN}║${NC} %-4s │ %-28s │ %-16s │ %-6s │ %-8s ${CYAN}║${NC}\n" "Src" "Domain" "Expiry Date" "Days" "Status"
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════════════════════╣${NC}"
    
    # Display certificates
    for cert_info in "${all_certs[@]}"; do
        IFS='|' read -r source domain cert_path days status <<< "$cert_info"
        
        local color
        color=$(get_status_color "$status")
        
        # Get expiry date for display
        local expiry_date formatted_date
        expiry_date=$(get_cert_expiry_date "$cert_path")
        formatted_date=$(date -d "$expiry_date" "+%Y-%m-%d" 2>/dev/null || echo "${expiry_date:0:10}")
        
        # Track problematic certificates
        case "$status" in
            EXPIRED|CRITICAL) expired_domains+=("$domain") ;;
            WARNING) expiring_domains+=("$domain") ;;
        esac
        
        # Source label — color goes in the FORMAT string, not the argument:
        # printf '%s' would print literal \033[...] text (MRM-038)
        local src_text src_color
        case "$source" in
            le) src_text="LE"; src_color="$GREEN" ;;
            panel) src_text="PNL"; src_color="$ORANGE" ;;
            node) src_text="NOD"; src_color="$PURPLE" ;;
        esac

        # MRM-044: role markers for the cert actually in use right now
        local dom_disp="$domain"
        [[ -n "$panel_dom" && "$domain" == "$panel_dom" ]] && dom_disp="$domain 🖥"
        if [[ "$dom_disp" == "$domain" && -n "$node_dom" && "$domain" == "$node_dom" ]]; then
            dom_disp="$domain ⚙"
        fi

        printf "${CYAN}║${NC} ${src_color}%-13s${NC} │ %-28s │ %-16s │ ${color}%-6s${NC} │ ${color}%-8s${NC} ${CYAN}║${NC}\n" \
               "$src_text" "${dom_disp:0:28}" "${formatted_date:0:16}" "$days" "$status"
    done
    
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
    
    # Legend
    echo -e "\n${CYAN}Source:${NC} ${GREEN}LE${NC}=Let's Encrypt  ${ORANGE}PNL${NC}=Panel only  ${PURPLE}NOD${NC}=Node only"
    if [[ -n "$panel_dom" || -n "$node_dom" ]]; then
        echo -e "${CYAN}Role:${NC} 🖥 = dashboard domain (panel .env)   ⚙ = node gRPC domain (node .env)"
    fi
    
    # Alerts
    if [[ ${#expired_domains[@]} -gt 0 ]]; then
        echo -e "\n${RED}🚨 ${#expired_domains[@]} certificate(s) EXPIRED or CRITICAL:${NC}"
        for d in "${expired_domains[@]}"; do
            echo -e "   ${RED}• $d${NC}"
        done
    fi
    
    if [[ ${#expiring_domains[@]} -gt 0 ]]; then
        echo -e "\n${YELLOW}⚡ ${#expiring_domains[@]} certificate(s) expiring soon:${NC}"
        for d in "${expiring_domains[@]}"; do
            echo -e "   ${YELLOW}• $d${NC}"
        done
    fi
    
    # Quick actions
    local total_issues=$(( ${#expired_domains[@]} + ${#expiring_domains[@]} ))
    
    if [[ $total_issues -gt 0 ]]; then
        echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo "Quick Actions:"
        echo "1) 🔄 Renew ALL expiring/expired certificates"
        echo "2) 🎯 Renew specific certificate"
        echo "0) ↩️  Back"
        echo ""
        read -r -p "Select: " action
        
        case "$action" in
            1) renew_expiring_certificates ;;
            2) renew_specific_certificate ;;
        esac
    else
        pause
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# RENEW EXPIRING CERTIFICATES
# ═══════════════════════════════════════════════════════════════════════════

renew_expiring_certificates() {
    ui_header "🔄 RENEWING EXPIRING CERTIFICATES"
    init_logging
    detect_active_panel > /dev/null
    
    log_info "Starting bulk certificate renewal"
    
    local -a le_domains=()
    local -a panel_only_domains=()
    local -A domain_info=()
    
    # Categorize certificates
    while IFS='|' read -r source domain cert_path days status; do
        # Flat/default entries have no real domain to renew (MRM-033)
        [[ "$source" != "le" && "$domain" == "default" ]] && continue
        if [[ "$days" -le "$EXPIRY_WARNING_DAYS" ]]; then
            domain_info["$domain"]="$days|$status"
            
            if [[ "$source" == "le" ]]; then
                le_domains+=("$domain")
            else
                panel_only_domains+=("$domain")
            fi
        fi
    done < <(discover_all_certificates)
    
    local total_le=${#le_domains[@]}
    local total_panel=${#panel_only_domains[@]}
    local total=$((total_le + total_panel))
    
    if [[ $total -eq 0 ]]; then
        ui_success "All certificates are up to date!"
        pause
        return 0
    fi
    
    # Display summary
    echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  Certificates requiring renewal: $total${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}\n"
    
    if [[ $total_le -gt 0 ]]; then
        echo -e "${GREEN}Let's Encrypt certificates ($total_le):${NC}"
        for d in "${le_domains[@]}"; do
            IFS='|' read -r days status <<< "${domain_info[$d]}"
            local color
            color=$(get_status_color "$status")
            echo -e "  ${color}• $d ($days days - $status)${NC}"
        done
        echo ""
    fi
    
    if [[ $total_panel -gt 0 ]]; then
        echo -e "${ORANGE}Panel/Node only certificates ($total_panel):${NC}"
        echo -e "${ORANGE}(These need NEW certificates from Let's Encrypt)${NC}"
        for d in "${panel_only_domains[@]}"; do
            IFS='|' read -r days status <<< "${domain_info[$d]}"
            local color
            color=$(get_status_color "$status")
            echo -e "  ${color}• $d ($days days - $status)${NC}"
        done
        echo ""
    fi
    
    # Options
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "Options:"
    [[ $total_le -gt 0 ]] && echo "1) Renew Let's Encrypt certificates ($total_le)"
    [[ $total_panel -gt 0 ]] && echo "2) Request NEW certificates for Panel/Node only ($total_panel)"
    [[ $total_le -gt 0 && $total_panel -gt 0 ]] && echo "3) Process ALL ($total)"
    echo "0) Cancel"
    echo ""
    read -r -p "Select: " choice
    
    case "$choice" in
        1) [[ $total_le -gt 0 ]] && _renew_le_certificates "${le_domains[@]}" ;;
        2) [[ $total_panel -gt 0 ]] && _request_new_certificates "${panel_only_domains[@]}" ;;
        3) 
            [[ $total_le -gt 0 ]] && _renew_le_certificates "${le_domains[@]}"
            [[ $total_panel -gt 0 ]] && _request_new_certificates "${panel_only_domains[@]}"
            ;;
        *) return ;;
    esac
    
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
# HELPER: Renew Let's Encrypt Certificates
# ═══════════════════════════════════════════════════════════════════════════

# authenticator saved for a live cert (empty when unknown)
_cert_authenticator() {
    local domain="$1"
    grep -E '^[[:space:]]*authenticator[[:space:]]*=' "/etc/letsencrypt/renewal/${domain}.conf" 2>/dev/null \
        | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d ' "'
}

# Show the most relevant part of a failed certbot run + actionable hints
_show_certbot_failure() {
    local output_file="$1" domain="$2"

    if [[ ! -s "$output_file" ]]; then
        echo -e "\n  ${YELLOW}(no certbot output captured)${NC}"
        return
    fi

    echo -e "\n  ${RED}── certbot report: $domain ──${NC}"
    grep -vE '^[[:space:]]*$' "$output_file" 2>/dev/null | tail -n 12 | sed 's/^/    /'
    echo ""

    if grep -qE 'Failed to bind to port|Address already in use' "$output_file" 2>/dev/null; then
        echo -e "    ${YELLOW}Hint: port $HTTP_PORT is still occupied — find and stop the web server/container owning it.${NC}"
    elif grep -qiE 'Invalid response from|404|403' "$output_file" 2>/dev/null; then
        echo -e "    ${YELLOW}Hint: Let's Encrypt reached the server but got an invalid challenge response.${NC}"
        echo -e "    ${YELLOW}      Make sure DNS for $domain really points to THIS server (no CDN/proxy in between).${NC}"
    elif grep -qiE 'timeout|timed out' "$output_file" 2>/dev/null; then
        echo -e "    ${YELLOW}Hint: Let's Encrypt could not reach port 80 — check firewall rules and the DNS target.${NC}"
    elif grep -qiE 'live directory exists' "$output_file" 2>/dev/null; then
        echo -e "    ${YELLOW}Hint: a stale /etc/letsencrypt live directory blocked the new certificate.${NC}"
        echo -e "    ${YELLOW}      MRM should have backed it up and removed it — run the renewal again.${NC}"
    elif grep -qiE 'No certificate found|No certs were found' "$output_file" 2>/dev/null; then
        echo -e "    ${YELLOW}Hint: certbot has no renewal profile for '$domain' and the automatic reissue also failed.${NC}"
        echo -e "    ${YELLOW}      Check DNS, then see: /var/log/letsencrypt/letsencrypt.log${NC}"
    fi
    echo -e "    Full log: ${CYAN}$CERTBOT_DEBUG_LOG${NC}"
}

# Append a failed run's full output to the archive log with a separator
_archive_certbot_failure() {
    local output_file="$1" domain="$2"
    {
        echo "════════ certbot failure: $domain ($(date '+%Y-%m-%d %H:%M:%S')) ════════"
        cat "$output_file" 2>/dev/null
        echo ""
    } >> "$CERTBOT_DEBUG_LOG" 2>/dev/null
}

# MRM-041: find a renewal profile whose domain list covers $1.
# Prints the profile's (primary) name; rc 1 when no profile covers it.
_find_renewal_name_for_domain() {
    local domain="$1" conf name tok
    for conf in /etc/letsencrypt/renewal/*.conf; do
        [[ -f "$conf" ]] || continue
        # Extract all domain-like tokens from the profile and exact-match
        # (webroot_map keys hold every domain the cert covers; exact
        # comparison avoids regex-escaping pitfalls)
        while IFS= read -r tok; do
            if [[ "$tok" == "$domain" ]]; then
                name=$(basename "$conf" .conf)
                printf '%s\n' "$name"
                return 0
            fi
        done < <(grep -oE '[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+' "$conf" 2>/dev/null)
    done
    return 1
}

# Saved Let's Encrypt email (first one found), else interactive prompt
_get_reissue_email() {
    local saved
    saved=$(grep -hE '^[[:space:]]*email[[:space:]]*=' /etc/letsencrypt/renewal/*.conf 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' "')
    if [[ -n "$saved" ]]; then
        printf '%s\n' "$saved"
        return 0
    fi
    read -r -p "  No saved Let's Encrypt email found — enter email: " saved
    sanitize_input "$saved"
}

# Copy an LE cert (from live_dir) into a per-domain panel/node dest dir
_copy_le_cert_to_dest() {
    local domain="$1" le_dir="$2" dest_base="$3" dest
    [[ -n "$dest_base" ]] || return 1
    dest="$dest_base/$domain"
    [[ -d "$dest" ]] || return 1
    [[ -f "$le_dir/fullchain.pem" && -f "$le_dir/privkey.pem" ]] || return 1
    cp -L "$le_dir/fullchain.pem" "$dest/" 2>/dev/null || return 1
    cp -L "$le_dir/privkey.pem" "$dest/" 2>/dev/null || return 1
    chmod 644 "$dest/fullchain.pem" 2>/dev/null
    chmod 600 "$dest/privkey.pem" 2>/dev/null
    return 0
}

# MRM-042: certbot refuses to issue a cert when a stale live/ directory
# already exists ("live directory exists for X"). Back up the stale dir
# (dereferenced) into the SSL backup space, remove it and the orphaned
# archive, so the reissue can proceed. The old key/chain stay in the
# backup; panel/node copies under their cert dirs are untouched.
_stale_live_cleanup() {
    local domain="$1"
    local live="/etc/letsencrypt/live/$domain"
    [[ -e "$live" ]] || return 0
    local backup
    backup="$SSL_BACKUP_DIR/stale-live-$domain-$(date +%Y%m%d-%H%M%S)"
    if ! mkdir -p "$backup" 2>/dev/null; then
        log_error "Cannot create backup dir: $backup"
        return 1
    fi
    cp -Lr "$live" "$backup/" 2>/dev/null
    if [[ -d "/etc/letsencrypt/archive/$domain" ]]; then
        cp -a "/etc/letsencrypt/archive/$domain" "$backup/" 2>/dev/null
    fi
    if ! rm -rf "$live" "/etc/letsencrypt/archive/$domain" 2>/dev/null || [[ -e "$live" ]]; then
        log_error "Failed to remove stale live dir for $domain"
        return 1
    fi
    rm -f "/etc/letsencrypt/renewal/${domain}.conf" 2>/dev/null
    log_info "Stale live dir for $domain backed up to $backup"
    echo -e "    ${YELLOW}↳ stale cert backed up: $backup${NC}"
    return 0
}

# MRM-043: a renewal profile is "broken" when the file exists but holds no
# file references (cert/fullchain/privkey/chain/csr =). certbot leaves such
# a skeleton behind when an issuance is aborted after account setup (e.g.
# 'live directory exists') — 'certbot renew' then fails with a parse error
# and can never succeed on that profile.
_renewal_profile_broken() {
    local domain="$1"
    local conf="/etc/letsencrypt/renewal/${domain}.conf"
    [[ -f "$conf" ]] || return 1
    if grep -qE '^[[:space:]]*(cert|fullchain|privkey|chain|csr)[[:space:]]*=' "$conf" 2>/dev/null; then
        return 1    # file references present — healthy profile
    fi
    return 0        # broken skeleton
}

_renew_le_certificates() {
    local -a domains=("$@")

    [[ ${#domains[@]} -eq 0 ]] && return 0

    # Non-interactive DNS sanity check (MRM-039): warn before stopping services
    local -a dns_bad=()
    local domain srv4
    local -a a_recs=()
    srv4=$(get_server_ipv4 2>/dev/null || true)
    for domain in "${domains[@]}"; do
        a_recs=()
        mapfile -t a_recs < <(get_domain_ipv4 "$domain")
        if [[ ${#a_recs[@]} -eq 0 ]]; then
            dns_bad+=("$domain — no A record found")
        elif [[ -n "$srv4" ]] && ! all_records_match_server "$srv4" "${a_recs[@]}"; then
            dns_bad+=("$domain — A: ${a_recs[*]} but this server is $srv4")
        fi
    done
    if [[ ${#dns_bad[@]} -gt 0 ]]; then
        echo -e "\n${YELLOW}⚠ DNS pre-check — likely to fail:${NC}"
        local bad_entry
        for bad_entry in "${dns_bad[@]}"; do
            echo -e "  ${YELLOW}• $bad_entry${NC}"
        done
        echo -e "${YELLOW}  (Renewal continues anyway — it only works if HTTP actually reaches this server.)${NC}\n"
    fi

    # MRM-041: missing renewal profile pre-check — say it before we stop services
    local -a missing_profile=() broken_profile=() san_covered_by=()
    local alt_name
    for domain in "${domains[@]}"; do
        if [[ ! -f "/etc/letsencrypt/renewal/${domain}.conf" ]]; then
            if alt_name=$(_find_renewal_name_for_domain "$domain"); then
                san_covered_by+=("$domain — covered by cert '$alt_name', that one gets renewed")
            else
                missing_profile+=("$domain — no renewal profile, a NEW certificate will be requested")
            fi
        elif _renewal_profile_broken "$domain"; then
            broken_profile+=("$domain — renewal profile is BROKEN, it will be backed up and a NEW certificate will be requested")
        elif alt_name=$(_find_renewal_name_for_domain "$domain") && [[ -n "$alt_name" && "$alt_name" != "$domain" ]]; then
            san_covered_by+=("$domain — covered by cert '$alt_name', that one gets renewed")
        fi
    done
    if [[ ${#missing_profile[@]} -gt 0 || ${#broken_profile[@]} -gt 0 || ${#san_covered_by[@]} -gt 0 ]]; then
        echo -e "${YELLOW}⚠ Renewal profile check:${NC}"
        local note
        for note in "${missing_profile[@]}" "${broken_profile[@]}" "${san_covered_by[@]}"; do
            echo -e "  ${YELLOW}• $note${NC}"
        done
        echo ""
    fi

    echo -e "${YELLOW}[1/3] Stopping web services...${NC}"
    stop_web_services

    if ! check_port_availability "$HTTP_PORT" 5; then
        ui_error "Port $HTTP_PORT still in use!"
        restore_services
        return 1
    fi

    echo -e "${YELLOW}[2/3] Renewing certificates...${NC}\n"

    local renewed=0 failed=0 rc=0
    local tmp_out auth renew_name san_covered
    local reissue_email=""
    local recovery=0 bconf bbackup
    tmp_out=$(mktemp /tmp/ssl-manager-cb.XXXXXX)

    for domain in "${domains[@]}"; do
        echo -ne "  Renewing ${CYAN}$domain${NC}... "

        renew_name="$domain"
        san_covered=0

        # DNS-01 certs must renew with their saved plugin — forcing
        # --standalone on them would break the renewal (MRM-039)
        auth=$(_cert_authenticator "$renew_name")

        rc=0
        if [[ "$auth" == dns-* ]]; then
            certbot renew --cert-name "$renew_name" --non-interactive >"$tmp_out" 2>&1 || rc=$?
        else
            certbot renew --cert-name "$renew_name" --standalone --non-interactive >"$tmp_out" 2>&1 || rc=$?
        fi

        # MRM-041: cert files exist but certbot has no renewal profile for
        # this name (partial /etc/letsencrypt restore, manually copied cert).
        # certbot cannot renew what it never recorded — recover:
        #  a) domain is a SAN on another cert → renew that cert
        #  b) no profile anywhere            → reissue a fresh certificate
        # MRM-041/043: cert files exist but certbot cannot renew this name.
        # Two shapes of that:
        #   a) 'No certificate found with name' — no profile at all
        #   b) parse failure on a BROKEN profile skeleton (left behind by an
        #      aborted issuance, e.g. 'live directory exists') — back it up
        #      and drop it, then treat the name as profile-less.
        recovery=0
        if [[ $rc -ne 0 ]]; then
            if grep -qE 'No certificate found with name|No certs were found' "$tmp_out"; then
                recovery=1
            elif grep -qiE 'is broken|parse failure|parsefail|missing a required file reference' "$tmp_out" \
                 && _renewal_profile_broken "$domain"; then
                bconf="/etc/letsencrypt/renewal/${domain}.conf"
                bbackup="$SSL_BACKUP_DIR/broken-conf-$domain-$(date +%Y%m%d-%H%M%S)"
                mkdir -p "$bbackup" 2>/dev/null && cp -a "$bconf" "$bbackup/" 2>/dev/null
                rm -f "$bconf" 2>/dev/null
                log_info "Broken renewal profile for $domain backed up to $bbackup"
                echo -e "    ${YELLOW}↳ broken renewal profile backed up: $bbackup${NC}"
                recovery=1
            fi
        fi
        if [[ $recovery -eq 1 ]]; then
            alt_name=$(_find_renewal_name_for_domain "$domain")
            if [[ -n "$alt_name" ]]; then
                echo -e "${YELLOW}↳ covered by cert '$alt_name' — renewing it...${NC}"
                renew_name="$alt_name"
                san_covered=1
                auth=$(_cert_authenticator "$renew_name")
                rc=0
                if [[ "$auth" == dns-* ]]; then
                    certbot renew --cert-name "$renew_name" --non-interactive >"$tmp_out" 2>&1 || rc=$?
                else
                    certbot renew --cert-name "$renew_name" --standalone --non-interactive >"$tmp_out" 2>&1 || rc=$?
                fi
            else
                echo -e "${YELLOW}↳ renewal profile missing — reissuing fresh certificate...${NC}"
                reissue_email=$(_get_reissue_email)
                if ! validate_email "${reissue_email:-}"; then
                    ui_error "Invalid email — cannot reissue $domain"
                    rc=1
                elif ! _stale_live_cleanup "$domain"; then
                    ui_error "Stale live directory for $domain could not be removed — reissue skipped"
                    rc=1
                else
                    rc=0
                    certbot certonly --standalone \
                        --non-interactive --agree-tos \
                        --email "$reissue_email" \
                        --preferred-challenges http \
                        -d "$domain" >"$tmp_out" 2>&1 || rc=$?
                fi
            fi
        fi

        if [[ $rc -eq 0 ]]; then
            echo -e "${GREEN}✔${NC}"
            if [[ $san_covered -eq 1 ]]; then
                log_success "Renewed via cert '$renew_name' (covers $domain)"
                _copy_le_cert_to_dest "$domain" "/etc/letsencrypt/live/$renew_name" "$PANEL_DEF_CERTS"
                if [[ -n "$NODE_DEF_CERTS" && "$NODE_DEF_CERTS" != "$PANEL_DEF_CERTS" ]]; then
                    _copy_le_cert_to_dest "$domain" "/etc/letsencrypt/live/$renew_name" "$NODE_DEF_CERTS"
                fi
            else
                log_success "Renewed: $domain"
                _update_cert_paths "$domain"
            fi
            renewed=$((renewed + 1))
        else
            echo -e "${RED}✘${NC}"
            log_error "Failed to renew: $domain"
            failed=$((failed + 1))
            _archive_certbot_failure "$tmp_out" "$domain"
            _show_certbot_failure "$tmp_out" "$domain"
        fi
        : > "$tmp_out"
    done
    rm -f "$tmp_out"

    echo -e "\n${YELLOW}[3/3] Restoring services...${NC}"
    restore_services
    # Only restart panel/node when something actually renewed (fresh certs to load)
    if [[ $renewed -gt 0 ]]; then
        restart_panel_services "panel"
        restart_panel_services "node"
    fi

    # Summary
    echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${GREEN}✔ Renewed: $renewed${NC}"
    echo -e "  ${RED}✘ Failed:  $failed${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    _offer_sync "${domains[@]}"

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# HELPER: Request New Certificates
# ═══════════════════════════════════════════════════════════════════════════

_request_new_certificates() {
    local -a domains=("$@")
    
    [[ ${#domains[@]} -eq 0 ]] && return 0
    
    echo -e "\n${ORANGE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${ORANGE}  These certificates need to be requested NEW.${NC}"
    echo -e "${ORANGE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    # Get email
    local email=""
    local saved_email
    saved_email=$(grep -h "email" /etc/letsencrypt/renewal/*.conf 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d ' ')
    
    if [[ -n "$saved_email" ]]; then
        echo -e "Found email: ${CYAN}$saved_email${NC}"
        read -r -p "Use this email? (Y/n): " use_saved
        if [[ ! "$use_saved" =~ ^[Nn]$ ]]; then
            email="$saved_email"
        fi
    fi
    
    if [[ -z "$email" ]]; then
        read -r -p "Enter email: " email
        email=$(sanitize_input "$email")
        
        if ! validate_email "$email"; then
            ui_error "Invalid email format."
            return 1
        fi
    fi
    
    echo -e "\n${YELLOW}[1/4] Validating DNS...${NC}\n"
    
    local -a valid_domains=()
    local domain dns_out
    for domain in "${domains[@]}"; do
        echo -ne "  Checking ${CYAN}$domain${NC}... "
        # (MRM-039) capture the check output so the FAILURE REASON is visible
        if dns_out=$(validate_domain_dns "$domain" "true" 2>&1); then
            echo -e "${GREEN}✔${NC}"
            valid_domains+=("$domain")
        else
            echo -e "${RED}✘ (skipping)${NC}"
            printf '%s\n' "$dns_out" | sed 's/^/    /'
            log_warning "DNS failed for $domain"
        fi
    done
    
    if [[ ${#valid_domains[@]} -eq 0 ]]; then
        ui_error "No domains passed DNS validation!"
        return 1
    fi
    
    echo -e "\n${YELLOW}[2/4] Stopping web services...${NC}"
    stop_web_services
    
    if ! check_port_availability "$HTTP_PORT" 5; then
        ui_error "Port $HTTP_PORT still in use!"
        restore_services
        return 1
    fi
    
    echo -e "${YELLOW}[3/4] Requesting certificates...${NC}\n"
    
    local success=0 failed=0 rc=0
    local tmp_out
    tmp_out=$(mktemp /tmp/ssl-manager-cb.XXXXXX)
    
    for domain in "${valid_domains[@]}"; do
        echo -ne "  Requesting ${CYAN}$domain${NC}... "
        
        rc=0
        certbot certonly --standalone \
            --non-interactive --agree-tos \
            --email "$email" \
            --preferred-challenges http \
            -d "$domain" >"$tmp_out" 2>&1 || rc=$?
        
        if [[ $rc -eq 0 ]]; then
            echo -e "${GREEN}✔${NC}"
            log_success "New certificate: $domain"
            success=$((success + 1))
            _update_cert_paths "$domain"
        else
            echo -e "${RED}✘${NC}"
            log_error "Failed to get certificate: $domain"
            failed=$((failed + 1))
            _archive_certbot_failure "$tmp_out" "$domain"
            _show_certbot_failure "$tmp_out" "$domain"
        fi
        : > "$tmp_out"
    done
    
    rm -f "$tmp_out"
    
    echo -e "\n${YELLOW}[4/4] Restoring services...${NC}"
    restore_services
    # Only restart panel/node when something actually succeeded (MRM-039)
    if [[ $success -gt 0 ]]; then
        restart_panel_services "panel"
        restart_panel_services "node"
    fi
    
    # Summary
    echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${GREEN}✔ Success: $success${NC}"
    echo -e "  ${RED}✘ Failed:  $failed${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    _offer_sync "${valid_domains[@]}"
    
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# HELPER: Update Certificate Paths
# ═══════════════════════════════════════════════════════════════════════════

_update_cert_paths() {
    local domain="$1"
    local le_path="/etc/letsencrypt/live/$domain"
    
    [[ ! -d "$le_path" ]] && return 1
    
    # Update panel certs
    if [[ -d "$PANEL_DEF_CERTS/$domain" ]]; then
        cp -L "$le_path/fullchain.pem" "$PANEL_DEF_CERTS/$domain/" 2>/dev/null
        cp -L "$le_path/privkey.pem" "$PANEL_DEF_CERTS/$domain/" 2>/dev/null
        chmod 644 "$PANEL_DEF_CERTS/$domain/fullchain.pem" 2>/dev/null
        chmod 600 "$PANEL_DEF_CERTS/$domain/privkey.pem" 2>/dev/null
        echo -e "    ${GREEN}↳ Updated panel cert${NC}"
    fi
    
    # Update node certs
    if [[ -d "$NODE_DEF_CERTS/$domain" && "$NODE_DEF_CERTS" != "$PANEL_DEF_CERTS" ]]; then
        cp -L "$le_path/fullchain.pem" "$NODE_DEF_CERTS/$domain/" 2>/dev/null
        cp -L "$le_path/privkey.pem" "$NODE_DEF_CERTS/$domain/" 2>/dev/null
        chmod 644 "$NODE_DEF_CERTS/$domain/fullchain.pem" 2>/dev/null
        chmod 600 "$NODE_DEF_CERTS/$domain/privkey.pem" 2>/dev/null
        echo -e "    ${GREEN}↳ Updated node cert${NC}"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# RENEW SPECIFIC CERTIFICATE
# ═══════════════════════════════════════════════════════════════════════════

renew_specific_certificate() {
    ui_header "🎯 RENEW SPECIFIC CERTIFICATE"
    detect_active_panel > /dev/null
    
    echo -e "${YELLOW}Select certificate to renew:${NC}\n"
    
    local -a cert_list=()
    local idx=1
    
    while IFS='|' read -r source domain cert_path days status; do
        [[ "$domain" == "default" ]] && continue   # flat/default certs: not renewable (MRM-033)
        cert_list+=("$source|$domain|$cert_path|$days|$status")
        
        local color src_text src_color
        color=$(get_status_color "$status")
        case "$source" in
            le) src_text="[LE]"; src_color="$GREEN" ;;
            panel) src_text="[PNL]"; src_color="$ORANGE" ;;
            node) src_text="[NOD]"; src_color="$PURPLE" ;;
        esac
        
        # (MRM-038) color in the format string — '%s' would print raw \033 codes
        printf "%2d) ${src_color}%-12s${NC} %-30s ${color}[%s - %d days]${NC}\n" \
               "$idx" "$src_text" "$domain" "$status" "$days"
        idx=$((idx + 1))
    done < <(discover_all_certificates)
    
    if [[ $idx -eq 1 ]]; then
        ui_error "No certificates found."
        pause
        return
    fi
    
    echo ""
    read -r -p "Select (0 to cancel): " selection
    [[ "$selection" == "0" || -z "$selection" ]] && return
    
    # Validate selection
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -lt 1 ]] || [[ "$selection" -ge "$idx" ]]; then
        ui_error "Invalid selection."
        pause
        return
    fi
    
    local selected_idx=$((selection - 1))
    IFS='|' read -r source domain cert_path days status <<< "${cert_list[$selected_idx]}"
    
    # (MRM-038) same fix as expiry table: colors in format, not %s args
    local src_text src_color
    case "$source" in
        le) src_text="[LE]"; src_color="$GREEN" ;;
        panel) src_text="[PNL]"; src_color="$ORANGE" ;;
        node) src_text="[NOD]"; src_color="$PURPLE" ;;
    esac
    
    echo -e "\nSelected: ${CYAN}$domain${NC} (Source: ${src_color}${src_text}${NC})"
    
    if [[ "$source" == "le" ]]; then
        read -r -p "Renew this certificate? (Y/n): " confirm
        [[ "$confirm" =~ ^[Nn]$ ]] && return
        
        _renew_le_certificates "$domain"
    else
        echo -e "\n${ORANGE}This certificate is not in Let's Encrypt.${NC}"
        echo -e "${ORANGE}A NEW certificate will be requested.${NC}"
        read -r -p "Proceed? (Y/n): " confirm
        [[ "$confirm" =~ ^[Nn]$ ]] && return
        
        _request_new_certificates "$domain"
    fi
    
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
# REQUEST NEW CERTIFICATE (SSL WIZARD)
# ═══════════════════════════════════════════════════════════════════════════

ssl_wizard() {
    ui_header "🔐 SSL GENERATION WIZARD"
    init_logging
    detect_active_panel > /dev/null
    
    if ! check_dependencies; then
        pause
        return 2
    fi
    
    echo -e "${CYAN}Panel: $(basename "$PANEL_DIR" 2>/dev/null || echo 'unknown')${NC}"
    echo -e "${CYAN}Certs: $PANEL_DEF_CERTS${NC}\n"
    
    # Get domain count
    read -r -p "How many domains? (1-10): " count
    
    if ! [[ "$count" =~ ^[0-9]+$ ]] || [[ "$count" -lt 1 ]] || [[ "$count" -gt 10 ]]; then
        ui_error "Invalid number. Enter 1-10."
        pause
        return 1
    fi
    
    # Get domains
    local -a domain_list=()
    for (( i=1; i<=count; i++ )); do
        while true; do
            read -r -p "Domain $i: " domain_input
            domain_input=$(sanitize_input "$domain_input")
            
            if [[ -z "$domain_input" ]]; then
                ui_error "Domain cannot be empty."
                continue
            fi
            
            if ! validate_domain "$domain_input"; then
                ui_error "Invalid domain format: $domain_input"
                continue
            fi
            
            domain_list+=("$domain_input")
            break
        done
    done
    
    # Get email
    local email
    while true; do
        read -r -p "Email: " email
        email=$(sanitize_input "$email")
        
        if validate_email "$email"; then
            break
        fi
        ui_error "Invalid email format."
    done
    
    local primary_domain="${domain_list[0]}"
    
    # Request certificate
    if ! _request_certificate "$email" "${domain_list[@]}"; then
        ui_error "Certificate request failed!"
        echo -e "${YELLOW}Check logs: $CERTBOT_DEBUG_LOG${NC}"
        pause
        return 5
    fi
    
    # Verify certificate exists
    if [[ ! -d "/etc/letsencrypt/live/$primary_domain" ]]; then
        ui_error "Certificate not created!"
        pause
        return 5
    fi
    
    ui_success "Certificate obtained for: $primary_domain"
    echo ""
    
    # Configure usage
    echo "Where to use this certificate?"
    echo "1) Panel (Dashboard)"
    echo "2) Node Server"
    echo "3) Config (Inbounds)"
    echo "4) All of the above"
    read -r -p "Select: " usage_opt
    
    case "$usage_opt" in
        1) _process_panel "$primary_domain" ;;
        2) _process_node "$primary_domain" ;;
        3) _process_config "$primary_domain" ;;
        4)
            _process_panel "$primary_domain"
            _process_node "$primary_domain"
            _process_config "$primary_domain"
            ;;
        *) ui_error "Invalid selection." ;;
    esac
    
    _offer_sync "$primary_domain"
    
    log_info "SSL wizard completed for $primary_domain"
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
# REQUEST CERTIFICATE (Core Function)
# ═══════════════════════════════════════════════════════════════════════════

_request_certificate() {
    local email="$1"
    shift
    local -a domains=("$@")
    
    log_info "Starting certificate request for: ${domains[*]}"
    
    # Step 1: Check Let's Encrypt API
    echo -e "${YELLOW}[1/5] Checking Let's Encrypt API...${NC}"
    if ! curl -s --connect-timeout "$CURL_TIMEOUT" https://acme-v02.api.letsencrypt.org/directory > /dev/null; then
        ui_error "Let's Encrypt API unreachable!"
        log_error "LE API unreachable"
        return 4
    fi
    ui_success "API accessible"
    
    # Step 2: Validate DNS
    echo -e "${YELLOW}[2/5] Validating DNS...${NC}"
    for domain in "${domains[@]}"; do
        if ! validate_domain_dns "$domain"; then
            log_error "DNS validation failed for $domain"
            return 1
        fi
    done
    
    # Step 3: Configure firewall
    echo -e "${YELLOW}[3/5] Configuring firewall...${NC}"
    if command -v ufw &>/dev/null; then
        ufw allow "$HTTP_PORT/tcp" &>/dev/null
        ufw allow "$HTTPS_PORT/tcp" &>/dev/null
    fi
    
    # Step 4: Stop services
    echo -e "${YELLOW}[4/5] Preparing for challenge...${NC}"
    stop_web_services
    
    if ! check_port_availability "$HTTP_PORT" 5; then
        ui_error "Port $HTTP_PORT still in use!"
        restore_services
        return 1
    fi
    ui_success "Port $HTTP_PORT available"
    
    # Build domain flags
    local domain_flags=""
    for d in "${domains[@]}"; do
        domain_flags+=" -d $d"
    done
    
    # Step 5: Request certificate
    echo -e "${YELLOW}[5/5] Requesting certificate...${NC}"
    echo -e "${CYAN}This may take up to 2 minutes...${NC}"
    
    # shellcheck disable=SC2086
    if certbot certonly --standalone \
        --non-interactive --agree-tos \
        --email "$email" \
        --preferred-challenges http \
        --http-01-port "$HTTP_PORT" \
        $domain_flags > "$CERTBOT_DEBUG_LOG" 2>&1; then
        
        ui_success "Certificate obtained successfully!"
        log_success "Certificate obtained for ${domains[*]}"
        restore_services
        return 0
    else
        ui_error "Certificate request failed!"
        _show_certbot_failure "$CERTBOT_DEBUG_LOG" "${domains[0]}"
        log_error "Certbot failed"
        restore_services
        return 5
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# PROCESS PANEL/NODE/CONFIG SSL
# ═══════════════════════════════════════════════════════════════════════════

_process_panel() {
    local domain="$1"
    local le_path="/etc/letsencrypt/live/$domain"
    
    echo -e "\n${CYAN}--- Configuring Panel SSL ---${NC}"
    
    if [[ ! -f "$le_path/fullchain.pem" ]]; then
        ui_error "Source certificate not found!"
        return 1
    fi
    
    echo "Storage options:"
    echo "1) Default ($PANEL_DEF_CERTS/$domain)"
    echo "2) Custom path"
    read -r -p "Select: " path_opt
    
    local target_dir="$PANEL_DEF_CERTS"
    if [[ "$path_opt" == "2" ]]; then
        read -r -p "Enter path: " custom_path
        custom_path=$(sanitize_input "$custom_path")
        if validate_path "$custom_path"; then
            target_dir="$custom_path"
        else
            ui_error "Invalid path!"
            return 1
        fi
    fi
    
    target_dir="$target_dir/$domain"
    mkdir -p "$target_dir" || { ui_error "Cannot create directory!"; return 1; }
    
    if cp -L "$le_path/fullchain.pem" "$target_dir/" && \
       cp -L "$le_path/privkey.pem" "$target_dir/"; then
        
        chmod 644 "$target_dir/fullchain.pem"
        chmod 600 "$target_dir/privkey.pem"
        
        # Update .env
        if [[ -f "$PANEL_ENV" ]] || touch "$PANEL_ENV" 2>/dev/null; then
            sed -i '/UVICORN_SSL_CERTFILE/d' "$PANEL_ENV"
            sed -i '/UVICORN_SSL_KEYFILE/d' "$PANEL_ENV"
            echo "UVICORN_SSL_CERTFILE = \"$target_dir/fullchain.pem\"" >> "$PANEL_ENV"
            echo "UVICORN_SSL_KEYFILE = \"$target_dir/privkey.pem\"" >> "$PANEL_ENV"
        fi
        
        # FIX: recreate the container — env_file changes only apply on
        # container creation; `restart` reuses the old config (MRM-031)
        recreate_service "panel"
        
        ui_success "Panel SSL configured!"
        echo -e "  Cert: ${CYAN}$target_dir/fullchain.pem${NC}"
        echo -e "  Key:  ${CYAN}$target_dir/privkey.pem${NC}"
        log_success "Panel SSL configured for $domain"
    else
        ui_error "Failed to copy certificates!"
        return 1
    fi
}

_process_node() {
    local domain="$1"
    local le_path="/etc/letsencrypt/live/$domain"
    
    echo -e "\n${PURPLE}--- Configuring Node SSL ---${NC}"
    
    if [[ ! -f "$le_path/fullchain.pem" ]]; then
        ui_error "Source certificate not found!"
        return 1
    fi
    
    echo "Storage options:"
    echo "1) Default ($NODE_DEF_CERTS/$domain)"
    echo "2) Custom path"
    read -r -p "Select: " path_opt
    
    local target_dir="$NODE_DEF_CERTS"
    if [[ "$path_opt" == "2" ]]; then
        read -r -p "Enter path: " custom_path
        custom_path=$(sanitize_input "$custom_path")
        if validate_path "$custom_path"; then
            target_dir="$custom_path"
        else
            ui_error "Invalid path!"
            return 1
        fi
    fi
    
    target_dir="$target_dir/$domain"
    mkdir -p "$target_dir" || { ui_error "Cannot create directory!"; return 1; }
    
    if cp -L "$le_path/fullchain.pem" "$target_dir/" && \
       cp -L "$le_path/privkey.pem" "$target_dir/"; then
        
        chmod 644 "$target_dir/fullchain.pem"
        chmod 600 "$target_dir/privkey.pem"
        
        # Update .env
        if [[ -f "$NODE_ENV" ]]; then
            sed -i '/SSL_CERT_FILE/d' "$NODE_ENV"
            sed -i '/SSL_KEY_FILE/d' "$NODE_ENV"
            echo "SSL_CERT_FILE = \"$target_dir/fullchain.pem\"" >> "$NODE_ENV"
            echo "SSL_KEY_FILE = \"$target_dir/privkey.pem\"" >> "$NODE_ENV"
            # FIX: recreate the container — env_file changes need a new container (MRM-031)
            recreate_service "node"
        else
            ui_warning "Node .env not found - manual config needed"
        fi
        
        ui_success "Node SSL configured!"
        echo -e "  Cert: ${CYAN}$target_dir/fullchain.pem${NC}"
        echo -e "  Key:  ${CYAN}$target_dir/privkey.pem${NC}"
        log_success "Node SSL configured for $domain"
    else
        ui_error "Failed to copy certificates!"
        return 1
    fi
}

_process_config() {
    local domain="$1"
    local le_path="/etc/letsencrypt/live/$domain"
    
    echo -e "\n${ORANGE}--- Config SSL (Inbounds) ---${NC}"
    
    if [[ ! -f "$le_path/fullchain.pem" ]]; then
        ui_error "Source certificate not found!"
        return 1
    fi
    
    local target_dir="$PANEL_DEF_CERTS/$domain"
    mkdir -p "$target_dir" || { ui_error "Cannot create directory!"; return 1; }
    
    if cp -L "$le_path/fullchain.pem" "$target_dir/" && \
       cp -L "$le_path/privkey.pem" "$target_dir/"; then
        
        chmod 755 "$target_dir"
        chmod 644 "$target_dir/fullchain.pem"
        chmod 600 "$target_dir/privkey.pem"
        
        ui_success "Inbound SSL configured!"
        echo -e "\n${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║     Copy these paths to your Inbound Settings:           ║${NC}"
        echo -e "${YELLOW}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${YELLOW}║${NC}  Cert: ${CYAN}$target_dir/fullchain.pem${NC}"
        echo -e "${YELLOW}║${NC}  Key:  ${CYAN}$target_dir/privkey.pem${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
        log_success "Inbound SSL configured for $domain"
    else
        ui_error "Failed to copy certificates!"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# MULTI-SERVER SYNC
# ═══════════════════════════════════════════════════════════════════════════

_offer_sync() {
    local -a domains=("$@")
    
    [[ ! -f "$SERVERS_FILE" || ! -s "$SERVERS_FILE" ]] && return
    
    local count
    count=$(wc -l < "$SERVERS_FILE" 2>/dev/null || echo "0")
    
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}$count server(s) configured.${NC}"
    read -r -p "Sync to other servers? (y/N): " sync_now
    
    if [[ "$sync_now" =~ ^[Yy]$ ]]; then
        for domain in "${domains[@]}"; do
            _sync_domain_to_all "$domain"
        done
    fi
}

_sync_domain_to_all() {
    local domain="$1"
    local cert_path="/etc/letsencrypt/live/$domain"
    
    [[ ! -d "$cert_path" ]] && return 1
    
    echo -e "\n${YELLOW}Syncing $domain to all servers...${NC}"
    
    while IFS='|' read -r name host port user path panel; do
        [[ -z "$name" ]] && continue
        
        echo -ne "  ${YELLOW}[$name]${NC} $host ... "
        
        if _sync_to_server "$host" "$port" "$user" "$path" "$domain" "$cert_path" "$panel"; then
            echo -e "${GREEN}✔${NC}"
        else
            echo -e "${RED}✘${NC}"
        fi
    done < "$SERVERS_FILE"
}

_sync_to_server() {
    local host="$1" port="$2" user="$3" remote_base="$4" domain="$5" local_path="$6" panel="$7"
    local remote_path="$remote_base/$domain"
    
    # Create directory
    if ! ssh -o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=yes -p "$port" \
         "$user@$host" "mkdir -p '$remote_path'" 2>/dev/null; then
        log_error "Failed to create directory on $host"
        return 1
    fi
    
    # Copy files
    if ! scp -o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=yes -P "$port" \
         "$local_path/fullchain.pem" "$local_path/privkey.pem" \
         "$user@$host:$remote_path/" 2>/dev/null; then
        log_error "Failed to copy files to $host"
        return 1
    fi
    
    # Set permissions and restart
    ssh -o BatchMode=yes -p "$port" "$user@$host" "
        chmod 644 '$remote_path/fullchain.pem' 2>/dev/null
        chmod 600 '$remote_path/privkey.pem' 2>/dev/null
        if [[ -n '$panel' && '$panel' != 'custom' ]]; then
            cd /opt/$panel 2>/dev/null && docker compose restart 2>/dev/null || \
            systemctl restart $panel 2>/dev/null
        fi
    " 2>/dev/null
    
    log_success "Synced $domain to $host"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# SERVER MANAGEMENT MENU
# ═══════════════════════════════════════════════════════════════════════════

multi_server_menu() {
    while true; do
        ui_header "🌐 MULTI-SERVER SSL SYNC"
        
        echo "1) 📋 List Servers"
        echo "2) ➕ Add Server"
        echo "3) ➖ Remove Server"
        echo "4) 🔄 Sync to All"
        echo "5) 🔄 Sync to Specific"
        echo "6) 🔑 Setup SSH Key"
        echo "7) 🧪 Test Connections"
        echo ""
        echo "0) ↩️  Back"
        echo ""
        read -r -p "Select: " opt
        
        case "$opt" in
            1) _list_servers ;;
            2) _add_server ;;
            3) _remove_server ;;
            4) _sync_all_servers ;;
            5) _sync_specific_server ;;
            6) _setup_ssh_keys ;;
            7) _test_all_connections ;;
            0) return ;;
        esac
    done
}

_list_servers() {
    ui_header "📋 CONFIGURED SERVERS"
    
    if [[ ! -f "$SERVERS_FILE" || ! -s "$SERVERS_FILE" ]]; then
        ui_warning "No servers configured."
        pause
        return
    fi
    
    printf "${GREEN}%-3s │ %-15s │ %-20s │ %-5s │ %s${NC}\n" "ID" "Name" "Host" "Port" "Path"
    echo "────┼─────────────────┼──────────────────────┼───────┼────────────────────"
    
    local idx=1
    while IFS='|' read -r name host port user path panel; do
        [[ -z "$name" ]] && continue
        printf "%-3s │ %-15s │ %-20s │ %-5s │ %s\n" "$idx" "$name" "$host" "$port" "$path"
        ((idx++))
    done < "$SERVERS_FILE"
    
    pause
}

_add_server() {
    ui_header "➕ ADD SERVER"
    
    local name host port user path panel_type panel_name
    
    read -r -p "Server name: " name
    name=$(sanitize_input "$name")
    [[ -z "$name" ]] && ui_error "Required." && pause && return
    
    read -r -p "Host/IP: " host
    host=$(sanitize_input "$host")
    [[ -z "$host" ]] && ui_error "Required." && pause && return
    
    read -r -p "SSH Port [22]: " port
    port="${port:-22}"
    
    read -r -p "SSH User [root]: " user
    user="${user:-root}"
    
    echo -e "\nPanel type:"
    echo "1) Pasarguard"
    echo "2) Custom"
    read -r -p "Select: " panel_type
    
    case "$panel_type" in
        1) panel_name="pasarguard"; path="/var/lib/pasarguard/certs" ;;
        2) 
            panel_name="custom"
            read -r -p "Remote cert path: " path
            path=$(sanitize_input "$path")
            ;;
        *) ui_error "Invalid." && pause && return ;;
    esac
    
    mkdir -p "$(dirname "$SERVERS_FILE")"
    echo "${name}|${host}|${port}|${user}|${path}|${panel_name}" >> "$SERVERS_FILE"
    
    ui_success "Server added!"
    log_info "Added server: $name ($host)"
    
    read -r -p "Test connection? (Y/n): " test_now
    [[ ! "$test_now" =~ ^[Nn]$ ]] && _test_connection "$host" "$port" "$user"
    
    pause
}

_remove_server() {
    ui_header "➖ REMOVE SERVER"
    
    [[ ! -f "$SERVERS_FILE" || ! -s "$SERVERS_FILE" ]] && ui_warning "No servers." && pause && return
    
    local idx=1
    local -a names=()
    
    while IFS='|' read -r name host port user path panel; do
        [[ -z "$name" ]] && continue
        echo "$idx) $name ($host)"
        names[$idx]="$name"
        ((idx++))
    done < "$SERVERS_FILE"
    
    read -r -p "Select (0=cancel): " sel
    [[ "$sel" == "0" || -z "$sel" ]] && return
    
    local remove_name="${names[$sel]}"
    [[ -z "$remove_name" ]] && ui_error "Invalid." && pause && return
    
    # Safe removal using temp file
    local tmp_file
    tmp_file=$(mktemp /tmp/ssl-manager-XXXXXX.tmp)
    grep -v "^${remove_name}|" "$SERVERS_FILE" > "$tmp_file"
    mv "$tmp_file" "$SERVERS_FILE"
    
    ui_success "Removed: $remove_name"
    log_info "Removed server: $remove_name"
    pause
}

_test_connection() {
    local host="$1" port="$2" user="$3"
    
    echo -e "${YELLOW}Testing $user@$host:$port...${NC}"
    
    if ssh -o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=yes -p "$port" "$user@$host" "echo OK" &>/dev/null; then
        ui_success "Connected!"
        return 0
    else
        ui_error "Failed!"
        echo -e "${YELLOW}Check: SSH running, key configured, firewall allows port $port${NC}"
        return 1
    fi
}

_test_all_connections() {
    ui_header "🧪 TEST ALL CONNECTIONS"
    
    [[ ! -f "$SERVERS_FILE" || ! -s "$SERVERS_FILE" ]] && ui_warning "No servers." && pause && return
    
    local success=0 failed=0
    
    while IFS='|' read -r name host port user path panel; do
        [[ -z "$name" ]] && continue
        
        echo -ne "${YELLOW}[$name]${NC} $host:$port ... "
        
        if ssh -n -o ConnectTimeout=5 -o BatchMode=yes -p "$port" "$user@$host" "exit" &>/dev/null; then
            echo -e "${GREEN}✔${NC}"
            ((success++))
        else
            echo -e "${RED}✘${NC}"
            ((failed++))
        fi
    done < "$SERVERS_FILE"
    
    echo -e "\n${GREEN}Success: $success${NC} | ${RED}Failed: $failed${NC}"
    pause
}

_setup_ssh_keys() {
    ui_header "🔑 SETUP SSH KEY"
    
    if [[ ! -f ~/.ssh/id_rsa ]]; then
        echo -e "${YELLOW}Generating SSH key...${NC}"
        ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
        ui_success "Key generated."
    else
        ui_success "Key exists."
    fi
    
    [[ ! -f "$SERVERS_FILE" || ! -s "$SERVERS_FILE" ]] && ui_warning "No servers." && pause && return
    
    echo -e "\n${YELLOW}Select server:${NC}\n"
    
    local idx=1
    local -a hosts=() ports=() users=()
    
    while IFS='|' read -r name host port user path panel; do
        [[ -z "$name" ]] && continue
        echo "$idx) $name ($host)"
        hosts[$idx]="$host"
        ports[$idx]="$port"
        users[$idx]="$user"
        ((idx++))
    done < "$SERVERS_FILE"
    
    echo "$idx) All servers"
    echo "0) Cancel"
    read -r -p "Select: " sel
    
    [[ "$sel" == "0" ]] && return
    
    if [[ "$sel" == "$idx" ]]; then
        for ((i=1; i<idx; i++)); do
            echo -e "\n${YELLOW}Setting up ${hosts[$i]}...${NC}"
            ssh-copy-id -p "${ports[$i]}" "${users[$i]}@${hosts[$i]}" 2>/dev/null || true
        done
    else
        [[ -z "${hosts[$sel]}" ]] && ui_error "Invalid." && pause && return
        ssh-copy-id -p "${ports[$sel]}" "${users[$sel]}@${hosts[$sel]}"
    fi
    
    ui_success "SSH key setup complete!"
    pause
}

_sync_all_servers() {
    ui_header "🔄 SYNC TO ALL SERVERS"
    
    [[ ! -f "$SERVERS_FILE" || ! -s "$SERVERS_FILE" ]] && ui_warning "No servers." && pause && return
    
    echo -e "${YELLOW}Select certificate:${NC}\n"
    
    local idx=1
    local -a domains=()
    
    for dir in /etc/letsencrypt/live/*/; do
        [[ ! -d "$dir" ]] && continue
        local domain
        domain=$(basename "$dir")
        [[ "$domain" == "README" ]] && continue
        domains[$idx]="$domain"
        echo "$idx) $domain"
        ((idx++))
    done
    
    [[ $idx -eq 1 ]] && ui_error "No certificates." && pause && return
    
    read -r -p "Select: " sel
    local selected="${domains[$sel]}"
    [[ -z "$selected" ]] && ui_error "Invalid." && pause && return
    
    _sync_domain_to_all "$selected"
    pause
}

_sync_specific_server() {
    ui_header "🔄 SYNC TO SPECIFIC SERVER"
    
    [[ ! -f "$SERVERS_FILE" || ! -s "$SERVERS_FILE" ]] && ui_warning "No servers." && pause && return
    
    # Select server
    echo -e "${YELLOW}Select server:${NC}\n"
    
    local idx=1
    local -a server_data=()
    
    while IFS='|' read -r name host port user path panel; do
        [[ -z "$name" ]] && continue
        echo "$idx) $name ($host)"
        server_data[$idx]="$name|$host|$port|$user|$path|$panel"
        ((idx++))
    done < "$SERVERS_FILE"
    
    read -r -p "Select: " server_sel
    [[ -z "${server_data[$server_sel]}" ]] && ui_error "Invalid." && pause && return
    
    # Select certificate
    echo -e "\n${YELLOW}Select certificate:${NC}\n"
    
    idx=1
    local -a domains=()
    
    for dir in /etc/letsencrypt/live/*/; do
        [[ ! -d "$dir" ]] && continue
        local domain
        domain=$(basename "$dir")
        [[ "$domain" == "README" ]] && continue
        domains[$idx]="$domain"
        echo "$idx) $domain"
        ((idx++))
    done
    
    [[ $idx -eq 1 ]] && ui_error "No certificates." && pause && return
    
    read -r -p "Select: " cert_sel
    local selected_domain="${domains[$cert_sel]}"
    [[ -z "$selected_domain" ]] && ui_error "Invalid." && pause && return
    
    # Parse server data
    IFS='|' read -r name host port user path panel <<< "${server_data[$server_sel]}"
    local cert_path="/etc/letsencrypt/live/$selected_domain"
    
    echo -e "\n${YELLOW}Syncing $selected_domain to $name...${NC}"
    
    if _sync_to_server "$host" "$port" "$user" "$path" "$selected_domain" "$cert_path" "$panel"; then
        ui_success "Sync completed!"
    else
        ui_error "Sync failed!"
    fi
    
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
# BACKUP CERTIFICATES
# ═══════════════════════════════════════════════════════════════════════════

backup_certificates() {
    ui_header "💾 BACKUP CERTIFICATES"
    init_logging
    detect_active_panel > /dev/null
    
    local backup_name
    backup_name="ssl-backup-$(date +%Y%m%d-%H%M%S)"
    local backup_path="$SSL_BACKUP_DIR/$backup_name"
    
    mkdir -p "$backup_path" || { ui_error "Cannot create backup directory!"; pause; return; }
    
    echo -e "${YELLOW}Creating backup...${NC}\n"
    
    # Backup Let's Encrypt
    if [[ -d "/etc/letsencrypt" ]]; then
        echo "  Backing up Let's Encrypt..."
        cp -r /etc/letsencrypt "$backup_path/" 2>/dev/null
    fi
    
    # Backup panel certs
    if [[ -d "$PANEL_DEF_CERTS" ]]; then
        echo "  Backing up panel certificates..."
        mkdir -p "$backup_path/panel-certs"
        cp -r "$PANEL_DEF_CERTS"/* "$backup_path/panel-certs/" 2>/dev/null
    fi
    
    # Create tarball
    echo "  Creating archive..."
    (cd "$SSL_BACKUP_DIR" && tar -czf "$backup_name.tar.gz" "$backup_name" 2>/dev/null)
    rm -rf "$backup_path"
    
    local final_path="$SSL_BACKUP_DIR/$backup_name.tar.gz"
    local size
    size=$(du -h "$final_path" 2>/dev/null | cut -f1)
    
    ui_success "Backup created!"
    echo -e "  ${YELLOW}Path:${NC} $final_path"
    echo -e "  ${YELLOW}Size:${NC} $size"
    
    log_success "Backup created: $final_path"
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
# AUTO-RENEWAL SETUP
# ═══════════════════════════════════════════════════════════════════════════
# AUTO-RENEWAL SETUP
# ═══════════════════════════════════════════════════════════════════════════

setup_auto_renewal() {
    ui_header "⏰ SETUP AUTO-RENEWAL"
    detect_active_panel > /dev/null

    local cron_file="/etc/cron.d/ssl-auto-renew"
    local wrapper="/opt/mrm-manager/ssl-auto-renew.sh"

    echo -e "${YELLOW}This will setup automatic certificate renewal.${NC}\n"
    echo "Schedule: Daily at 3:00 AM"
    echo "Action:  Stop web services + port-80 containers → renew →"
    echo "         copy certs to panel/node dirs → restore services"
    echo "Log:     ${SSL_LOG_DIR}/auto-renew.log"
    echo ""

    read -r -p "Proceed? (Y/n): " proceed
    [[ "$proceed" =~ ^[Nn]$ ]] && return

    mkdir -p "$(dirname "$wrapper")"

    # (MRM-040) A bare `certbot renew` in cron fails silently when the panel
    # container still owns port 80 — the challenge never reaches certbot.
    # The wrapper sources this module and reuses the exact same
    # stop/restore logic as the interactive flows.
    cat > "$wrapper" << WRAP_EOF
#!/bin/bash
# SSL Auto-Renewal wrapper - generated by MRM Manager
# Runs under cron. Must NOT be edited by hand; re-run 'mrm → SSL → Setup
# Auto-Renewal' after updating MRM.

source /opt/mrm-manager/ssl.sh
PANEL_CERTS="$PANEL_DEF_CERTS"
NODE_CERTS="$NODE_DEF_CERTS"

init_logging || exit 1
detect_active_panel > /dev/null
log_info "Auto-renew started (panel: ${PANEL_DIR:-?})"

stop_web_services

# Pass 1: HTTP-01 with standalone (web servers + port-80 containers stopped)
# Pass 2: plain renew — covers DNS-01 certs saved with their own plugin
certbot renew --standalone --quiet 2>>"$CERTBOT_DEBUG_LOG"
RC=\$?
if [[ \$RC -ne 0 ]]; then
    certbot renew --quiet 2>>"$CERTBOT_DEBUG_LOG"
    RC=\$?
fi

# Copy renewed LE certs into the panel/node cert dirs (MRM convention)
for dir in /etc/letsencrypt/live/*/; do
    domain=\$(basename "\$dir")
    [[ "\$domain" == "README" ]] && continue
    if [[ -d "\$PANEL_CERTS/\$domain" ]]; then
        cp -L "\$dir/fullchain.pem" "\$dir/privkey.pem" "\$PANEL_CERTS/\$domain/" 2>/dev/null
        chmod 644 "\$PANEL_CERTS/\$domain/fullchain.pem" 2>/dev/null
        chmod 600 "\$PANEL_CERTS/\$domain/privkey.pem" 2>/dev/null
        log_info "Updated panel cert: \$domain"
    fi
    if [[ -d "\$NODE_CERTS/\$domain" && "\$NODE_CERTS" != "\$PANEL_CERTS" ]]; then
        cp -L "\$dir/fullchain.pem" "\$dir/privkey.pem" "\$NODE_CERTS/\$domain/" 2>/dev/null
        chmod 644 "\$NODE_CERTS/\$domain/fullchain.pem" 2>/dev/null
        chmod 600 "\$NODE_CERTS/\$domain/privkey.pem" 2>/dev/null
        log_info "Updated node cert: \$domain"
    fi
done

restore_services
restart_panel_services "panel"
restart_panel_services "node"

log_info "Auto-renew finished (certbot rc=\$RC)"
exit 0
WRAP_EOF

    chmod 700 "$wrapper"

    # Cron entry (replaces the legacy deploy-hook approach)
    mkdir -p "$(dirname "$cron_file")" 2>/dev/null
    cat > "$cron_file" << EOF
# SSL Auto-Renewal - MRM Manager
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 * * * root /opt/mrm-manager/ssl-auto-renew.sh >> $SSL_LOG_DIR/auto-renew.log 2>&1
EOF

    chmod 644 "$cron_file"

    # Legacy hook from previous versions — no longer used
    rm -f /opt/mrm-manager/ssl-renew-hook.sh

    ui_success "Auto-renewal configured!"
    echo -e "  ${YELLOW}Wrapper:${NC} $wrapper"
    echo -e "  ${YELLOW}Cron:${NC} $cron_file"
    echo -e "  ${YELLOW}Log:${NC} $SSL_LOG_DIR/auto-renew.log"
    echo -e "\n${CYAN}Test now with:${NC} bash $wrapper"
    echo -e "${CYAN}Dry-run only:${NC}  certbot renew --dry-run"

    log_success "Auto-renewal configured (wrapper mode, MRM-040)"
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
# SHOW SSL PATHS
# ═══════════════════════════════════════════════════════════════════════════

show_detailed_paths() {
    ui_header "📁 SSL FILE PATHS"
    detect_active_panel > /dev/null
    
    echo -e "${GREEN}--- Panel Certificates ($PANEL_DEF_CERTS) ---${NC}"
    if [[ -d "$PANEL_DEF_CERTS" ]]; then
        for dir in "$PANEL_DEF_CERTS"/*; do
            [[ -d "$dir" ]] || continue
            local dom
            dom=$(basename "$dir")
            echo -e "  ${YELLOW}$dom${NC}"
            [[ -f "$dir/fullchain.pem" ]] && echo -e "    Cert: ${CYAN}$dir/fullchain.pem${NC}"
            [[ -f "$dir/privkey.pem" ]] && echo -e "    Key:  ${CYAN}$dir/privkey.pem${NC}"
        done
    else
        echo "  No certificates."
    fi
    # Flat/default certs at the certs root (MRM-033)
    for flat in fullchain.pem ssl_cert.pem; do
        [[ -f "$PANEL_DEF_CERTS/$flat" ]] && echo -e "  ${YELLOW}default (flat)${NC} ${CYAN}$PANEL_DEF_CERTS/$flat${NC}"
    done
    
    echo -e "\n${PURPLE}--- Node Certificates ($NODE_DEF_CERTS) ---${NC}"
    if [[ -d "$NODE_DEF_CERTS" && "$NODE_DEF_CERTS" != "$PANEL_DEF_CERTS" ]]; then
        for dir in "$NODE_DEF_CERTS"/*; do
            [[ -d "$dir" ]] || continue
            local dom
            dom=$(basename "$dir")
            echo -e "  ${YELLOW}$dom${NC}"
            [[ -f "$dir/fullchain.pem" ]] && echo -e "    Cert: ${CYAN}$dir/fullchain.pem${NC}"
            [[ -f "$dir/privkey.pem" ]] && echo -e "    Key:  ${CYAN}$dir/privkey.pem${NC}"
        done
    else
        echo "  No certificates."
    fi
    # Flat/default certs at the certs root (MRM-033)
    for flat in ssl_cert.pem fullchain.pem; do
        [[ -f "$NODE_DEF_CERTS/$flat" ]] && echo -e "  ${YELLOW}default (flat)${NC} ${CYAN}$NODE_DEF_CERTS/$flat${NC}"
    done
    
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
# VIEW LOGS
# ═══════════════════════════════════════════════════════════════════════════

view_ssl_logs() {
    ui_header "📋 SSL LOGS"
    
    echo "1) SSL Manager Log (last 50)"
    echo "2) Certbot Log (last 50)"
    echo "3) Clear Logs"
    echo "0) Back"
    read -r -p "Select: " opt
    
    case "$opt" in
        1) 
            [[ -f "$SSL_LOG_FILE" ]] && tail -n 50 "$SSL_LOG_FILE" || echo "Not found."
            pause
            ;;
        2) 
            [[ -f "$CERTBOT_DEBUG_LOG" ]] && tail -n 50 "$CERTBOT_DEBUG_LOG" || echo "Not found."
            pause
            ;;
        3) 
            : > "$SSL_LOG_FILE" 2>/dev/null
            : > "$CERTBOT_DEBUG_LOG" 2>/dev/null
            ui_success "Cleared."
            pause
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN MENU
# ═══════════════════════════════════════════════════════════════════════════

ssl_menu() {
    init_logging
    
    while true; do
        # FIX: only clear on a real terminal (MRM-034)
        if [ -t 1 ]; then
            clear
        fi
        ui_header "🔐 SSL MANAGEMENT v${SSL_VERSION}"
        detect_active_panel > /dev/null
        
        echo -e "${CYAN}Panel: $(basename "$PANEL_DIR" 2>/dev/null || echo 'unknown')${NC}\n"
        
        echo "1)  🔐 Request New SSL Certificate"
        echo "2)  📅 View Certificate Expiry Status"
        echo "3)  📁 Show SSL File Paths"
        echo "4)  🔄 Renew Expiring Certificates"
        echo "5)  🎯 Renew Specific Certificate"
        echo "6)  🌐 Multi-Server Sync"
        echo "7)  💾 Backup Certificates"
        echo "8)  ⏰ Setup Auto-Renewal"
        echo "9)  📋 View Logs"
        echo ""
        echo "0)  ↩️  Back"
        echo ""
        read -r -p "Select: " opt
        
        case "$opt" in
            1) ssl_wizard ;;
            2) show_certificate_expiry ;;
            3) show_detailed_paths ;;
            4) renew_expiring_certificates ;;
            5) renew_specific_certificate ;;
            6) multi_server_menu ;;
            7) backup_certificates ;;
            8) setup_auto_renewal ;;
            9) view_ssl_logs ;;
            0) return ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════════════════
# ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════

main() {
    # Check root
    if ! check_root; then
        exit 3
    fi
    
    # Check dependencies
    if ! check_dependencies; then
        exit 2
    fi
    
    # Initialize
    init_logging
    detect_active_panel > /dev/null
    
    # Run menu
    ssl_menu
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
