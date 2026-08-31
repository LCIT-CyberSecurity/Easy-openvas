#!/bin/bash

# Easy-OpenVAS Installer
#
# Deploys the Greenbone Community Edition container stack.
#
# Supported deployment modes:
#   - Fresh Debian 13 server:
#     Docker CE and Docker Compose v2 are installed before deploying OpenVAS.
#
#   - Existing Docker server:
#     The existing Docker environment is validated and reused without being
#     upgraded, reconfigured, restarted, or otherwise modified.
#
# The installer configures the OpenVAS service FQDN and performs basic DNS,
# port availability, and Docker Compose validation checks before deployment.

set -e

DOCKER_CMD="${EASY_OPENVAS_DOCKER_CMD:-docker}"
OPENVAS_DIR="${EASY_OPENVAS_BASE_DIR:-/opt/openvas}"
COMPOSE_FILE="${EASY_OPENVAS_COMPOSE_FILE:-$OPENVAS_DIR/compose.yaml}"
OS_RELEASE_FILE="${EASY_OPENVAS_OS_RELEASE:-/etc/os-release}"
SS_CMD="${EASY_OPENVAS_SS_CMD:-ss}"
DPKG_QUERY_CMD="${EASY_OPENVAS_DPKG_QUERY_CMD:-dpkg-query}"
NPROC_CMD="${EASY_OPENVAS_NPROC_CMD:-nproc}"
DF_CMD="${EASY_OPENVAS_DF_CMD:-df}"
MEMINFO_FILE="${EASY_OPENVAS_MEMINFO:-/proc/meminfo}"
SKIP_ROOT_CHECK="${EASY_OPENVAS_SKIP_ROOT:-false}"

ok() { echo "[OK] $*"; }
info() { echo "[INFO] $*"; }
warning() { echo "[WARNING] $*"; }
error() { echo "[ERROR] $*" >&2; }

# Require root only for the default system installation path.
# Tests and custom base directories can bypass this guard without changing
# privileged host locations.
require_root() {
  if [ "$SKIP_ROOT_CHECK" = "true" ] || [ "$OPENVAS_DIR" != "/opt/openvas" ]; then
    return 0
  fi

  if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root."
    echo "Example: sudo ./Openvas-installer.sh" >&2
    exit 1
  fi
}

# Normalize user-provided hostnames before validation and Compose injection.
normalize_fqdn() {
  local FQDN="$1"
  FQDN="$(printf '%s' "$FQDN" | tr '[:upper:]' '[:lower:]')"
  FQDN="${FQDN%.}"
  printf '%s' "$FQDN"
}

# Detect IPv4-looking values so they are not accepted as OpenVAS service FQDNs.
is_ipv4_address() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

# Validate the DNS name format expected for browser-facing OpenVAS access.
is_valid_fqdn() {
  local FQDN="$1"
  [ -n "$FQDN" ] || return 1
  [ "${#FQDN}" -le 253 ] || return 1
  [[ "$FQDN" == *.* ]] || return 1
  ! is_ipv4_address "$FQDN" || return 1
  [[ "$FQDN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

# Derive a convenient OpenVAS service FQDN from the host domain.
# The generated value is only a default suggestion and can be overridden.
suggest_openvas_fqdn() {
  local HOST_FQDN DOMAIN CANDIDATE
  HOST_FQDN="$(normalize_fqdn "$1")"
  ! is_ipv4_address "$HOST_FQDN" || return 0
  [[ "$HOST_FQDN" == *.* ]] || return 0
  DOMAIN="${HOST_FQDN#*.}"
  CANDIDATE="openvas.$DOMAIN"
  if is_valid_fqdn "$CANDIDATE"; then
    printf '%s' "$CANDIDATE"
  fi
}

# Prompt until a valid OpenVAS FQDN is provided.
# The suggested value is accepted only when it passes the same validation.
prompt_openvas_fqdn() {
  local HOST_FQDN="$1" DEFAULT_FQDN INPUT NORMALIZED
  DEFAULT_FQDN="$(suggest_openvas_fqdn "$HOST_FQDN")"

  echo "Detected host FQDN: $HOST_FQDN" >&2
  while true; do
    if [ -n "$DEFAULT_FQDN" ]; then
      printf 'OpenVAS FQDN [%s]:\n> ' "$DEFAULT_FQDN" >&2
    else
      printf 'OpenVAS FQDN:\n> ' >&2
    fi

    if ! IFS= read -r INPUT; then
      error "Invalid OpenVAS FQDN."
      return 1
    fi

    if [ -z "$INPUT" ] && [ -n "$DEFAULT_FQDN" ]; then
      NORMALIZED="$DEFAULT_FQDN"
    else
      NORMALIZED="$(normalize_fqdn "$INPUT")"
    fi

    if is_valid_fqdn "$NORMALIZED"; then
      printf '%s\n' "$NORMALIZED"
      return 0
    fi

    error "Invalid OpenVAS FQDN."
  done
}

# DNS resolution is informational only because the DNS record may be
# provisioned before or after Easy-OpenVAS installation.
check_openvas_dns() {
  local FQDN="$1" GETENT_CMD OUTPUT IPS
  GETENT_CMD="${EASY_OPENVAS_GETENT_CMD:-getent}"
  OUTPUT="$("$GETENT_CMD" ahostsv4 "$FQDN" 2>/dev/null || true)"
  if [ -z "$OUTPUT" ]; then
    OUTPUT="$("$GETENT_CMD" hosts "$FQDN" 2>/dev/null || true)"
  fi

  IPS="$(printf '%s\n' "$OUTPUT" | awk 'NF { print $1 }' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if [ -n "$IPS" ]; then
    ok "DNS name $FQDN resolves to $IPS"
  else
    warning "DNS name $FQDN does not currently resolve."
    warning "Create or verify the DNS entry before accessing OpenVAS with this name."
  fi
}

# Configure Greenbone's native nginx host and origin settings for the
# OpenVAS service FQDN instead of changing internal Docker hostnames.
configure_gvm_config_fqdn() {
  local TMP ORIGINAL_MODE
  ORIGINAL_MODE="$(stat -c '%a' "$COMPOSE_FILE")"
  TMP="$(mktemp)"
  if ! awk -v host="$OPENVAS_FQDN" '
    function emit_fqdn() {
      if (emitted) return
      print "      NGINX_HOST: \"" host "\""
      print "      NGINX_ACCESS_CONTROL_ALLOW_ORIGIN_HEADER: \"https://" host "\""
      emitted=1
    }
    /^  [A-Za-z0-9_-]+:$/ {
      if (svc == "gvm-config" && in_env) {
        emit_fqdn()
        in_env=0
      }
      svc=($0 == "  gvm-config:") ? "gvm-config" : ""
      if (svc == "gvm-config") seen_svc=1
      print
      next
    }
    svc == "gvm-config" && /^    environment:$/ {
      seen_env=1
      in_env=1
      emitted=0
      print
      next
    }
    svc == "gvm-config" && in_env && !/^      / {
      emit_fqdn()
      in_env=0
      print
      next
    }
    svc == "gvm-config" && in_env && /^      NGINX_HOST:/ { next }
    svc == "gvm-config" && in_env && /^      NGINX_ACCESS_CONTROL_ALLOW_ORIGIN_HEADER:/ { next }
    { print }
    END {
      if (svc == "gvm-config" && in_env) emit_fqdn()
      if (!seen_svc || !seen_env) exit 1
    }
  ' "$COMPOSE_FILE" > "$TMP"; then
    rm -f "$TMP"
    error "Unsupported Greenbone Compose structure."
    return 1
  fi
  mv -f "$TMP" "$COMPOSE_FILE"
  chmod "$ORIGINAL_MODE" "$COMPOSE_FILE"
}

# Validate the generated Compose configuration before pulling or starting
# containers to avoid partially deploying an invalid stack.
validate_docker_compose_config() {
  if "$DOCKER_CMD" compose -f "$COMPOSE_FILE" config >/dev/null; then
    ok "Docker Compose configuration valid"
    return 0
  fi

  error "Docker Compose configuration is invalid."
  return 1
}

# Check Docker CLI availability, with test overrides kept local to this script.
docker_command_exists() {
  case "${EASY_OPENVAS_DOCKER_PRESENT:-}" in
    true) return 0 ;;
    false) return 1 ;;
  esac
  command -v "$DOCKER_CMD" >/dev/null 2>&1
}

# Confirm the Docker daemon can answer API requests.
docker_daemon_operational() {
  "$DOCKER_CMD" info >/dev/null 2>&1
}

# Require Docker Compose v2 through the Docker CLI plugin interface.
docker_compose_available() {
  "$DOCKER_CMD" compose version >/dev/null 2>&1
}

# Detect Docker CE package conflicts without resolving them automatically.
# Package removal remains an explicit administrator decision.
conflicting_docker_packages() {
  local PKG STATUS
  for PKG in docker.io docker-doc docker-compose podman-docker containerd runc; do
    STATUS="$($DPKG_QUERY_CMD -W -f='${Status}' "$PKG" 2>/dev/null || true)"
    if [ "$STATUS" = "install ok installed" ]; then
      printf '%s\n' "$PKG"
    fi
  done
}

# Never remove existing container runtimes automatically.
# They may belong to unrelated workloads managed by the customer.
check_no_conflicting_docker_packages_for_fresh() {
  local CONFLICTS
  CONFLICTS="$(conflicting_docker_packages)"
  if [ -z "$CONFLICTS" ]; then
    ok "No conflicting Docker CE packages detected"
    return 0
  fi

  error "Conflicting container packages were detected:"
  echo "" >&2
  printf '%s\n' "$CONFLICTS" | while IFS= read -r PKG; do
    [ -n "$PKG" ] && printf '  %s\n' "$PKG" >&2
  done
  echo "" >&2
  info "Easy-OpenVAS will not remove existing container software automatically."
  info "Review the server configuration and resolve the Docker package conflict manually."
  info "No existing container software has been modified."
  return 1
}

# Reject explicitly remote Docker endpoints without changing Docker context.
# Easy-OpenVAS deploys only to the intended local Docker daemon.
check_local_docker_endpoint() {
  local CONTEXT ENDPOINT
  if [[ "${DOCKER_HOST:-}" == tcp://* || "${DOCKER_HOST:-}" == ssh://* ]]; then
    error "The active Docker context points to a remote Docker daemon."
    error "Easy-OpenVAS will not deploy automatically to a remote Docker endpoint."
    info "Select the intended local Docker context and run the installer again."
    return 1
  fi

  CONTEXT="$($DOCKER_CMD context show 2>/dev/null || true)"
  if [ -n "$CONTEXT" ]; then
    ENDPOINT="$($DOCKER_CMD context inspect "$CONTEXT" --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
    if [[ "$ENDPOINT" == tcp://* || "$ENDPOINT" == ssh://* ]]; then
      error "The active Docker context points to a remote Docker daemon."
      error "Easy-OpenVAS will not deploy automatically to a remote Docker endpoint."
      info "Select the intended local Docker context and run the installer again."
      return 1
    fi
  fi

  ok "Local Docker endpoint"
}

# Detect existing Greenbone/OpenVAS Compose projects without modifying them.
# Collisions are left for the administrator to resolve manually.
check_no_existing_greenbone_project() {
  local PROJECTS LABELS COMBINED LINE LOWER
  PROJECTS="$($DOCKER_CMD compose ls --format '{{.Name}}' 2>/dev/null || true)"
  LABELS="$($DOCKER_CMD ps -a --filter label=com.docker.compose.project --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null || true)"
  COMBINED="$(printf '%s\n%s\n' "$PROJECTS" "$LABELS")"
  while IFS= read -r LINE; do
    LOWER="${LINE,,}"
    if [[ "$LOWER" == *greenbone* || "$LOWER" == *openvas* ]]; then
      error "An existing Greenbone/OpenVAS Docker project was detected."
      info "Existing containers, volumes and networks have not been modified."
      return 1
    fi
  done <<< "$COMBINED"

  ok "No existing Greenbone project detected"
}

# Resolve the filesystem that should be checked for OpenVAS data growth.
# Existing Docker hosts use DockerRootDir when Docker can report it.
disk_check_path() {
  local ROOT
  ROOT="$($DOCKER_CMD info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  if [ -n "$ROOT" ]; then
    printf '%s' "$ROOT"
  else
    printf '%s' "$OPENVAS_DIR"
  fi
}

# Perform simple capacity checks without changing resource limits.
# Greenbone feed data, databases, and scans can be heavy on shared hosts.
check_system_resources() {
  local MODE="$1" CPU RAM_KB RAM_GB DISK_PATH DISK_KB DISK_GB BELOW_MIN=0 BELOW_RECOMMENDED=0
  CPU="$($NPROC_CMD 2>/dev/null || echo 0)"
  RAM_KB="$(awk '/^MemTotal:/ { print $2; exit }' "$MEMINFO_FILE" 2>/dev/null || echo 0)"
  RAM_GB=$((RAM_KB / 1024 / 1024))
  if [ "$MODE" = "existing" ]; then
    DISK_PATH="$(disk_check_path)"
  else
    DISK_PATH="$OPENVAS_DIR"
  fi
  if [ ! -e "$DISK_PATH" ]; then
    DISK_PATH="$(dirname "$DISK_PATH")"
  fi
  DISK_KB="$($DF_CMD -Pk "$DISK_PATH" 2>/dev/null | awk 'NR==2 { print $4 }')"
  DISK_GB=$(( ${DISK_KB:-0} / 1024 / 1024 ))

  [ "${CPU:-0}" -lt 2 ] && BELOW_MIN=1
  [ "$RAM_GB" -lt 4 ] && BELOW_MIN=1
  [ "$DISK_GB" -lt 20 ] && BELOW_MIN=1
  [ "${CPU:-0}" -lt 4 ] && BELOW_RECOMMENDED=1
  [ "$RAM_GB" -lt 8 ] && BELOW_RECOMMENDED=1
  [ "$DISK_GB" -lt 60 ] && BELOW_RECOMMENDED=1

  if [ "$BELOW_MIN" -ne 0 ]; then
    error "Insufficient system resources for Greenbone deployment."
    return 1
  fi
  if [ "$BELOW_RECOMMENDED" -ne 0 ]; then
    warning "Available resources are below Greenbone recommended values."
  fi
  if [ "$MODE" = "existing" ]; then
    warning "OpenVAS feeds, databases and scan activity can consume significant disk and memory resources."
    info "Ensure sufficient capacity remains available for existing Docker workloads."
  fi
  ok "Resource checks completed"
}

# Ask for explicit consent before deploying onto a shared Docker server.
confirm_existing_docker_deployment() {
  local ANSWER
  printf 'Deploy Easy-OpenVAS on this Docker server? [y/N]:\n> '
  if ! IFS= read -r ANSWER; then
    info "Deployment cancelled."
    info "Existing Docker environment has not been modified."
    return 1
  fi
  case "$ANSWER" in
    y|Y|yes|YES) return 0 ;;
    *)
      info "Deployment cancelled."
      info "Existing Docker environment has not been modified."
      return 1
      ;;
  esac
}

# Run all shared-host checks before downloading Compose files or creating data.
existing_docker_preflight() {
  echo "Existing Docker preflight"
  echo ""
  check_existing_docker_environment || return 1
  check_local_docker_endpoint || return 1
  check_no_existing_greenbone_project || return 1
  check_no_existing_openvas_installation || return 1
  ok "$OPENVAS_DIR available"
  check_required_ports || return 1
  check_system_resources existing || return 1
  warning "The Greenbone scanner uses elevated container capabilities required by the upstream stack."
  info "Review this deployment if the Docker host also runs sensitive unrelated workloads."
  warning "OpenVAS can consume significant disk and memory resources."
  echo ""
  confirm_existing_docker_deployment
}

# Fresh-server installation is intentionally limited to Debian 13.
# Existing Docker deployments are validated through Docker capabilities
# rather than the underlying Linux distribution.
is_debian_13() {
  local ID_VALUE="" VERSION_ID_VALUE=""
  [ -r "$OS_RELEASE_FILE" ] || return 1
  . "$OS_RELEASE_FILE"
  ID_VALUE="${ID:-}"
  VERSION_ID_VALUE="${VERSION_ID:-}"
  [ "$ID_VALUE" = "debian" ] && [ "$VERSION_ID_VALUE" = "13" ]
}

# Enforce the Debian 13 guard before any fresh-server system changes.
check_fresh_debian13() {
  if is_debian_13; then
    ok "Debian 13 detected"
    return 0
  fi

  error "Fresh server mode currently supports Debian 13 only."
  info "No system changes have been made."
  return 1
}

# Keep fresh-server mode from taking over a host that already has Docker.
# Existing Docker installations may belong to the customer environment.
ensure_no_existing_docker_for_fresh() {
  if ! docker_command_exists; then
    ok "No existing Docker installation detected"
    return 0
  fi

  if docker_daemon_operational; then
    warning "An operational Docker installation already exists."
    warning "Fresh Debian 13 installation mode will not be used."
    info "Use option 2 to deploy Easy-OpenVAS on the existing Docker server."
  else
    error "Docker is installed but the Docker daemon is not operational."
    info "Fresh Debian 13 installation mode will not modify this Docker installation."
  fi
  return 1
}

# Validate an existing Docker installation without modifying it.
# Customer Docker hosts may run unrelated workloads, so this code path must
# never install, upgrade, restart, or reconfigure Docker.
check_existing_docker_environment() {
  echo "Docker environment"
  echo ""

  if ! docker_command_exists; then
    error "Docker is not installed on this server."
    info "Use option 1 if this is a fresh Debian 13 server."
    return 1
  fi

  "$DOCKER_CMD" --version
  ok "Existing Docker installation detected"

  if ! docker_daemon_operational; then
    error "Docker is installed but the Docker daemon is not operational."
    error "Fix the existing Docker installation before deploying Easy-OpenVAS."
    info "Existing Docker installation has not been modified."
    return 1
  fi
  ok "Docker daemon is operational"

  if ! docker_compose_available; then
    error "Docker is operational but Docker Compose v2 is not available."
    error "Install Docker Compose v2 before deploying Easy-OpenVAS."
    info "Existing Docker installation has not been modified."
    return 1
  fi
  "$DOCKER_CMD" compose version
  ok "Docker Compose v2 is available"

  echo ""
  info "Existing Docker installation will be used unchanged."
  info "Easy-OpenVAS will deploy only its own Greenbone/OpenVAS stack."
  echo ""
  return 0
}

# Check whether a host TCP port is already bound by another process.
port_is_available() {
  local PORT="$1"
  ! "$SS_CMD" -ltn 2>/dev/null | awk -v port=":$PORT" 'NR > 1 { split($4, addr, ":"); if ($4 ~ port "$") found=1 } END { exit found ? 0 : 1 }'
}

# Check required host ports before starting Greenbone.
# Existing processes or containers are never stopped automatically.
check_required_ports() {
  local PORT FAILED=0
  for PORT in 443 9392; do
    if port_is_available "$PORT"; then
      ok "TCP port $PORT is available"
    else
      error "TCP port $PORT is already in use."
      FAILED=1
    fi
  done

  if [ "$FAILED" -ne 0 ]; then
    error "Easy-OpenVAS cannot deploy the OpenVAS HTTPS service."
    info "No existing service or container has been modified."
    return 1
  fi
}

# Refuse to overwrite an existing Easy-OpenVAS Compose deployment.
check_no_existing_openvas_installation() {
  if [ -e "$COMPOSE_FILE" ]; then
    error "An existing Easy-OpenVAS installation was detected in $OPENVAS_DIR."
    info "Existing installation has not been modified."
    return 1
  fi
}

# Install Docker CE and Docker Compose v2 for the fresh Debian 13 mode.
# This function must only be reached when no operational Docker installation
# is already present.
install_docker() {
  info "Installing Docker for Easy-OpenVAS..."

  if [ "${EASY_OPENVAS_SKIP_DOCKER_INSTALL:-false}" = "true" ]; then
    info "Docker installation skipped by test mode."
    return 0
  fi

  echo "[2/9] Updating package list and installing prerequisites..."
  apt update
  apt install -y ca-certificates curl gnupg

  echo "Prerequisites installed."
  echo ""

  echo "[3/9] Verifying Docker CE package prerequisites..."
  check_no_conflicting_docker_packages_for_fresh
  echo ""

  echo "[4/9] Installing Docker repository key..."

  install -m 0755 -d /etc/apt/keyrings
  rm -f /etc/apt/keyrings/docker.gpg

  curl -fsSL https://download.docker.com/linux/debian/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "Docker key installed."
  echo ""

  echo "[5/9] Adding Docker APT repository..."

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt update

  echo "Docker repository added."
  echo ""

  echo "[6/9] Installing Docker Engine and Docker Compose plugin..."

  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker

  echo "Docker installed and started."
  echo ""

  "$DOCKER_CMD" --version
  "$DOCKER_CMD" compose version
  echo ""
}

# Detect the host identity used to suggest the browser-facing OpenVAS FQDN.
detect_server_identity() {
  echo "[1/9] Detecting server FQDN and IP address..."

  SERVER_FQDN="${EASY_OPENVAS_SERVER_FQDN:-}"
  SERVER_IP="${EASY_OPENVAS_SERVER_IP:-}"

  if [ -z "$SERVER_FQDN" ]; then
    SERVER_FQDN="$(hostname -f 2>/dev/null || hostname)"
  fi
  if [ -z "$SERVER_IP" ]; then
    SERVER_IP="$(hostname -I | awk '{print $1}')"
  fi

  if [ -z "$SERVER_FQDN" ]; then
    SERVER_FQDN="$SERVER_IP"
  fi

  echo "Detected FQDN: $SERVER_FQDN"
  echo "Detected IP:   $SERVER_IP"
  echo ""
}

# Select and validate the OpenVAS service FQDN before writing Compose changes.
select_openvas_fqdn() {
  echo "Selecting OpenVAS service FQDN..."
  OPENVAS_FQDN="$(prompt_openvas_fqdn "$SERVER_FQDN")"
  check_openvas_dns "$OPENVAS_FQDN"
  echo ""
}

# Prepare the installation directory that will hold the downloaded Compose file.
prepare_openvas_directory() {
  echo "[7/9] Preparing OpenVAS installation directory..."

  mkdir -p "$OPENVAS_DIR"
  cd "$OPENVAS_DIR"

  echo "OpenVAS directory: $OPENVAS_DIR"
  echo ""
}

# Fetch the Greenbone Community Edition Compose definition.
# Test mode can provide a local source to avoid network access.
download_compose_file() {
  echo "[8/9] Downloading OpenVAS Docker Compose file..."

  if [ -n "${EASY_OPENVAS_COMPOSE_SOURCE:-}" ]; then
    cp "$EASY_OPENVAS_COMPOSE_SOURCE" "$COMPOSE_FILE"
  else
    curl -f -L https://greenbone.github.io/docs/latest/_static/compose.yaml -o "$COMPOSE_FILE"
  fi

  echo "Compose file downloaded:"
  echo "$COMPOSE_FILE"
  echo ""
}

# Adjust the downloaded Compose file for external HTTPS access and the selected
# OpenVAS FQDN, then validate the resulting configuration.
configure_openvas_compose() {
  echo "Configuring OpenVAS web access on all network interfaces..."
  sed -i \
    -e 's/127\.0\.0\.1:443:443/443:443/g' \
    -e 's/127\.0\.0\.1:9392:9392/9392:9392/g' \
    "$COMPOSE_FILE"
  echo "OpenVAS web access configured for any server IP address."
  echo ""

  echo "Configuring Greenbone gvm-config for OpenVAS FQDN..."
  configure_gvm_config_fqdn
  echo "OpenVAS FQDN configured: $OPENVAS_FQDN"
  echo ""

  echo "Validating Docker Compose configuration..."
  validate_docker_compose_config
  echo ""
}

# Wait for a Compose service to reach Docker's healthy state.
# On timeout, show logs and container status before aborting the deployment.
wait_for_healthy_service() {
  local SERVICE_NAME="$1"
  local CONTAINER_ID
  local HEALTH_STATUS
  local ATTEMPT=1
  local MAX_ATTEMPTS="${EASY_OPENVAS_HEALTH_MAX_ATTEMPTS:-120}"
  local SLEEP_SECONDS="${EASY_OPENVAS_HEALTH_SLEEP_SECONDS:-15}"

  CONTAINER_ID="$("$DOCKER_CMD" compose -f "$COMPOSE_FILE" ps -q "$SERVICE_NAME" || true)"

  if [ -z "$CONTAINER_ID" ]; then
    echo "Error: $SERVICE_NAME container was not found."
    echo "Showing current container status:"
    "$DOCKER_CMD" compose -f "$COMPOSE_FILE" ps
    exit 1
  fi

  while [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]; do
    HEALTH_STATUS="$("$DOCKER_CMD" inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CONTAINER_ID" 2>/dev/null || echo "unknown")"

    echo "$SERVICE_NAME status: $HEALTH_STATUS - attempt $ATTEMPT/$MAX_ATTEMPTS"

    if [ "$HEALTH_STATUS" = "healthy" ]; then
      echo "$SERVICE_NAME is healthy."
      return 0
    fi

    if [ "$ATTEMPT" -eq "$MAX_ATTEMPTS" ]; then
      echo ""
      echo "Error: $SERVICE_NAME did not become healthy in time."
      echo ""
      echo "Last logs from $SERVICE_NAME:"
      "$DOCKER_CMD" compose -f "$COMPOSE_FILE" logs --tail=100 "$SERVICE_NAME"
      echo ""
      echo "Current container status:"
      "$DOCKER_CMD" compose -f "$COMPOSE_FILE" ps
      exit 1
    fi

    sleep "$SLEEP_SECONDS"
    ATTEMPT=$((ATTEMPT + 1))
  done
}

# Start Greenbone feed data containers first so shared volumes are populated
# before the rest of the OpenVAS stack depends on them.
start_openvas_containers() {
  local SERVICE_NAME
  echo "[9/9] Starting OpenVAS containers..."

  "$DOCKER_CMD" compose -f "$COMPOSE_FILE" pull

  echo ""
  echo "Starting feed data containers first."
  echo "Some data containers may take several minutes to copy feeds into Docker volumes..."

  BASE_FEED_DATA_SERVICES=(
    vulnerability-tests
    notus-data
    scap-data
    cert-bund-data
    data-objects
  )

  DEPENDENT_FEED_DATA_SERVICES=(
    dfn-cert-data
    report-formats
  )

  "$DOCKER_CMD" compose -f "$COMPOSE_FILE" up -d "${BASE_FEED_DATA_SERVICES[@]}"

  echo ""
  echo "Waiting for feed data containers to become healthy..."

  for SERVICE_NAME in "${BASE_FEED_DATA_SERVICES[@]}"; do
    wait_for_healthy_service "$SERVICE_NAME"
  done

  echo ""
  echo "Starting dependent feed data containers..."
  "$DOCKER_CMD" compose -f "$COMPOSE_FILE" up -d "${DEPENDENT_FEED_DATA_SERVICES[@]}"

  for SERVICE_NAME in "${DEPENDENT_FEED_DATA_SERVICES[@]}"; do
    wait_for_healthy_service "$SERVICE_NAME"
  done

  echo ""
  echo "Starting remaining OpenVAS services..."
  "$DOCKER_CMD" compose -f "$COMPOSE_FILE" up -d

  echo ""
  echo "Current container status:"
  "$DOCKER_CMD" compose -f "$COMPOSE_FILE" ps
  echo ""
}

# Print post-installation access details and operational commands for admins.
print_completion() {
  echo "=================================================="
  echo " Installation completed"
  echo "=================================================="
  echo ""
  echo "OpenVAS web interface should be available at:"
  echo ""
  echo "  https://$OPENVAS_FQDN"
  echo ""
  echo "Port information:"
  echo "  HTTPS uses the standard port 443, so no port needs to be added"
  echo "  to the URL unless you changed the Docker Compose port mapping."
  echo "  In the default OpenVAS Compose file, port 9392 redirects to 443."
  echo ""

  if [ -n "$SERVER_IP" ] && [ "$SERVER_IP" != "$OPENVAS_FQDN" ]; then
    echo "Server IP:"
    echo ""
    echo "  $SERVER_IP"
    echo ""
  fi

  echo "Default credentials:"
  echo ""
  echo "  Username: admin"
  echo "  Password: admin"
  echo ""
  echo "Important:"
  echo "  Change the default admin password after the first login."
  echo "  To do this, open the admin account menu in the top-right corner,"
  echo "  then go to Settings > Password and enter the old password and"
  echo "  the new password."
  echo "  If the admin password is lost, reset it from the command line with:"
  echo "    sudo docker exec -it greenbone-community-edition-gvmd-1 gvmd --user=admin --new-password='XXXXX'"
  echo ""
  echo "Certificate warning:"
  echo "  If your browser displays a certificate warning, this is expected"
  echo "  when OpenVAS uses its default self-signed HTTPS certificate."
  echo "  For a warning-free browser experience, install a TLS certificate"
  echo "  issued by a certificate authority trusted by browsers."
  echo ""
  echo "Useful commands:"
  echo ""
  echo "  Check containers:"
  echo "    docker compose -f $COMPOSE_FILE ps"
  echo ""
  echo "  Follow logs:"
  echo "    docker compose -f $COMPOSE_FILE logs -f"
  echo ""
  echo "  Check scap-data logs:"
  echo "    docker compose -f $COMPOSE_FILE logs --tail=100 scap-data"
  echo ""
  echo "  Restart OpenVAS:"
  echo "    docker compose -f $COMPOSE_FILE up -d"
  echo ""
  echo "  Stop OpenVAS:"
  echo "    docker compose -f $COMPOSE_FILE down"
  echo ""
}

# Run the common OpenVAS deployment sequence after the selected mode has
# completed its own safety checks.
deploy_openvas_stack() {
  local MODE="${1:-fresh}"
  detect_server_identity
  select_openvas_fqdn
  if [ "$MODE" != "existing" ]; then
    check_no_existing_openvas_installation || return 1
    check_required_ports || return 1
    check_system_resources fresh || return 1
  fi
  prepare_openvas_directory
  download_compose_file
  configure_openvas_compose
  start_openvas_containers
  print_completion
}

# Fresh Debian 13 mode may install Docker, but only after OS and Docker guards
# have confirmed that this is a clean target.
install_fresh_debian13_server() {
  check_fresh_debian13 || return 1
  ensure_no_existing_docker_for_fresh || return 1
  check_no_existing_openvas_installation || return 1
  check_no_conflicting_docker_packages_for_fresh || return 1
  check_system_resources fresh || return 1
  install_docker
  deploy_openvas_stack fresh
}

# Existing Docker mode validates Docker capabilities and then deploys only the
# Easy-OpenVAS Greenbone stack.
install_existing_docker_server() {
  existing_docker_preflight || return 1
  deploy_openvas_stack existing
}

# Show the interactive deployment menu.
print_menu() {
  cat <<'MENU'
========================================
 Easy-OpenVAS Installer
========================================

1. Install OpenVAS on a fresh Debian 13 server
2. Install OpenVAS on an existing Docker server
3. Exit

Choice:
MENU
}

# Select the deployment mode explicitly so a pre-existing Docker environment is
# never mistaken for a fresh-server installation.
main_menu() {
  local CHOICE
  while true; do
    print_menu
    if ! IFS= read -r CHOICE; then
      return 0
    fi

    case "$CHOICE" in
      1) install_fresh_debian13_server && return 0 ;;
      2) install_existing_docker_server && return 0 ;;
      3) return 0 ;;
      *) warning "Invalid choice." ;;
    esac
    echo ""
  done
}

# Expose focused entry points used by the test suite without running the
# interactive installer.
run_test_command() {
  local COMMAND="${1:-}"
  shift || true
  case "$COMMAND" in
    suggest-fqdn) suggest_openvas_fqdn "$1" ;;
    validate-fqdn)
      if is_valid_fqdn "$(normalize_fqdn "$1")"; then
        normalize_fqdn "$1"
      else
        return 1
      fi
      ;;
    prompt-fqdn) prompt_openvas_fqdn "$1" ;;
    dns-check) check_openvas_dns "$1" ;;
    configure-compose)
      COMPOSE_FILE="$1"
      OPENVAS_FQDN="$2"
      configure_gvm_config_fqdn
      ;;
    validate-compose)
      COMPOSE_FILE="$1"
      validate_docker_compose_config
      ;;
    fresh-conflicts) check_no_conflicting_docker_packages_for_fresh ;;
    local-docker) check_local_docker_endpoint ;;
    greenbone-project) check_no_existing_greenbone_project ;;
    resources) check_system_resources "${1:-fresh}" ;;
    menu) main_menu ;;
    *) error "Unknown test command."; return 2 ;;
  esac
}

# Route either test commands or the normal interactive installer.
main() {
  if [ "${1:-}" = "--test-command" ]; then
    shift
    run_test_command "$@"
    return
  fi

  require_root
  main_menu
}

main "$@"
