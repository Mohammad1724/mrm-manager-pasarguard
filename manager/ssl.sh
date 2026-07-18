#!/bin/bash
# MRM Manager v1.0.0

# ═══════════════════════════════════════════════════════════════════════════
# SSL MANAGEMENT MODULE v1.0.0
# ═══════════════════════════════════════════════════════════════════════════
# Author: MRM Manager Team
# License: MIT
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


# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly ORANGE='\033[0;33m'
readonly NC='\033[0m'
readonly BOLD='\033[1m'

# Paths (can be overridden via environment)
readonly SSL_LOG_DIR="${SSL_LOG_DIR:-/var/log/ssl-manager}"
readonly SSL_LOG_FILE="${SSL_LOG_DIR}/ssl-manager.log"
readonly CERTBOT_DEBUG_LOG="${SSL_LOG_DIR}/certbot-debug.log"
readonly SERVERS_FILE="${SERVERS_FILE:-/opt/mrm-manager/ssl-servers.conf}"
readonly SSL_BACKUP_DIR="${SSL_BACKUP_DIR:-/opt/mrm-manager/ssl-backups}"
readonly CONFIG_DIR="${CONFIG_DIR:-/opt/mrm-manager}"

[ -r "$CONFIG_DIR/versions.conf" ] && source "$CONFIG_DIR/versions.conf"
SSL_VERSION="${SSL_VERSION:-1.0.1}"

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

        clear
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
        ["marzban"]="/opt/marzban:/var/lib/marzban/certs:/opt/marzban/.env:/opt/marzban-node:/var/lib/marzban-node/certs:/opt/marzban-node/.env"
        ["x-ui"]="/opt/x-ui:/var/lib/x-ui/certs:/opt/x-ui/x-ui.db:/opt/x-ui:/var/lib/x-ui/certs:/opt/x-ui/.env"
        ["hiddify"]="/opt/hiddify:/opt/hiddify/certs:/opt/hiddify/.env:/opt/hiddify:/opt/hiddify/certs:/opt/hiddify/.env"
        ["pasarguard"]="/opt/pasarguard:/var/lib/pasarguard/certs:/opt/pasarguard/.env:/opt/pg-node:/var/lib/pg-node/certs:/opt/pg-node/.env"
        ["rebecca"]="/opt/rebecca:/var/lib/rebecca/certs:/opt/rebecca/.env:/opt/rebecca-node:/var/lib/rebecca-node/certs:/opt/rebecca-node/.env"
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

    # Default fallback
    PANEL_DIR="/opt/panel"
    PANEL_DEF_CERTS="/var/lib/panel/certs"
    PANEL_ENV="/opt/panel/.env"
    NODE_DIR="/opt/node"
    NODE_DEF_CERTS="/var/lib/node/certs"
    NODE_ENV="/opt/node/.env"
    echo "unknown"
    return 1
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
    
    for service in nginx apache2 httpd lighttpd; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            stop_service "$service" && ((stopped++))
        fi
    done
    
    # Also kill any process on port 80
    if command -v fuser &>/dev/null; then
        fuser -k ${HTTP_PORT}/tcp 2>/dev/null
    fi
    
    # Wait for ports to be released
    sleep 2
    
    return 0
}

# Restore all stopped services
restore_services() {
    local -a services_to_restore=("${_SERVICES_STOPPED[@]}")
    
    for service in "${services_to_restore[@]}"; do
        start_service "$service"
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
            else
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

# ═══════════════════════════════════════════════════════════════════════════
# PORT CHECKING
# ═══════════════════════════════════════════════════════════════════════════

check_port_availability() {
    local port="$1"
    local max_retries="${2:-3}"
    local retry=0
    
    while [[ $retry -lt $max_retries ]]; do
        if ! ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            return 0
        fi
        ((retry++))
        sleep 1
    done
    
    local service
    service=$(ss -tlnp 2>/dev/null | grep ":${port} " | awk '{print $NF}' | head -1)
    ui_warning "Port $port is in use by: $service"
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
        echo -e "${YELLOW}Server IPv6:  ${server