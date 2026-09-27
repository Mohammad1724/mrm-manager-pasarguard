#!/bin/bash
# MRM Manager ssl.sh — SSL certificate management
# License: GPL-3.0
#
# Requires: Bash 4.0+, certbot, openssl, curl
# Exit codes: 0 ok · 1 error · 2 dependency missing · 3 permission · 4 network · 5 certificate

set -o pipefail

# ─── Constants & configuration ───────────────────────────────────────────────

# Guard against double-source (prevents "readonly: variable is read only" error)
if [[ -z "${_SSL_MODULE_INITIALIZED:-}" ]]; then
_SSL_MODULE_INITIALIZED=1

# Paths (can be overridden via environment)
readonly SSL_LOG_DIR="${SSL_LOG_DIR:-/var/log/ssl-manager}"
readonly SSL_LOG_FILE="${SSL_LOG_DIR}/ssl-manager.log"
readonly CERTBOT_DEBUG_LOG="${SSL_LOG_DIR}/certbot-debug.log"
readonly SERVERS_FILE="${SERVERS_FILE:-/opt/mrm-manager/ssl-servers.conf}"
readonly SSL_BACKUP_DIR="${SSL_BACKUP_DIR:-/opt/mrm-manager/ssl-backups}"
# Module directory: explicit CONFIG_DIR, then MRM_DIR, then wherever this file
# lives, then the default install path (same rule as the other modules).
if [ -z "${CONFIG_DIR:-}" ]; then
    if [ -n "${MRM_DIR:-}" ] && [ -r "${MRM_DIR}/utils.sh" ]; then
        CONFIG_DIR="$MRM_DIR"
    elif [ -r "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/utils.sh" ]; then
        CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    else
        CONFIG_DIR="/opt/mrm-manager"
    fi
fi
readonly CONFIG_DIR

[ -r "$CONFIG_DIR/versions.conf" ] && source "$CONFIG_DIR/versions.conf"
SSL_VERSION="${SSL_VERSION:-1.0.10}"

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

# ─── Global State ──────────────────────────────────────────────────────

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

# ─── Load External Modules ─────────────────────────────────────────────

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

# UI helpers come from ui.sh (loaded above). The module uses the full design
# system (ui_kv, ui_cmd, ui_table_*, …) so a partial stand-in set would only
# hide the problem — fail clearly instead.
if ! declare -f ui_header >/dev/null 2>&1 || ! declare -f ui_cmd >/dev/null 2>&1; then
    echo "ssl.sh: ui.sh not found in ${CONFIG_DIR} — run 'mrm update' or reinstall MRM Manager" >&2
    exit 1
fi
# Colors are defined by ui.sh; keep empty defaults so echo -e never prints raw names
: "${RED:=}" "${GREEN:=}" "${YELLOW:=}" "${BLUE:=}" "${PURPLE:=}" "${CYAN:=}" "${ORANGE:=}" "${NC:=}" "${BOLD:=}" "${DIM:=}"

# ─── Logging System ────────────────────────────────────────────────────

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
    [ -d "$SSL_LOG_DIR" ] || return 0
    { echo "[$timestamp] [$level] $message" >> "$SSL_LOG_FILE"; } 2>/dev/null || true
}

log_info() { log_message "INFO" "$1"; }
log_error() { log_message "ERROR" "$1"; }
log_success() { log_message "SUCCESS" "$1"; }
log_warning() { log_message "WARNING" "$1"; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && log_message "DEBUG" "$1"; }

# ─── Cleanup & Signal Handling ─────────────────────────────────────────

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

# ─── Input Validation & Sanitization ───────────────────────────────────

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

# ─── Dependency Checking ───────────────────────────────────────────────

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
        ui_error "Missing required tools: ${missing[*]}"
        ui_cmd "apt install -y ${missing[*]}" "install them"
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

# ─── Panel Detection ───────────────────────────────────────────────────

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

# ─── Service Management (Centralized) ──────────────────────────────────

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
            ui_error "Container $container did not start — run: docker start $container"
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

# ─── Port Checking ─────────────────────────────────────────────────────

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

# ─── DNS Validation ────────────────────────────────────────────────────

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
        ui_kv "A records" "${domain_ipv4[*]:-none}"
        ui_kv "AAAA records" "${domain_ipv6[*]:-none}"
        ui_kv "Server IPv4" "${server_ipv4:-none}"
        ui_kv "Server IPv6" "${server_ipv6:-none}"
        log_warning "DNS mismatch for $domain"

        if [[ "$skip_mismatch" == "true" ]]; then
            return 1
        fi

        ui_confirm "Continue anyway?" || return 1
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

# ─── Certificate Expiry Functions ──────────────────────────────────────

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

# ─── Certificate Discovery ─────────────────────────────────────────────

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

    # An empty array would still print one blank line, which callers count as
    # "1 certificate" — print nothing instead.
    [ ${#results[@]} -gt 0 ] && printf '%s\n' "${results[@]}"
    return 0
}

# ─── Show Certificate Expiry Status ────────────────────────────────────

show_certificate_expiry() {
    detect_active_panel > /dev/null
    ui_header "Certificate Expiry" "Panel: $(basename "$PANEL_DIR" 2>/dev/null || echo unknown) · warn <${EXPIRY_WARNING_DAYS}d · critical <${EXPIRY_CRITICAL_DAYS}d"

    local -a all_certs
    local -a expired_domains=()
    local -a expiring_domains=()

    # MRM-044: mark the ACTIVE dashboard / node-gRPC domains taken from the
    # .env files so the operator can see at a glance which cert serves what
    local panel_dom node_dom
    panel_dom=$(_env_cert_domain "$PANEL_ENV" "UVICORN_SSL_CERTFILE" 2>/dev/null) || panel_dom=""
    node_dom=$(_env_cert_domain "$NODE_ENV" "SSL_CERT_FILE" 2>/dev/null) || node_dom=""

    mapfile -t all_certs < <(discover_all_certificates)

    if [[ ${#all_certs[@]} -eq 0 ]]; then
        ui_warning "No certificates found."
        pause
        return
    fi

    ui_table_header "%-4s  %-30s  %-11s  %5s  %-9s  %s" "Src" "Domain" "Expires" "Days" "Status" "Role"

    local cert_info source domain cert_path days status
    for cert_info in "${all_certs[@]}"; do
        IFS='|' read -r source domain cert_path days status <<< "$cert_info"

        local expiry_date formatted_date
        expiry_date=$(get_cert_expiry_date "$cert_path")
        formatted_date=$(date -d "$expiry_date" "+%Y-%m-%d" 2>/dev/null || echo "${expiry_date:0:10}")

        case "$status" in
            EXPIRED|CRITICAL) expired_domains+=("$domain") ;;
            WARNING) expiring_domains+=("$domain") ;;
        esac

        local src_text mode role=""
        case "$source" in
            le)    src_text="LE" ;;
            panel) src_text="PNL" ;;
            node)  src_text="NOD" ;;
            *)     src_text="$source" ;;
        esac
        # get_cert_status returns VALID / WARNING / CRITICAL / EXPIRED / UNKNOWN
        case "$status" in
            VALID|OK) mode=ok ;;
            WARNING)  mode=warn ;;
            UNKNOWN)  mode=off ;;
            *)        mode=bad ;;
        esac
        [[ -n "$panel_dom" && "$domain" == "$panel_dom" ]] && role="dashboard"
        [[ -z "$role" && -n "$node_dom" && "$domain" == "$node_dom" ]] && role="node gRPC"

        # Status column is coloured — printf %s would print raw escape text, so
        # the glyph+text is built with ui_state and padded manually (MRM-038)
        local status_cell
        status_cell="$(ui_state "$mode" "$status")"
        printf '%s%b%-4s  %-30s  %-11s  %5s  %b%b%*s  %b%s%b\n' "$UI_PAD" "$UI_C_TEXT" "$src_text" "$(ui_truncate "$domain" 30)" \
            "${formatted_date:0:11}" "$days" "$NC" "$status_cell" "$(( 9 - ${#status} - 2 ))" "" "$UI_C_MUTED" "$role" "$NC"
    done

    echo ""
    ui_note "Source: LE = Let's Encrypt · PNL = panel certs dir only · NOD = node certs dir only"

    if [[ ${#expired_domains[@]} -gt 0 ]]; then
        echo ""
        ui_error "${#expired_domains[@]} certificate(s) expired or critical:"
        local d
        for d in "${expired_domains[@]}"; do ui_bullet "$d"; done
    fi
    if [[ ${#expiring_domains[@]} -gt 0 ]]; then
        echo ""
        ui_warning "${#expiring_domains[@]} certificate(s) expiring soon:"
        local d
        for d in "${expiring_domains[@]}"; do ui_bullet "$d"; done
    fi

    local total_issues=$(( ${#expired_domains[@]} + ${#expiring_domains[@]} ))
    if [[ $total_issues -gt 0 ]]; then
        echo ""
        ui_menu_title "Quick actions"
        ui_menu_item 1 "Renew all expiring / expired certificates"
        ui_menu_item 2 "Renew a specific certificate"
        ui_menu_back
        local action
        ui_select action
        case "$action" in
            1) renew_expiring_certificates ;;
            2) renew_specific_certificate ;;
        esac
    else
        pause
    fi
}

# ─── Renew Expiring Certificates ───────────────────────────────────────

renew_expiring_certificates() {
    ui_header "Renew Expiring Certificates"
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
        ui_success "All certificates are up to date."
        pause
        return 0
    fi

    ui_kv "Need renewal" "$total certificate(s)"
    echo ""
    local d days status mode
    if [[ $total_le -gt 0 ]]; then
        ui_section "Let's Encrypt certificates ($total_le)"
        for d in "${le_domains[@]}"; do
            IFS='|' read -r days status <<< "${domain_info[$d]}"
            case "$status" in WARNING) mode=warn ;; *) mode=bad ;; esac
            ui_kv_state "$d" "$mode" "$status" "$days days left"
        done
        echo ""
    fi
    if [[ $total_panel -gt 0 ]]; then
        ui_section "Panel / node only certificates ($total_panel)"
        ui_note "Not managed by Let's Encrypt — a new certificate will be requested."
        for d in "${panel_only_domains[@]}"; do
            IFS='|' read -r days status <<< "${domain_info[$d]}"
            case "$status" in WARNING) mode=warn ;; *) mode=bad ;; esac
            ui_kv_state "$d" "$mode" "$status" "$days days left"
        done
        echo ""
    fi

    [[ $total_le -gt 0 ]] && ui_menu_item 1 "Renew Let's Encrypt certificates" "$total_le"
    [[ $total_panel -gt 0 ]] && ui_menu_item 2 "Request new certificates for panel / node only" "$total_panel"
    [[ $total_le -gt 0 && $total_panel -gt 0 ]] && ui_menu_item 3 "Process all" "$total"
    ui_menu_back "Cancel"
    local choice
    ui_select choice
    
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

# ─── Helper: Renew Let'S Encrypt Certificates ──────────────────────────

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
        ui_note "(no certbot output captured)"
        return
    fi

    echo ""
    ui_section "certbot report · $domain"
    grep -vE '^[[:space:]]*$' "$output_file" 2>/dev/null | tail -n 12 | sed "s/^/${UI_PAD}  /"
    echo ""

    if grep -qE 'Failed to bind to port|Address already in use' "$output_file" 2>/dev/null; then
        ui_warning "Port $HTTP_PORT is still occupied — find and stop the web server / container owning it."
    elif grep -qiE 'Invalid response from|404|403' "$output_file" 2>/dev/null; then
        ui_warning "Let's Encrypt reached the server but got an invalid challenge response."
        ui_note "Make sure DNS for $domain points to THIS server (no CDN / proxy in between)."
    elif grep -qiE 'timeout|timed out' "$output_file" 2>/dev/null; then
        ui_warning "Let's Encrypt could not reach port 80 — check firewall rules and the DNS target."
    elif grep -qiE 'live directory exists' "$output_file" 2>/dev/null; then
        ui_warning "A stale /etc/letsencrypt live directory blocked the new certificate."
        ui_note "MRM should have backed it up and removed it — run the renewal again."
    elif grep -qiE 'No certificate found|No certs were found' "$output_file" 2>/dev/null; then
        ui_warning "certbot has no renewal profile for '$domain' and the automatic reissue also failed."
        ui_note "Check DNS, then see: /var/log/letsencrypt/letsencrypt.log"
    fi
    ui_note "Full log: $CERTBOT_DEBUG_LOG"
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
    ui_ask saved "No saved Let's Encrypt email found — email"
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
    ui_task_note "stale certificate backed up: $backup"
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
        echo ""
        ui_warning "DNS pre-check — these are likely to fail:"
        local bad_entry
        for bad_entry in "${dns_bad[@]}"; do
            ui_bullet "$bad_entry"
        done
        ui_note "Renewal continues anyway — it only works if HTTP actually reaches this server."
        echo ""
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
        ui_warning "Renewal profile check:"
        local note
        for note in "${missing_profile[@]}" "${broken_profile[@]}" "${san_covered_by[@]}"; do
            ui_bullet "$note"
        done
        echo ""
    fi

    ui_step 1 3 "Stopping web services"
    stop_web_services

    if ! check_port_availability "$HTTP_PORT" 5; then
        ui_error "Port $HTTP_PORT is still in use"
        restore_services
        return 1
    fi

    ui_step 2 3 "Renewing certificates"

    local renewed=0 failed=0 rc=0
    local tmp_out auth renew_name san_covered
    local reissue_email=""
    local recovery=0 bconf bbackup
    tmp_out=$(mktemp /tmp/ssl-manager-cb.XXXXXX)

    for domain in "${domains[@]}"; do
        ui_task "Renewing $domain"

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
                ui_task_note "broken renewal profile backed up: $bbackup"
                recovery=1
            fi
        fi
        if [[ $recovery -eq 1 ]]; then
            alt_name=$(_find_renewal_name_for_domain "$domain")
            if [[ -n "$alt_name" ]]; then
                ui_task_note "covered by cert '$alt_name' — renewing that one"
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
                ui_task_note "renewal profile missing — requesting a fresh certificate"
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
            ui_task_done ok "$domain renewed"
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
            ui_task_done bad "$domain failed"
            log_error "Failed to renew: $domain"
            failed=$((failed + 1))
            _archive_certbot_failure "$tmp_out" "$domain"
            _show_certbot_failure "$tmp_out" "$domain"
        fi
        : > "$tmp_out"
    done
    rm -f "$tmp_out"

    echo ""
    ui_step 3 3 "Restoring services"
    restore_services
    # Only restart panel/node when something actually renewed (fresh certs to load)
    if [[ $renewed -gt 0 ]]; then
        restart_panel_services "panel"
        restart_panel_services "node"
    fi

    echo ""
    if [[ $failed -eq 0 ]]; then ui_box_start ok "Renewal finished"; else ui_box_start warn "Renewal finished with errors"; fi
    ui_box_line "Renewed" "$renewed"
    ui_box_line "Failed" "$failed"
    ui_box_end

    _offer_sync "${domains[@]}"

    return 0
}

# ─── Helper: Request New Certificates ──────────────────────────────────

_request_new_certificates() {
    local -a domains=("$@")

    [[ ${#domains[@]} -eq 0 ]] && return 0

    echo ""
    ui_section "New certificates"
    ui_note "These domains are not managed by Let's Encrypt yet — a new certificate is requested for each."
    echo ""

    # Get email
    local email=""
    local saved_email
    saved_email=$(grep -h "email" /etc/letsencrypt/renewal/*.conf 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d ' ')

    if [[ -n "$saved_email" ]]; then
        ui_kv "Saved email" "$saved_email"
        if ui_confirm "Use this email?" y; then
            email="$saved_email"
        fi
    fi

    if [[ -z "$email" ]]; then
        ui_ask email "Email for Let's Encrypt notices"
        email=$(sanitize_input "$email")
        if ! validate_email "$email"; then
            ui_error "Invalid email format."
            return 1
        fi
    fi

    echo ""
    ui_step 1 4 "Validating DNS"

    local -a valid_domains=()
    local domain dns_out
    for domain in "${domains[@]}"; do
        ui_task "Checking $domain"
        # (MRM-039) capture the check output so the FAILURE REASON is visible
        if dns_out=$(validate_domain_dns "$domain" "true" 2>&1); then
            ui_task_done ok
            valid_domains+=("$domain")
        else
            ui_task_done bad "skipped"
            printf '%s\n' "$dns_out" | sed "s/^/${UI_PAD}  /"
            log_warning "DNS failed for $domain"
        fi
    done

    if [[ ${#valid_domains[@]} -eq 0 ]]; then
        ui_error "No domain passed DNS validation."
        return 1
    fi

    echo ""
    ui_step 2 4 "Stopping web services"
    stop_web_services

    if ! check_port_availability "$HTTP_PORT" 5; then
        ui_error "Port $HTTP_PORT is still in use"
        restore_services
        return 1
    fi

    ui_step 3 4 "Requesting certificates"

    local success=0 failed=0 rc=0
    local tmp_out
    tmp_out=$(mktemp /tmp/ssl-manager-cb.XXXXXX)

    for domain in "${valid_domains[@]}"; do
        ui_task "Requesting $domain"

        rc=0
        certbot certonly --standalone \
            --non-interactive --agree-tos \
            --email "$email" \
            --preferred-challenges http \
            -d "$domain" >"$tmp_out" 2>&1 || rc=$?

        if [[ $rc -eq 0 ]]; then
            ui_task_done ok
            log_success "New certificate: $domain"
            success=$((success + 1))
            _update_cert_paths "$domain"
        else
            ui_task_done bad
            log_error "Failed to get certificate: $domain"
            failed=$((failed + 1))
            _archive_certbot_failure "$tmp_out" "$domain"
            _show_certbot_failure "$tmp_out" "$domain"
        fi
        : > "$tmp_out"
    done

    rm -f "$tmp_out"

    echo ""
    ui_step 4 4 "Restoring services"
    restore_services
    # Only restart panel/node when something actually succeeded (MRM-039)
    if [[ $success -gt 0 ]]; then
        restart_panel_services "panel"
        restart_panel_services "node"
    fi

    echo ""
    if [[ $failed -eq 0 ]]; then ui_box_start ok "Certificates requested"; else ui_box_start warn "Finished with errors"; fi
    ui_box_line "Issued" "$success"
    ui_box_line "Failed" "$failed"
    ui_box_end

    _offer_sync "${valid_domains[@]}"

    return 0
}

# ─── Helper: Update Certificate Paths ──────────────────────────────────

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
        ui_task_note "panel copy updated: $PANEL_DEF_CERTS/$domain"
    fi
    
    # Update node certs
    if [[ -d "$NODE_DEF_CERTS/$domain" && "$NODE_DEF_CERTS" != "$PANEL_DEF_CERTS" ]]; then
        cp -L "$le_path/fullchain.pem" "$NODE_DEF_CERTS/$domain/" 2>/dev/null
        cp -L "$le_path/privkey.pem" "$NODE_DEF_CERTS/$domain/" 2>/dev/null
        chmod 644 "$NODE_DEF_CERTS/$domain/fullchain.pem" 2>/dev/null
        chmod 600 "$NODE_DEF_CERTS/$domain/privkey.pem" 2>/dev/null
        ui_task_note "node copy updated: $NODE_DEF_CERTS/$domain"
    fi
}

# ─── Renew Specific Certificate ────────────────────────────────────────

renew_specific_certificate() {
    ui_header "Renew a Certificate"
    detect_active_panel > /dev/null

    local -a cert_list=()
    local idx=1
    local source domain cert_path days status

    while IFS='|' read -r source domain cert_path days status; do
        [[ "$domain" == "default" ]] && continue   # flat/default certs: not renewable (MRM-033)
        cert_list+=("$source|$domain|$cert_path|$days|$status")
        local src_text
        case "$source" in
            le) src_text="LE" ;;
            panel) src_text="PNL" ;;
            node) src_text="NOD" ;;
            *) src_text="$source" ;;
        esac
        ui_menu_item "$idx" "$domain" "$src_text · $status · $days days"
        idx=$((idx + 1))
    done < <(discover_all_certificates)

    if [[ $idx -eq 1 ]]; then
        ui_error "No certificates found."
        pause
        return
    fi

    ui_menu_back "Cancel"
    local selection
    ui_select selection
    [[ "$selection" == "0" || -z "$selection" ]] && return

    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -lt 1 ]] || [[ "$selection" -ge "$idx" ]]; then
        ui_error "Invalid selection."
        pause
        return
    fi

    local selected_idx=$((selection - 1))
    IFS='|' read -r source domain cert_path days status <<< "${cert_list[$selected_idx]}"

    echo ""
    ui_kv "Selected" "$domain"
    if [[ "$source" == "le" ]]; then
        ui_kv "Source" "Let's Encrypt"
        echo ""
        ui_confirm "Renew this certificate?" y || return
        _renew_le_certificates "$domain"
    else
        ui_kv "Source" "$( [[ "$source" == panel ]] && echo "panel certs dir" || echo "node certs dir" )"
        ui_note "This certificate is not managed by Let's Encrypt — a new one will be requested."
        echo ""
        ui_confirm "Request a new certificate?" y || return
        _request_new_certificates "$domain"
    fi

    pause
}

# ─── Request New Certificate (SSL Wizard) ──────────────────────────────

ssl_wizard() {
    init_logging
    detect_active_panel > /dev/null
    ui_header "New Certificate" "Panel: $(basename "$PANEL_DIR" 2>/dev/null || echo unknown) · Certs: ${PANEL_DEF_CERTS:-unknown}"

    if ! check_dependencies; then
        pause
        return 2
    fi

    ui_note "Let's Encrypt (HTTP-01). Every domain must already point to this server."
    echo ""

    # Get domain count
    local count
    ui_ask count "How many domains? (1-10)" "1"

    if ! [[ "$count" =~ ^[0-9]+$ ]] || [[ "$count" -lt 1 ]] || [[ "$count" -gt 10 ]]; then
        ui_error "Invalid number — enter a value from 1 to 10."
        pause
        return 1
    fi

    # Get domains
    local -a domain_list=()
    local domain_input
    for (( i=1; i<=count; i++ )); do
        while true; do
            ui_ask domain_input "Domain $i"
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
        ui_ask email "Email for Let's Encrypt notices"
        email=$(sanitize_input "$email")

        if validate_email "$email"; then
            break
        fi
        ui_error "Invalid email format."
    done

    local primary_domain="${domain_list[0]}"
    echo ""

    # Request certificate
    if ! _request_certificate "$email" "${domain_list[@]}"; then
        ui_error "Certificate request failed."
        ui_note "Log: $CERTBOT_DEBUG_LOG"
        pause
        return 5
    fi

    # Verify certificate exists
    if [[ ! -d "/etc/letsencrypt/live/$primary_domain" ]]; then
        ui_error "Certificate was not created."
        pause
        return 5
    fi

    echo ""
    ui_success "Certificate issued for $primary_domain"
    echo ""

    # Configure usage
    ui_menu_title "Where should this certificate be used?"
    ui_menu_item 1 "Panel" "dashboard HTTPS"
    ui_menu_item 2 "Node" "gRPC / REST between panel and node"
    ui_menu_item 3 "Inbounds" "copy paths for the Xray config"
    ui_menu_item 4 "All of the above"
    ui_menu_back "Skip"
    local usage_opt
    ui_select usage_opt

    case "$usage_opt" in
        1) _process_panel "$primary_domain" ;;
        2) _process_node "$primary_domain" ;;
        3) _process_config "$primary_domain" ;;
        4)
            _process_panel "$primary_domain"
            _process_node "$primary_domain"
            _process_config "$primary_domain"
            ;;
        0|"") ;;
        *) ui_error "Invalid selection." ;;
    esac

    _offer_sync "$primary_domain"

    log_info "SSL wizard completed for $primary_domain"
    pause
}

# ─── Request Certificate (Core Function) ───────────────────────────────

_request_certificate() {
    local email="$1"
    shift
    local -a domains=("$@")
    
    log_info "Starting certificate request for: ${domains[*]}"
    
    # Step 1: Check Let's Encrypt API
    ui_step 1 5 "Checking Let's Encrypt API"
    if ! curl -s --connect-timeout "$CURL_TIMEOUT" https://acme-v02.api.letsencrypt.org/directory > /dev/null; then
        ui_error "Let's Encrypt API is unreachable"
        log_error "LE API unreachable"
        return 4
    fi
    ui_success "API reachable"

    # Step 2: Validate DNS
    ui_step 2 5 "Validating DNS"
    for domain in "${domains[@]}"; do
        if ! validate_domain_dns "$domain"; then
            log_error "DNS validation failed for $domain"
            return 1
        fi
    done

    # Step 3: Configure firewall
    ui_step 3 5 "Opening firewall ports $HTTP_PORT / $HTTPS_PORT"
    if command -v ufw &>/dev/null; then
        ufw allow "$HTTP_PORT/tcp" &>/dev/null
        ufw allow "$HTTPS_PORT/tcp" &>/dev/null
    fi

    # Step 4: Stop services
    ui_step 4 5 "Preparing for the HTTP challenge"
    stop_web_services

    if ! check_port_availability "$HTTP_PORT" 5; then
        ui_error "Port $HTTP_PORT is still in use"
        restore_services
        return 1
    fi
    ui_success "Port $HTTP_PORT is free"
    
    # Build domain flags
    local domain_flags=""
    for d in "${domains[@]}"; do
        domain_flags+=" -d $d"
    done
    
    # Step 5: Request certificate
    ui_step 5 5 "Requesting certificate"
    ui_note "This can take up to two minutes."
    
    # shellcheck disable=SC2086
    if certbot certonly --standalone \
        --non-interactive --agree-tos \
        --email "$email" \
        --preferred-challenges http \
        --http-01-port "$HTTP_PORT" \
        $domain_flags > "$CERTBOT_DEBUG_LOG" 2>&1; then
        
        ui_success "Certificate obtained"
        log_success "Certificate obtained for ${domains[*]}"
        restore_services
        return 0
    else
        ui_error "Certificate request failed"
        _show_certbot_failure "$CERTBOT_DEBUG_LOG" "${domains[0]}"
        log_error "Certbot failed"
        restore_services
        return 5
    fi
}

# ─── Process Panel/Node/Config SSL ─────────────────────────────────────

_process_panel() {
    local domain="$1"
    local le_path="/etc/letsencrypt/live/$domain"
    
    echo ""
    ui_section "Panel SSL"

    if [[ ! -f "$le_path/fullchain.pem" ]]; then
        ui_error "Source certificate not found: $le_path"
        return 1
    fi

    ui_menu_item 1 "Default location" "$PANEL_DEF_CERTS/$domain"
    ui_menu_item 2 "Custom path"
    local path_opt custom_path
    ui_select path_opt

    local target_dir="$PANEL_DEF_CERTS"
    if [[ "$path_opt" == "2" ]]; then
        ui_ask custom_path "Directory"
        custom_path=$(sanitize_input "$custom_path")
        if validate_path "$custom_path"; then
            target_dir="$custom_path"
        else
            ui_error "Invalid path."
            return 1
        fi
    fi

    target_dir="$target_dir/$domain"
    mkdir -p "$target_dir" || { ui_error "Cannot create $target_dir"; return 1; }
    
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

        ui_success "Panel SSL configured"
        ui_kv "Certificate" "$target_dir/fullchain.pem"
        ui_kv "Private key" "$target_dir/privkey.pem"
        log_success "Panel SSL configured for $domain"
    else
        ui_error "Failed to copy the certificate files"
        return 1
    fi
}

_process_node() {
    local domain="$1"
    local le_path="/etc/letsencrypt/live/$domain"
    
    echo ""
    ui_section "Node SSL"

    if [[ ! -f "$le_path/fullchain.pem" ]]; then
        ui_error "Source certificate not found: $le_path"
        return 1
    fi

    ui_menu_item 1 "Default location" "$NODE_DEF_CERTS/$domain"
    ui_menu_item 2 "Custom path"
    local path_opt custom_path
    ui_select path_opt

    local target_dir="$NODE_DEF_CERTS"
    if [[ "$path_opt" == "2" ]]; then
        ui_ask custom_path "Directory"
        custom_path=$(sanitize_input "$custom_path")
        if validate_path "$custom_path"; then
            target_dir="$custom_path"
        else
            ui_error "Invalid path."
            return 1
        fi
    fi

    target_dir="$target_dir/$domain"
    mkdir -p "$target_dir" || { ui_error "Cannot create $target_dir"; return 1; }
    
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
            ui_warning "Node .env not found — set SSL_CERT_FILE / SSL_KEY_FILE manually"
        fi

        ui_success "Node SSL configured"
        ui_kv "Certificate" "$target_dir/fullchain.pem"
        ui_kv "Private key" "$target_dir/privkey.pem"
        log_success "Node SSL configured for $domain"
    else
        ui_error "Failed to copy the certificate files"
        return 1
    fi
}

_process_config() {
    local domain="$1"
    local le_path="/etc/letsencrypt/live/$domain"
    
    echo ""
    ui_section "Inbound SSL"

    if [[ ! -f "$le_path/fullchain.pem" ]]; then
        ui_error "Source certificate not found: $le_path"
        return 1
    fi

    local target_dir="$PANEL_DEF_CERTS/$domain"
    mkdir -p "$target_dir" || { ui_error "Cannot create $target_dir"; return 1; }
    
    if cp -L "$le_path/fullchain.pem" "$target_dir/" && \
       cp -L "$le_path/privkey.pem" "$target_dir/"; then
        
        chmod 755 "$target_dir"
        chmod 644 "$target_dir/fullchain.pem"
        chmod 600 "$target_dir/privkey.pem"
        
        ui_success "Inbound SSL files ready"
        echo ""
        ui_box_start info "Use these paths in the inbound TLS settings"
        ui_box_line "Certificate" "$target_dir/fullchain.pem"
        ui_box_line "Private key" "$target_dir/privkey.pem"
        ui_box_end
        log_success "Inbound SSL configured for $domain"
    else
        ui_error "Failed to copy the certificate files"
        return 1
    fi
}

# ─── Multi-Server Sync ─────────────────────────────────────────────────

_offer_sync() {
    local -a domains=("$@")
    
    [[ ! -f "$SERVERS_FILE" || ! -s "$SERVERS_FILE" ]] && return
    
    local count
    count=$(wc -l < "$SERVERS_FILE" 2>/dev/null || echo "0")
    
    echo ""
    ui_kv "Remote servers" "$count configured"
    if ui_confirm "Sync the certificate(s) to the remote servers?"; then
        for domain in "${domains[@]}"; do
            _sync_domain_to_all "$domain"
        done
    fi
}

_sync_domain_to_all() {
    local domain="$1"
    local cert_path="/etc/letsencrypt/live/$domain"
    
    [[ ! -d "$cert_path" ]] && return 1
    
    echo ""
    ui_note "Syncing $domain to all servers"

    while IFS='|' read -r name host port user path panel; do
        [[ -z "$name" ]] && continue
        ui_task "$name ($host)"
        if _sync_to_server "$host" "$port" "$user" "$path" "$domain" "$cert_path" "$panel"; then
            ui_task_done ok
        else
            ui_task_done bad
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

# ─── Server Management Menu ────────────────────────────────────────────

multi_server_menu() {
    local opt
    while true; do
        local count=0
        [[ -f "$SERVERS_FILE" ]] && count=$(grep -c . "$SERVERS_FILE" 2>/dev/null || echo 0)
        ui_header "Multi-Server SSL Sync" "Servers: $count · $SERVERS_FILE"
        ui_menu_item 1 "List servers"
        ui_menu_item 2 "Add server"
        ui_menu_item 3 "Remove server"
        ui_menu_item 4 "Sync a certificate to all servers"
        ui_menu_item 5 "Sync a certificate to one server"
        ui_menu_item 6 "Set up SSH key" "ssh-copy-id"
        ui_menu_item 7 "Test connections"
        ui_menu_back
        ui_select opt

        case "$opt" in
            1) _list_servers ;;
            2) _add_server ;;
            3) _remove_server ;;
            4) _sync_all_servers ;;
            5) _sync_specific_server ;;
            6) _setup_ssh_keys ;;
            7) _test_all_connections ;;
            0) return ;;
            *) ui_invalid ;;
        esac
    done
}

# Prints numbered menu items for every configured server; fills the given
# array name with "name|host|port|user|path|panel" (1-based).
_server_menu_items() {
    local -n __out="$1"
    local idx=1 name host port user path panel
    __out=()
    while IFS='|' read -r name host port user path panel; do
        [[ -z "$name" ]] && continue
        ui_menu_item "$idx" "$name" "$user@$host:$port"
        __out[$idx]="$name|$host|$port|$user|$path|$panel"
        ((idx++))
    done < "$SERVERS_FILE"
    return 0
}

# Prints numbered menu items for every Let's Encrypt certificate; fills the
# given array name with domains (1-based).
_cert_menu_items() {
    local -n __out="$1"
    local idx=1 dir domain
    __out=()
    for dir in /etc/letsencrypt/live/*/; do
        [[ ! -d "$dir" ]] && continue
        domain=$(basename "$dir")
        [[ "$domain" == "README" ]] && continue
        __out[$idx]="$domain"
        ui_menu_item "$idx" "$domain"
        ((idx++))
    done
    return 0
}

_no_servers() {
    ui_warning "No servers configured yet — add one first."
    pause
}

_list_servers() {
    ui_header "Configured Servers" "$SERVERS_FILE"

    if [[ ! -f "$SERVERS_FILE" || ! -s "$SERVERS_FILE" ]]; then
        _no_servers
        return
    fi

    ui_table_header "%-3s  %-16s  %-22s  %-5s  %-6s  %s" "ID" "Name" "Host" "Port" "User" "Remote path"
    local idx=1 name host port user path panel
    while IFS='|' read -r name host port user path panel; do
        [[ -z "$name" ]] && continue
        ui_table_row "$idx" "$(ui_truncate "$name" 16)" "$(ui_truncate "$host" 22)" "$port" "$user" "$path"
        ((idx++))
    done < "$SERVERS_FILE"

    pause
}

_add_server() {
    ui_header "Add Server"

    local name host port user path panel_type panel_name

    ui_ask name "Server name"
    name=$(sanitize_input "$name")
    [[ -z "$name" ]] && { ui_error "Server name is required."; pause; return; }

    ui_ask host "Host / IP"
    host=$(sanitize_input "$host")
    [[ -z "$host" ]] && { ui_error "Host is required."; pause; return; }

    ui_ask port "SSH port" "22"
    port="${port:-22}"

    ui_ask user "SSH user" "root"
    user="${user:-root}"

    echo ""
    ui_menu_title "Remote panel type"
    ui_menu_item 1 "PasarGuard" "/var/lib/pasarguard/certs"
    ui_menu_item 2 "Custom path"
    ui_select panel_type

    case "$panel_type" in
        1) panel_name="pasarguard"; path="/var/lib/pasarguard/certs" ;;
        2)
            panel_name="custom"
            ui_ask path "Remote certificate directory"
            path=$(sanitize_input "$path")
            ;;
        *) ui_invalid; return ;;
    esac

    mkdir -p "$(dirname "$SERVERS_FILE")"
    echo "${name}|${host}|${port}|${user}|${path}|${panel_name}" >> "$SERVERS_FILE"

    echo ""
    ui_success "Server added: $name ($user@$host:$port)"
    log_info "Added server: $name ($host)"

    if ui_confirm "Test the connection now?" y; then
        _test_connection "$host" "$port" "$user"
    fi
    pause
}

_remove_server() {
    ui_header "Remove Server"

    [[ ! -f "$SERVERS_FILE" || ! -s "$SERVERS_FILE" ]] && { _no_servers; return; }

    local -a servers=()
    _server_menu_items servers
    ui_menu_back "Cancel"
    local sel
    ui_select sel
    [[ "$sel" == "0" || -z "$sel" ]] && return

    local remove_name="${servers[$sel]%%|*}"
    [[ -z "$remove_name" ]] && { ui_error "Invalid selection."; pause; return; }

    if ! ui_confirm "Remove $remove_name?"; then ui_cancelled; pause; return; fi

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

    ui_task "Connecting to $user@$host:$port"
    if ssh -o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=yes -p "$port" "$user@$host" "echo OK" &>/dev/null; then
        ui_task_done ok "connected"
        return 0
    fi
    ui_task_done bad "failed"
    ui_note "Check that SSH is running, the key is installed and the firewall allows port $port."
    return 1
}

_test_all_connections() {
    ui_header "Test Connections"

    [[ ! -f "$SERVERS_FILE" || ! -s "$SERVERS_FILE" ]] && { _no_servers; return; }

    local success=0 failed=0 name host port user path panel

    while IFS='|' read -r name host port user path panel; do
        [[ -z "$name" ]] && continue
        ui_task "$name ($user@$host:$port)"
        if ssh -n -o ConnectTimeout=5 -o BatchMode=yes -p "$port" "$user@$host" "exit" &>/dev/null; then
            ui_task_done ok
            ((success++))
        else
            ui_task_done bad
            ((failed++))
        fi
    done < "$SERVERS_FILE"

    echo ""
    ui_kv "Reachable" "$success"
    ui_kv "Failed" "$failed"
    pause
}

_setup_ssh_keys() {
    ui_header "SSH Key Setup" "installs this server's public key on the remote servers"

    if [[ ! -f ~/.ssh/id_rsa ]]; then
        ui_note "Generating an SSH key pair…"
        ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
        ui_success "Key generated: ~/.ssh/id_rsa"
    else
        ui_success "Key present: ~/.ssh/id_rsa"
    fi

    [[ ! -f "$SERVERS_FILE" || ! -s "$SERVERS_FILE" ]] && { _no_servers; return; }

    echo ""
    ui_menu_title "Select a server"
    local -a servers=()
    _server_menu_items servers
    local all_idx=$(( ${#servers[@]} + 1 ))
    ui_menu_item "$all_idx" "All servers"
    ui_menu_back "Cancel"
    local sel
    ui_select sel
    [[ "$sel" == "0" || -z "$sel" ]] && return

    local entry name host port user path panel i
    if [[ "$sel" == "$all_idx" ]]; then
        for ((i=1; i<all_idx; i++)); do
            IFS='|' read -r name host port user path panel <<< "${servers[$i]}"
            echo ""
            ui_note "Installing key on $name ($host)…"
            ssh-copy-id -p "$port" "$user@$host" 2>/dev/null || true
        done
    else
        entry="${servers[$sel]}"
        [[ -z "$entry" ]] && { ui_error "Invalid selection."; pause; return; }
        IFS='|' read -r name host port user path panel <<< "$entry"
        ssh-copy-id -p "$port" "$user@$host"
    fi

    echo ""
    ui_success "SSH key setup finished"
    pause
}

_sync_all_servers() {
    ui_header "Sync to All Servers"

    [[ ! -f "$SERVERS_FILE" || ! -s "$SERVERS_FILE" ]] && { _no_servers; return; }

    ui_menu_title "Select a certificate"
    local -a domains=()
    _cert_menu_items domains
    [[ ${#domains[@]} -eq 0 ]] && { ui_error "No Let's Encrypt certificates found."; pause; return; }
    ui_menu_back "Cancel"

    local sel
    ui_select sel
    [[ "$sel" == "0" || -z "$sel" ]] && return
    local selected="${domains[$sel]}"
    [[ -z "$selected" ]] && { ui_error "Invalid selection."; pause; return; }

    _sync_domain_to_all "$selected"
    pause
}

_sync_specific_server() {
    ui_header "Sync to One Server"

    [[ ! -f "$SERVERS_FILE" || ! -s "$SERVERS_FILE" ]] && { _no_servers; return; }

    ui_menu_title "Select a server"
    local -a servers=()
    _server_menu_items servers
    ui_menu_back "Cancel"
    local server_sel
    ui_select server_sel
    [[ "$server_sel" == "0" || -z "$server_sel" ]] && return
    [[ -z "${servers[$server_sel]}" ]] && { ui_error "Invalid selection."; pause; return; }

    echo ""
    ui_menu_title "Select a certificate"
    local -a domains=()
    _cert_menu_items domains
    [[ ${#domains[@]} -eq 0 ]] && { ui_error "No Let's Encrypt certificates found."; pause; return; }
    ui_menu_back "Cancel"

    local cert_sel
    ui_select cert_sel
    [[ "$cert_sel" == "0" || -z "$cert_sel" ]] && return
    local selected_domain="${domains[$cert_sel]}"
    [[ -z "$selected_domain" ]] && { ui_error "Invalid selection."; pause; return; }

    local name host port user path panel
    IFS='|' read -r name host port user path panel <<< "${servers[$server_sel]}"
    local cert_path="/etc/letsencrypt/live/$selected_domain"

    echo ""
    ui_task "Syncing $selected_domain to $name ($host)"
    if _sync_to_server "$host" "$port" "$user" "$path" "$selected_domain" "$cert_path" "$panel"; then
        ui_task_done ok
    else
        ui_task_done bad
    fi

    pause
}

# ─── Backup Certificates ───────────────────────────────────────────────

backup_certificates() {
    ui_header "Backup Certificates" "$SSL_BACKUP_DIR"
    init_logging
    detect_active_panel > /dev/null

    local backup_name
    backup_name="ssl-backup-$(date +%Y%m%d-%H%M%S)"
    local backup_path="$SSL_BACKUP_DIR/$backup_name"

    mkdir -p "$backup_path" || { ui_error "Cannot create $backup_path"; pause; return; }

    # Backup Let's Encrypt
    if [[ -d "/etc/letsencrypt" ]]; then
        ui_task "Copying /etc/letsencrypt"
        cp -r /etc/letsencrypt "$backup_path/" 2>/dev/null && ui_task_done ok || ui_task_done warn "partial"
    fi

    # Backup panel certs
    if [[ -d "$PANEL_DEF_CERTS" ]]; then
        ui_task "Copying panel certificates"
        mkdir -p "$backup_path/panel-certs"
        cp -r "$PANEL_DEF_CERTS"/* "$backup_path/panel-certs/" 2>/dev/null && ui_task_done ok || ui_task_done warn "partial"
    fi

    # Create tarball
    ui_task "Compressing archive"
    if (cd "$SSL_BACKUP_DIR" && tar -czf "$backup_name.tar.gz" "$backup_name" 2>/dev/null); then
        ui_task_done ok
    else
        ui_task_done bad
        rm -rf "$backup_path"
        ui_error "Could not create the archive"
        pause
        return 1
    fi
    rm -rf "$backup_path"

    local final_path="$SSL_BACKUP_DIR/$backup_name.tar.gz"
    local size
    size=$(du -h "$final_path" 2>/dev/null | cut -f1)

    echo ""
    ui_box_start ok "Certificate backup created"
    ui_box_line "File" "$final_path"
    ui_box_line "Size" "$size"
    ui_box_end

    log_success "Backup created: $final_path"
    pause
}

# ─── Auto-Renewal Setup ────────────────────────────────────────────────
# AUTO-RENEWAL SETUP
# ═══════════════════════════════════════════════════════════════════════════

setup_auto_renewal() {
    ui_header "Auto-Renewal"
    detect_active_panel > /dev/null

    local cron_file="/etc/cron.d/ssl-auto-renew"
    local wrapper="/opt/mrm-manager/ssl-auto-renew.sh"

    if [[ -f "$cron_file" ]]; then
        ui_kv_state "Status" ok "Configured" "$cron_file"
    else
        ui_kv_state "Status" off "Not configured"
    fi
    ui_kv "Schedule" "daily at 03:00"
    ui_kv "Action" "stop web services and port-80 containers › renew › copy certs to panel / node dirs › restore"
    ui_kv "Log" "${SSL_LOG_DIR}/auto-renew.log"
    echo ""

    ui_confirm "Install / refresh the auto-renewal job?" y || return

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

    echo ""
    ui_success "Auto-renewal configured"
    ui_kv "Wrapper" "$wrapper"
    ui_kv "Cron" "$cron_file"
    ui_kv "Log" "$SSL_LOG_DIR/auto-renew.log"
    echo ""
    ui_cmd "bash $wrapper" "run the renewal now"
    ui_cmd "certbot renew --dry-run" "dry run only"

    log_success "Auto-renewal configured (wrapper mode, MRM-040)"
    pause
}

# ─── Show SSL Paths ────────────────────────────────────────────────────

show_detailed_paths() {
    detect_active_panel > /dev/null
    ui_header "Certificate File Paths"

    _list_cert_dir() {
        local base="$1" title="$2" dir dom flat found=0
        ui_section "$title · ${base:-unknown}"
        if [[ -n "$base" && -d "$base" ]]; then
            for dir in "$base"/*; do
                [[ -d "$dir" ]] || continue
                dom=$(basename "$dir")
                [[ -f "$dir/fullchain.pem" || -f "$dir/privkey.pem" ]] || continue
                found=1
                ui_text "${BOLD}$dom${NC}"
                [[ -f "$dir/fullchain.pem" ]] && ui_kv "  Certificate" "$dir/fullchain.pem"
                [[ -f "$dir/privkey.pem" ]] && ui_kv "  Private key" "$dir/privkey.pem"
            done
            # Flat/default certs at the certs root (MRM-033)
            for flat in fullchain.pem ssl_cert.pem; do
                [[ -f "$base/$flat" ]] && { found=1; ui_kv "default (flat)" "$base/$flat"; }
            done
        fi
        [[ $found -eq 0 ]] && ui_note "No certificates."
        echo ""
    }

    _list_cert_dir "$PANEL_DEF_CERTS" "Panel certificates"
    if [[ -n "$NODE_DEF_CERTS" && "$NODE_DEF_CERTS" != "$PANEL_DEF_CERTS" ]]; then
        _list_cert_dir "$NODE_DEF_CERTS" "Node certificates"
    fi
    ui_section "Let's Encrypt · /etc/letsencrypt/live"
    local le_found=0 dir
    for dir in /etc/letsencrypt/live/*/; do
        [[ -d "$dir" && "$(basename "$dir")" != "README" ]] || continue
        le_found=1
        ui_kv "$(basename "$dir")" "${dir%/}"
    done
    [[ $le_found -eq 0 ]] && ui_note "No certificates."

    pause
}

# ─── View Logs ─────────────────────────────────────────────────────────

view_ssl_logs() {
    ui_header "SSL Logs" "$SSL_LOG_DIR"

    ui_menu_item 1 "SSL manager log" "last 50 lines"
    ui_menu_item 2 "certbot log" "last 50 lines"
    ui_menu_item 3 "Clear logs"
    ui_menu_back
    local opt
    ui_select opt

    case "$opt" in
        1)
            echo ""
            if [[ -s "$SSL_LOG_FILE" ]]; then tail -n 50 "$SSL_LOG_FILE"; else ui_note "No entries yet."; fi
            pause
            ;;
        2)
            echo ""
            if [[ -s "$CERTBOT_DEBUG_LOG" ]]; then tail -n 50 "$CERTBOT_DEBUG_LOG"; else ui_note "No entries yet."; fi
            pause
            ;;
        3)
            if ui_confirm "Clear both log files?"; then
                : > "$SSL_LOG_FILE" 2>/dev/null
                : > "$CERTBOT_DEBUG_LOG" 2>/dev/null
                ui_success "Logs cleared"
            else
                ui_cancelled
            fi
            pause
            ;;
    esac
}

# ─── Main Menu ─────────────────────────────────────────────────────────

ssl_menu() {
    init_logging
    local opt

    while true; do
        detect_active_panel > /dev/null
        ui_header "SSL Certificates" "Panel: $(basename "$PANEL_DIR" 2>/dev/null || echo unknown) · Certs: ${PANEL_DEF_CERTS:-unknown}"

        # Compact status line: how many certs and the nearest expiry
        local -a certs=()
        mapfile -t certs < <(discover_all_certificates 2>/dev/null)
        if [[ ${#certs[@]} -gt 0 ]]; then
            local min_days=99999 min_dom="" c source domain cert_path days status
            for c in "${certs[@]}"; do
                IFS='|' read -r source domain cert_path days status <<< "$c"
                if [[ "$days" =~ ^-?[0-9]+$ && "$days" -lt "$min_days" ]]; then min_days=$days; min_dom=$domain; fi
            done
            if [[ $min_days -le $EXPIRY_CRITICAL_DAYS ]]; then
                ui_kv_state "Certificates" bad "${#certs[@]} found" "$min_dom expires in $min_days days"
            elif [[ $min_days -le $EXPIRY_WARNING_DAYS ]]; then
                ui_kv_state "Certificates" warn "${#certs[@]} found" "$min_dom expires in $min_days days"
            else
                ui_kv_state "Certificates" ok "${#certs[@]} found" "nearest expiry: $min_dom in $min_days days"
            fi
        else
            ui_kv_state "Certificates" off "None found"
        fi
        if [[ -f /etc/cron.d/ssl-auto-renew ]]; then
            ui_kv_state "Auto-renewal" ok "Enabled" "daily 03:00"
        else
            ui_kv_state "Auto-renewal" off "Disabled"
        fi
        echo ""

        ui_menu_item 1 "Request a new certificate"
        ui_menu_item 2 "Certificate expiry status"
        ui_menu_item 3 "Renew expiring certificates"
        ui_menu_item 4 "Renew a specific certificate"
        ui_menu_item 5 "Set up auto-renewal"
        ui_menu_item 6 "Multi-server sync"
        ui_menu_item 7 "Back up certificates"
        ui_menu_item 8 "Certificate file paths"
        ui_menu_item 9 "View logs"
        ui_menu_back
        ui_select opt

        case "$opt" in
            1) ssl_wizard ;;
            2) show_certificate_expiry ;;
            3) renew_expiring_certificates ;;
            4) renew_specific_certificate ;;
            5) setup_auto_renewal ;;
            6) multi_server_menu ;;
            7) backup_certificates ;;
            8) show_detailed_paths ;;
            9) view_ssl_logs ;;
            0) return ;;
            *) ui_invalid ;;
        esac
    done
}

# ─── Entry Point ───────────────────────────────────────────────────────

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
