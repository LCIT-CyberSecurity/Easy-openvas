#!/bin/bash

set -e

DOCKER_CMD="${EASY_OPENVAS_DOCKER_CMD:-docker}"

ok() { echo "[OK] $*"; }
warning() { echo "[WARNING] $*"; }
error() { echo "[ERROR] $*" >&2; }

normalize_fqdn() {
  local FQDN="$1"
  FQDN="$(printf '%s' "$FQDN" | tr '[:upper:]' '[:lower:]')"
  FQDN="${FQDN%.}"
  printf '%s' "$FQDN"
}

is_valid_fqdn() {
  local FQDN="$1"
  [ -n "$FQDN" ] || return 1
  [ "${#FQDN}" -le 253 ] || return 1
  [[ "$FQDN" == *.* ]] || return 1
  [[ "$FQDN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

suggest_openvas_fqdn() {
  local HOST_FQDN DOMAIN CANDIDATE
  HOST_FQDN="$(normalize_fqdn "$1")"
  [[ "$HOST_FQDN" == *.* ]] || return 0
  DOMAIN="${HOST_FQDN#*.}"
  CANDIDATE="openvas.$DOMAIN"
  if is_valid_fqdn "$CANDIDATE"; then
    printf '%s' "$CANDIDATE"
  fi
}

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

configure_gvm_config_fqdn() {
  local TMP
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
}

validate_docker_compose_config() {
  if "$DOCKER_CMD" compose -f "$COMPOSE_FILE" config >/dev/null; then
    ok "Docker Compose configuration valid"
    return 0
  fi

  error "Docker Compose configuration is invalid."
  return 1
}

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
    *) error "Unknown test command."; return 2 ;;
  esac
}

if [ "${1:-}" = "--test-command" ]; then
  shift
  run_test_command "$@"
  exit
fi

echo "=================================================="
echo " OpenVAS Docker installation script"
echo "=================================================="
echo ""

if [ "$EUID" -ne 0 ]; then
  echo "Error: this script must be run as root."
  echo "Example: sudo ./Openvas-installer.sh"
  exit 1
fi

echo "[1/9] Detecting server FQDN and IP address..."

SERVER_FQDN="$(hostname -f 2>/dev/null || hostname)"
SERVER_IP="$(hostname -I | awk '{print $1}')"

if [ -z "$SERVER_FQDN" ]; then
  SERVER_FQDN="$SERVER_IP"
fi

echo "Detected FQDN: $SERVER_FQDN"
echo "Detected IP:   $SERVER_IP"
echo ""

echo "Selecting OpenVAS service FQDN..."
OPENVAS_FQDN="$(prompt_openvas_fqdn "$SERVER_FQDN")"
check_openvas_dns "$OPENVAS_FQDN"
echo ""

echo "[2/9] Updating package list and installing prerequisites..."

apt update
apt install -y ca-certificates curl gnupg

echo "Prerequisites installed."
echo ""

echo "[3/9] Removing conflicting Docker packages if present..."

for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
  apt remove -y "$pkg" || true
done

echo "Conflicting packages removed or not present."
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

docker --version
docker compose version
echo ""

echo "[7/9] Preparing OpenVAS installation directory..."

OPENVAS_DIR="/opt/openvas"
COMPOSE_FILE="$OPENVAS_DIR/compose.yaml"

mkdir -p "$OPENVAS_DIR"
cd "$OPENVAS_DIR"

echo "OpenVAS directory: $OPENVAS_DIR"
echo ""

echo "[8/9] Downloading OpenVAS Docker Compose file..."

curl -f -L https://greenbone.github.io/docs/latest/_static/compose.yaml -o "$COMPOSE_FILE"

echo "Compose file downloaded:"
echo "$COMPOSE_FILE"
echo ""

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

echo "[9/9] Starting OpenVAS containers..."

docker compose -f "$COMPOSE_FILE" pull

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

docker compose -f "$COMPOSE_FILE" up -d "${BASE_FEED_DATA_SERVICES[@]}"

echo ""
echo "Waiting for feed data containers to become healthy..."

wait_for_healthy_service() {
  local SERVICE_NAME="$1"
  local CONTAINER_ID
  local HEALTH_STATUS
  local ATTEMPT=1
  local MAX_ATTEMPTS=120
  local SLEEP_SECONDS=15

  CONTAINER_ID="$(docker compose -f "$COMPOSE_FILE" ps -q "$SERVICE_NAME" || true)"

  if [ -z "$CONTAINER_ID" ]; then
    echo "Error: $SERVICE_NAME container was not found."
    echo "Showing current container status:"
    docker compose -f "$COMPOSE_FILE" ps
    exit 1
  fi

  while [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]; do
    HEALTH_STATUS="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CONTAINER_ID" 2>/dev/null || echo "unknown")"

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
      docker compose -f "$COMPOSE_FILE" logs --tail=100 "$SERVICE_NAME"
      echo ""
      echo "Current container status:"
      docker compose -f "$COMPOSE_FILE" ps
      exit 1
    fi

    sleep "$SLEEP_SECONDS"
    ATTEMPT=$((ATTEMPT + 1))
  done
}

for SERVICE_NAME in "${BASE_FEED_DATA_SERVICES[@]}"; do
  wait_for_healthy_service "$SERVICE_NAME"
done

echo ""
echo "Starting dependent feed data containers..."
docker compose -f "$COMPOSE_FILE" up -d "${DEPENDENT_FEED_DATA_SERVICES[@]}"

for SERVICE_NAME in "${DEPENDENT_FEED_DATA_SERVICES[@]}"; do
  wait_for_healthy_service "$SERVICE_NAME"
done

echo ""
echo "Starting remaining OpenVAS services..."
docker compose -f "$COMPOSE_FILE" up -d

echo ""
echo "Current container status:"
docker compose -f "$COMPOSE_FILE" ps
echo ""

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
