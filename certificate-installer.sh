#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
OPENVAS_DIR="${EASY_OPENVAS_BASE_DIR:-/opt/openvas}"
COMPOSE_FILE="${EASY_OPENVAS_COMPOSE_FILE:-$OPENVAS_DIR/compose.yaml}"
CERTS_DIR="${EASY_OPENVAS_CERTS_DIR:-$OPENVAS_DIR/certs}"
CERT_DEST="$CERTS_DIR/server.cert.pem"
KEY_DEST="$CERTS_DIR/server.key"
BACKUP_DIR="$OPENVAS_DIR/.certificate-installer-backup"
DOCKER_CMD="${EASY_OPENVAS_DOCKER_CMD:-docker}"
OPENSSL_CMD="${EASY_OPENVAS_OPENSSL_CMD:-openssl}"
HTTPS_CERT_CMD="${EASY_OPENVAS_HTTPS_CERT_CMD:-}"
TLS_HOST="${EASY_OPENVAS_TLS_HOST:-127.0.0.1}"
TLS_PORT="${EASY_OPENVAS_TLS_PORT:-443}"
SKIP_ROOT_CHECK="${EASY_OPENVAS_SKIP_ROOT:-false}"
TEST_MODE="${EASY_OPENVAS_TEST_MODE:-false}"

RED=""
GREEN=""
YELLOW=""
BLUE=""
RESET=""
if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then
  RED=$'\033[31m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  BLUE=$'\033[34m'
  RESET=$'\033[0m'
fi

TMP_FILES=()

cleanup_tmp() {
  local path
  for path in "${TMP_FILES[@]:-}"; do
    if [[ -n "$path" && -e "$path" ]]; then
      rm -f -- "$path"
    fi
  done
  return 0
}
trap cleanup_tmp EXIT

info() { printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$*"; }
ok() { printf '%s[OK]%s %s\n' "$GREEN" "$RESET" "$*"; }
warning() { printf '%s[WARNING]%s %s\n' "$YELLOW" "$RESET" "$*"; }
error() { printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$*" >&2; }

die_no_change() {
  error "$1"
  printf 'No configuration has been changed.\n' >&2
  return 1
}

require_root() {
  if [[ "$SKIP_ROOT_CHECK" == "true" || "$OPENVAS_DIR" != "/opt/openvas" ]]; then
    return 0
  fi
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "This script must be run as root."
    printf 'Example: sudo ./%s\n' "$SCRIPT_NAME" >&2
    exit 1
  fi
}

resolve_path() {
  local input="$1"
  realpath -- "$input"
}

prompt_path() {
  local label="$1"
  local value
  printf '%s\n> ' "$label" >&2
  IFS= read -r value
  resolve_path "$value"
}

prompt_value() {
  local label="$1"
  local value
  printf '%s\n> ' "$label" >&2
  IFS= read -r value
  printf '%s' "$value"
}

confirm() {
  local prompt="$1"
  local answer
  printf '%s ' "$prompt"
  IFS= read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" || "$answer" == "YES" ]]
}

openssl_quiet() {
  "$OPENSSL_CMD" "$@" >/dev/null 2>&1
}

file_readable_regular() {
  local path="$1"
  [[ -f "$path" && -r "$path" ]]
}

cert_subject() { "$OPENSSL_CMD" x509 -in "$1" -noout -subject 2>/dev/null | sed 's/^subject=//'; }
cert_issuer() { "$OPENSSL_CMD" x509 -in "$1" -noout -issuer 2>/dev/null | sed 's/^issuer=//'; }
cert_start() { "$OPENSSL_CMD" x509 -in "$1" -noout -startdate 2>/dev/null | sed 's/^notBefore=//'; }
cert_end() { "$OPENSSL_CMD" x509 -in "$1" -noout -enddate 2>/dev/null | sed 's/^notAfter=//'; }

cert_san() {
  "$OPENSSL_CMD" x509 -in "$1" -noout -ext subjectAltName 2>/dev/null \
    | awk 'NR > 1 { gsub(/^ +| +$/, ""); print }' \
    | tr '\n' ' ' \
    | sed 's/[[:space:]]*$//'
}

date_epoch() {
  date -d "$1" +%s
}

days_remaining() {
  local end_date="$1"
  local end_epoch now_epoch
  end_epoch="$(date_epoch "$end_date")"
  now_epoch="$(date +%s)"
  printf '%s\n' $(((end_epoch - now_epoch) / 86400))
}

cert_fingerprint() {
  "$OPENSSL_CMD" x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'
}

cert_key_match() {
  local cert="$1"
  local key="$2"
  local cert_pub key_pub
  cert_pub="$(mktemp)"
  key_pub="$(mktemp)"
  TMP_FILES+=("$cert_pub" "$key_pub")
  "$OPENSSL_CMD" x509 -in "$cert" -pubkey -noout >"$cert_pub" 2>/dev/null || return 1
  "$OPENSSL_CMD" pkey -in "$key" -pubout >"$key_pub" 2>/dev/null || return 1
  cmp -s "$cert_pub" "$key_pub"
}

cert_covers_fqdn() {
  local cert="$1"
  local fqdn="$2"
  "$OPENSSL_CMD" x509 -in "$cert" -noout -checkhost "$fqdn" 2>/dev/null | grep -q "does match"
}

print_certificate_info() {
  local cert="$1"
  local end_date remaining san
  end_date="$(cert_end "$cert")"
  remaining="$(days_remaining "$end_date")"
  san="$(cert_san "$cert")"
  printf '\nCertificate information\n\n'
  printf 'Subject............. %s\n' "$(cert_subject "$cert")"
  printf 'Issuer.............. %s\n' "$(cert_issuer "$cert")"
  printf 'Valid from.......... %s\n' "$(cert_start "$cert")"
  printf 'Valid until......... %s\n' "$end_date"
  printf 'Days remaining...... %s\n' "$remaining"
  printf 'SAN................. %s\n' "${san:-Not present}"
}

validate_certificate_files() {
  local cert="$1"
  local key="$2"
  local fqdn="$3"
  local remaining

  printf 'Checking certificate...\n\n'

  if file_readable_regular "$cert"; then
    ok "Certificate file found"
  else
    die_no_change "Certificate file not found or not readable."
    return 1
  fi

  if file_readable_regular "$key"; then
    ok "Private key file found"
  else
    die_no_change "Private key file not found or not readable."
    return 1
  fi

  if openssl_quiet x509 -in "$cert" -noout; then
    ok "Certificate PEM format valid"
  else
    die_no_change "Certificate PEM format invalid."
    return 1
  fi

  if openssl_quiet pkey -in "$key" -noout; then
    ok "Private key format valid"
  else
    die_no_change "Private key format invalid."
    return 1
  fi

  if cert_key_match "$cert" "$key"; then
    ok "Certificate and private key match"
  else
    die_no_change "Certificate and private key do not match."
    return 1
  fi

  if openssl_quiet x509 -in "$cert" -checkend 0 -noout; then
    ok "Certificate is not expired"
  else
    die_no_change "Certificate has expired."
    return 1
  fi

  if cert_covers_fqdn "$cert" "$fqdn"; then
    ok "Certificate covers $fqdn"
  else
    die_no_change "Certificate does not cover $fqdn."
    return 1
  fi

  print_certificate_info "$cert"
  remaining="$(days_remaining "$(cert_end "$cert")")"
  if (( remaining < 30 )); then
    warning "Certificate expires in $remaining days."
  fi
}

service_exists_in_compose() {
  local service="$1"
  awk -v svc="$service" '
    $0 ~ "^  " svc ":$" { found=1 }
    END { exit found ? 0 : 1 }
  ' "$COMPOSE_FILE"
}

compose_has_tls_structure() {
  awk '
    /^  gvm-config:$/ { svc="gvm-config"; next }
    /^  nginx:$/ { svc="nginx"; next }
    /^  [A-Za-z0-9_-]+:$/ { svc="" }
    svc=="gvm-config" && /ENABLE_TLS_GENERATION:[[:space:]]*(true|false)/ { tls=1 }
    svc=="nginx" && /nginx_certificates_vol:\/etc\/nginx\/certs:ro/ { certvol=1 }
    svc=="nginx" && /\/etc\/nginx\/certs\/server\.cert\.pem:ro/ { certfile=1 }
    svc=="nginx" && /\/etc\/nginx\/certs\/server\.key:ro/ { keyfile=1 }
    END { exit (tls && (certvol || (certfile && keyfile))) ? 0 : 1 }
  ' "$COMPOSE_FILE"
}

validate_easy_openvas_installation() {
  printf 'Checking Easy-OpenVAS installation...\n\n'
  if [[ -f "$COMPOSE_FILE" ]]; then
    ok "$COMPOSE_FILE found"
  else
    error "Unsupported Greenbone Compose structure."
    printf 'No changes have been made.\n' >&2
    return 1
  fi

  if service_exists_in_compose "nginx"; then
    ok "nginx service found"
  else
    error "Unsupported Greenbone Compose structure."
    printf 'No changes have been made.\n' >&2
    return 1
  fi

  if service_exists_in_compose "gvm-config"; then
    ok "gvm-config service found"
  else
    error "Unsupported Greenbone Compose structure."
    printf 'No changes have been made.\n' >&2
    return 1
  fi

  if compose_has_tls_structure; then
    ok "Greenbone TLS structure found"
  else
    error "Unsupported Greenbone Compose structure."
    printf 'No changes have been made.\n' >&2
    return 1
  fi

  validate_compose_quiet
  ok "Docker Compose configuration valid"
}

validate_compose_quiet() {
  (cd "$OPENVAS_DIR" && "$DOCKER_CMD" compose -f "$COMPOSE_FILE" config >/dev/null)
}

create_backup() {
  info "Creating configuration backup..."
  rm -rf -- "$BACKUP_DIR"
  mkdir -p -- "$BACKUP_DIR"
  cp -- "$COMPOSE_FILE" "$BACKUP_DIR/compose.yaml"
  if [[ -f "$CERT_DEST" ]]; then
    cp -- "$CERT_DEST" "$BACKUP_DIR/server.cert.pem"
  fi
  if [[ -f "$KEY_DEST" ]]; then
    cp -- "$KEY_DEST" "$BACKUP_DIR/server.key"
  fi
  ok "Backup created"
}

restore_backup() {
  info "Restoring previous configuration..."
  if [[ -f "$BACKUP_DIR/compose.yaml" ]]; then
    cp -- "$BACKUP_DIR/compose.yaml" "$COMPOSE_FILE"
  fi
  mkdir -p -- "$CERTS_DIR"
  if [[ -f "$BACKUP_DIR/server.cert.pem" ]]; then
    cp -- "$BACKUP_DIR/server.cert.pem" "$CERT_DEST"
    chmod 644 "$CERT_DEST"
  else
    rm -f -- "$CERT_DEST"
  fi
  if [[ -f "$BACKUP_DIR/server.key" ]]; then
    cp -- "$BACKUP_DIR/server.key" "$KEY_DEST"
    chmod 600 "$KEY_DEST"
  else
    rm -f -- "$KEY_DEST"
  fi
  ok "Rollback completed."
}

secure_copy_certificate() {
  local cert="$1"
  local key="$2"
  local tmp_cert tmp_key
  mkdir -p -- "$CERTS_DIR"
  chown root:root "$CERTS_DIR" 2>/dev/null || true
  chmod 700 "$CERTS_DIR"

  tmp_cert="$(mktemp "$CERTS_DIR/.server.cert.pem.XXXXXX")"
  tmp_key="$(mktemp "$CERTS_DIR/.server.key.XXXXXX")"
  TMP_FILES+=("$tmp_cert" "$tmp_key")

  cp -- "$cert" "$tmp_cert"
  cp -- "$key" "$tmp_key"
  chmod 644 "$tmp_cert"
  chmod 600 "$tmp_key"
  chown root:root "$tmp_cert" "$tmp_key" 2>/dev/null || true
  mv -f -- "$tmp_cert" "$CERT_DEST"
  mv -f -- "$tmp_key" "$KEY_DEST"
}

render_custom_compose() {
  local output="$1"
  awk -v cert="$CERT_DEST" -v key="$KEY_DEST" '
    function emit_custom() {
      if (!custom_emitted) {
        print "      - " cert ":/etc/nginx/certs/server.cert.pem:ro"
        print "      - " key ":/etc/nginx/certs/server.key:ro"
        custom_emitted=1
      }
    }
    /^  [A-Za-z0-9_-]+:$/ {
      if (svc=="nginx" && section=="volumes") emit_custom()
      svc=$0
      sub(/^  /, "", svc)
      sub(/:$/, "", svc)
      section=""
      custom_emitted=0
      print
      next
    }
    /^    [A-Za-z0-9_-]+:$/ {
      if (svc=="nginx" && section=="volumes") emit_custom()
      section=$0
      sub(/^    /, "", section)
      sub(/:$/, "", section)
      print
      next
    }
    svc=="gvm-config" && $0 ~ /^[[:space:]]+ENABLE_TLS_GENERATION:/ {
      print "      ENABLE_TLS_GENERATION: false"
      next
    }
    svc=="nginx" && section=="volumes" && $0 ~ /\/etc\/nginx\/certs(:ro)?$/ { next }
    svc=="nginx" && section=="volumes" && $0 ~ /\/etc\/nginx\/certs\/server\.cert\.pem:ro$/ { next }
    svc=="nginx" && section=="volumes" && $0 ~ /\/etc\/nginx\/certs\/server\.key:ro$/ { next }
    svc=="nginx" && section=="volumes" && $0 ~ /gsa_data_vol:\/usr\/share\/nginx\/html:ro/ { emit_custom(); print; next }
    { print }
    END { if (svc=="nginx" && section=="volumes") emit_custom() }
  ' "$COMPOSE_FILE" >"$output"
}

render_self_signed_compose() {
  local output="$1"
  awk '
    function emit_certvol() {
      if (!certvol_emitted) {
        print "      - nginx_certificates_vol:/etc/nginx/certs:ro"
        certvol_emitted=1
      }
    }
    /^  [A-Za-z0-9_-]+:$/ {
      if (svc=="nginx" && section=="volumes") emit_certvol()
      svc=$0
      sub(/^  /, "", svc)
      sub(/:$/, "", svc)
      section=""
      certvol_emitted=0
      print
      next
    }
    /^    [A-Za-z0-9_-]+:$/ {
      if (svc=="nginx" && section=="volumes") emit_certvol()
      section=$0
      sub(/^    /, "", section)
      sub(/:$/, "", section)
      print
      next
    }
    svc=="gvm-config" && $0 ~ /^[[:space:]]+ENABLE_TLS_GENERATION:/ {
      print "      ENABLE_TLS_GENERATION: true"
      next
    }
    svc=="nginx" && section=="volumes" && $0 ~ /\/etc\/nginx\/certs\/server\.cert\.pem:ro$/ { next }
    svc=="nginx" && section=="volumes" && $0 ~ /\/etc\/nginx\/certs\/server\.key:ro$/ { next }
    svc=="nginx" && section=="volumes" && $0 ~ /nginx_certificates_vol:\/etc\/nginx\/certs:ro/ { certvol_emitted=1; print; next }
    svc=="nginx" && section=="volumes" && $0 ~ /gsa_data_vol:\/usr\/share\/nginx\/html:ro/ { emit_certvol(); print; next }
    { print }
    END { if (svc=="nginx" && section=="volumes") emit_certvol() }
  ' "$COMPOSE_FILE" >"$output"
}

apply_compose_file() {
  local mode="$1"
  local tmp
  tmp="$(mktemp)"
  TMP_FILES+=("$tmp")
  if [[ "$mode" == "custom" ]]; then
    render_custom_compose "$tmp"
  else
    render_self_signed_compose "$tmp"
  fi
  mv -f -- "$tmp" "$COMPOSE_FILE"
}

validate_compose_or_rollback() {
  info "Validating Docker Compose configuration..."
  if validate_compose_quiet; then
    ok "Docker Compose configuration valid"
    return 0
  fi
  error "Docker Compose configuration invalid."
  restore_backup
  return 1
}

reload_tls_services() {
  info "Reloading Greenbone TLS services..."
  if ! (cd "$OPENVAS_DIR" && "$DOCKER_CMD" compose -f "$COMPOSE_FILE" up -d gvm-config nginx >/dev/null); then
    return 1
  fi
  if (cd "$OPENVAS_DIR" && "$DOCKER_CMD" compose -f "$COMPOSE_FILE" ps -q nginx >/dev/null); then
    ok "nginx is running"
  else
    return 1
  fi
}

retrieve_presented_certificate() {
  local output="$1"
  local fqdn="$2"
  if [[ -n "$HTTPS_CERT_CMD" ]]; then
    EASY_OPENVAS_CERT_OUTPUT="$output" EASY_OPENVAS_FQDN="$fqdn" bash -c "$HTTPS_CERT_CMD"
    return
  fi
  "$OPENSSL_CMD" s_client -connect "$TLS_HOST:$TLS_PORT" -servername "$fqdn" -showcerts </dev/null 2>/dev/null \
    | "$OPENSSL_CMD" x509 -outform PEM >"$output"
}

https_endpoint_reachable() {
  local fqdn="$1"
  local tmp
  tmp="$(mktemp)"
  TMP_FILES+=("$tmp")
  retrieve_presented_certificate "$tmp" "$fqdn"
  openssl_quiet x509 -in "$tmp" -noout
}

post_install_checks() {
  local fqdn="$1"
  local expected_cert="$2"
  local presented expected_fp presented_fp
  printf '
Post-installation checks

'
  if (cd "$OPENVAS_DIR" && "$DOCKER_CMD" compose -f "$COMPOSE_FILE" ps -q nginx >/dev/null); then
    ok "nginx container running"
  else
    return 1
  fi
  presented="$(mktemp)"
  TMP_FILES+=("$presented")
  if retrieve_presented_certificate "$presented" "$fqdn"; then
    ok "HTTPS endpoint reachable"
  else
    return 1
  fi
  if openssl_quiet x509 -in "$presented" -noout; then
    ok "TLS handshake successful"
  else
    return 1
  fi
  expected_fp="$(cert_fingerprint "$expected_cert")"
  presented_fp="$(cert_fingerprint "$presented")"
  if [[ "$expected_fp" == "$presented_fp" ]]; then
    ok "Expected certificate is presented"
  else
    return 1
  fi
  if openssl_quiet x509 -in "$presented" -checkend 0 -noout; then
    ok "Certificate is valid"
  else
    return 1
  fi
  if validate_compose_quiet; then
    ok "Docker Compose configuration valid"
  else
    return 1
  fi
}


current_mode() {
  if [[ -f "$CERT_DEST" ]] && awk '/\/etc\/nginx\/certs\/server\.cert\.pem:ro/ { found=1 } END { exit found ? 0 : 1 }' "$COMPOSE_FILE" 2>/dev/null; then
    printf 'Custom certificate'
  else
    printf 'Greenbone self-signed'
  fi
}

show_current_certificate() {
  local fqdn cert remaining
  fqdn="$(prompt_value "OpenVAS FQDN:")"
  cert="$(mktemp)"
  TMP_FILES+=("$cert")
  if ! retrieve_presented_certificate "$cert" "$fqdn" || ! openssl_quiet x509 -in "$cert" -noout; then
    error "Unable to retrieve the certificate presented by nginx."
    return 1
  fi
  remaining="$(days_remaining "$(cert_end "$cert")")"
  printf '\nCurrent HTTPS certificate\n\n'
  printf 'Mode................ %s\n' "$(current_mode)"
  printf 'Subject............. %s\n' "$(cert_subject "$cert")"
  printf 'Issuer.............. %s\n' "$(cert_issuer "$cert")"
  printf 'Valid from.......... %s\n' "$(cert_start "$cert")"
  printf 'Valid until......... %s\n' "$(cert_end "$cert")"
  printf 'Days remaining...... %s\n' "$remaining"
  printf 'SAN................. %s\n' "$(cert_san "$cert")"
  if (( remaining < 0 )); then
    printf 'Status.............. [ERROR] Certificate has expired.\n'
  elif (( remaining < 30 )); then
    printf 'Status.............. [WARNING] Certificate expires in %s days.\n' "$remaining"
  else
    printf 'Status.............. [OK] Certificate valid\n'
  fi
}

install_custom_certificate() {
  local cert key fqdn
  cert="$(prompt_path "Certificate / fullchain path:")"
  key="$(prompt_path "Private key path:")"
  fqdn="$(prompt_value "OpenVAS FQDN:")"

  validate_certificate_files "$cert" "$key" "$fqdn"
  printf '\n'
  confirm "Apply this certificate to Easy-OpenVAS? [y/N]:" || return 0
  require_root
  validate_easy_openvas_installation
  create_backup
  secure_copy_certificate "$cert" "$key"
  apply_compose_file "custom"
  validate_compose_or_rollback || return 1
  if ! reload_tls_services || ! post_install_checks "$fqdn" "$CERT_DEST"; then
    error "TLS validation failed after configuration change."
    restore_backup
    reload_tls_services || true
    printf '\nCustom certificate installation aborted.\n'
    return 1
  fi
  printf '\nCertificate installation successful.\n\n'
  printf 'FQDN................. %s\n' "$fqdn"
  printf 'Certificate.......... %s\n' "$CERT_DEST"
  printf 'Valid until.......... %s\n' "$(cert_end "$CERT_DEST")"
}

restore_self_signed_certificate() {
  printf 'This will restore the Greenbone self-signed certificate.\n'
  printf 'Browser certificate warnings may appear again.\n\n'
  confirm "Continue? [y/N]:" || return 0
  require_root
  info "Restoring Greenbone self-signed TLS..."
  validate_easy_openvas_installation
  create_backup
  apply_compose_file "self-signed"
  validate_compose_or_rollback || return 1
  if ! reload_tls_services; then
    error "TLS validation failed after configuration change."
    restore_backup
    reload_tls_services || true
    return 1
  fi
  rm -f -- "$CERT_DEST" "$KEY_DEST"
  ok "TLS configuration restored"
  ok "Docker Compose configuration valid"
  ok "nginx running"
  if https_endpoint_reachable "${EASY_OPENVAS_FQDN:-localhost}"; then
    ok "HTTPS endpoint reachable"
    ok "Greenbone certificate presented"
  else
    error "Unable to retrieve the certificate presented by nginx."
    restore_backup
    return 1
  fi
  printf '\nGreenbone self-signed certificate restored successfully.\n'
}

check_certificate_files_menu() {
  local cert key fqdn
  cert="$(prompt_path "Certificate / fullchain path:")"
  key="$(prompt_path "Private key path:")"
  fqdn="$(prompt_value "OpenVAS FQDN:")"
  printf '\nCertificate validation\n\n'
  validate_certificate_files "$cert" "$key" "$fqdn"
  printf '\nNo configuration changes were made.\n'
}

menu() {
  while true; do
    cat <<'MENU'
========================================
 Easy-OpenVAS - Certificate Management
========================================

1. Install / replace custom certificate
2. Show current certificate
3. Restore Greenbone self-signed certificate
4. Check certificate files
5. Exit

Choice:
MENU
    local choice
    IFS= read -r choice
    case "$choice" in
      1) install_custom_certificate ;;
      2) show_current_certificate ;;
      3) restore_self_signed_certificate ;;
      4) check_certificate_files_menu ;;
      5) exit 0 ;;
      *) warning "Invalid choice." ;;
    esac
    printf '\n'
  done
}

run_test_command() {
  local command="${1:-}"
  shift || true
  case "$command" in
    validate-certificate) validate_certificate_files "$(resolve_path "$1")" "$(resolve_path "$2")" "$3" ;;
    validate-installation) validate_easy_openvas_installation ;;
    copy-certificate) secure_copy_certificate "$(resolve_path "$1")" "$(resolve_path "$2")" ;;
    apply-custom) apply_compose_file "custom" ;;
    apply-self-signed) apply_compose_file "self-signed" ;;
    install-custom) install_custom_certificate ;;
    restore-self-signed) restore_self_signed_certificate ;;
    show-current) show_current_certificate ;;
    *) error "Unknown test command."; return 2 ;;
  esac
}

main() {
  if [[ "${1:-}" == "--test-command" ]]; then
    shift
    run_test_command "$@"
    return
  fi
  menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
