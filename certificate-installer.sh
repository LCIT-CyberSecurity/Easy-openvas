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

TMP_FILES=()
cleanup_tmp() {
  local path
  for path in "${TMP_FILES[@]:-}"; do
    [[ -n "$path" && -e "$path" ]] && rm -f -- "$path"
  done
  return 0
}
trap cleanup_tmp EXIT

info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
warning() { printf '[WARNING] %s\n' "$*"; }
error() { printf '[ERROR] %s\n' "$*" >&2; }

no_change() {
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
  realpath -- "$input" 2>/dev/null || realpath -m -- "$input"
}

prompt_path() {
  local label="$1" value
  printf '%s\n> ' "$label" >&2
  IFS= read -r value
  resolve_path "$value"
}

prompt_value() {
  local label="$1" value
  printf '%s\n> ' "$label" >&2
  IFS= read -r value
  printf '%s' "$value"
}

confirm() {
  local answer
  printf '%s ' "$1"
  IFS= read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" || "$answer" == "YES" ]]
}

openssl_ok() {
  "$OPENSSL_CMD" "$@" >/dev/null 2>&1
}

cert_subject() { "$OPENSSL_CMD" x509 -in "$1" -noout -subject 2>/dev/null | sed 's/^subject=//'; }
cert_issuer() { "$OPENSSL_CMD" x509 -in "$1" -noout -issuer 2>/dev/null | sed 's/^issuer=//'; }
cert_start() { "$OPENSSL_CMD" x509 -in "$1" -noout -startdate 2>/dev/null | sed 's/^notBefore=//'; }
cert_end() { "$OPENSSL_CMD" x509 -in "$1" -noout -enddate 2>/dev/null | sed 's/^notAfter=//'; }

cert_san() {
  "$OPENSSL_CMD" x509 -in "$1" -noout -ext subjectAltName 2>/dev/null \
    | awk 'NR > 1 { gsub(/^ +| +$/, ""); print }' \
    | tr '\n' ' ' \
    | sed 's/[[:space:]]*$//' \
    || true
}

cert_dns_names() {
  local entry san
  san="$(cert_san "$1")"
  [[ -n "$san" ]] || return 0
  tr ',' '\n' <<<"$san" | while IFS= read -r entry; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ "$entry" == DNS:* ]] && printf '%s\n' "${entry#DNS:}"
  done
}

hostname_matches_dns_san() {
  local fqdn="${1,,}" san="${2,,}" suffix prefix
  [[ "$fqdn" == "$san" ]] && return 0
  [[ "$san" == \*.* ]] || return 1
  suffix="${san#\*.}"
  [[ "$fqdn" == *."$suffix" ]] || return 1
  prefix="${fqdn%."$suffix"}"
  [[ -n "$prefix" && "$prefix" != *.* ]]
}

cert_covers_fqdn() {
  local cert="$1" fqdn="$2" san
  while IFS= read -r san; do
    hostname_matches_dns_san "$fqdn" "$san" && return 0
  done < <(cert_dns_names "$cert")
  return 1
}

date_epoch() { date -d "$1" +%s; }

days_remaining() {
  local end_epoch now_epoch
  end_epoch="$(date_epoch "$(cert_end "$1")")"
  now_epoch="$(date +%s)"
  printf '%s\n' $(((end_epoch - now_epoch) / 86400))
}

cert_fingerprint() {
  "$OPENSSL_CMD" x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'
}

cert_key_match() {
  local cert="$1" key="$2" cert_pub key_pub
  cert_pub="$(mktemp)"
  key_pub="$(mktemp)"
  TMP_FILES+=("$cert_pub" "$key_pub")
  "$OPENSSL_CMD" x509 -in "$cert" -pubkey -noout >"$cert_pub" 2>/dev/null || return 1
  "$OPENSSL_CMD" pkey -in "$key" -pubout >"$key_pub" 2>/dev/null || return 1
  cmp -s "$cert_pub" "$key_pub"
}

cert_is_self_signed() {
  local cert="$1"
  [[ "$(cert_subject "$cert")" == "$(cert_issuer "$cert")" ]] && openssl_ok verify -CAfile "$cert" "$cert"
}

warn_if_single_non_self_signed_cert() {
  local count
  count="$(grep -c -- '-----BEGIN CERTIFICATE-----' "$1" || true)"
  if (( count <= 1 )) && ! cert_is_self_signed "$1"; then
    warning "The supplied certificate file contains only one certificate."
    warning "Make sure required intermediate CA certificates are included."
  fi
}

print_certificate_block() {
  local title="$1" cert="$2" remaining san
  remaining="$(days_remaining "$cert")"
  san="$(cert_san "$cert")"
  printf '\n%s\n\n' "$title"
  printf 'Subject............. %s\n' "$(cert_subject "$cert")"
  printf 'Issuer.............. %s\n' "$(cert_issuer "$cert")"
  printf 'Valid from.......... %s\n' "$(cert_start "$cert")"
  printf 'Valid until......... %s\n' "$(cert_end "$cert")"
  printf 'Days remaining...... %s\n' "$remaining"
  printf 'SAN................. %s\n' "${san:-Not present}"
}

validate_certificate_files() {
  local cert="$1" key="$2" fqdn="$3" remaining
  if [[ -f "$cert" && -r "$cert" ]]; then
    ok "Certificate found"
  else
    no_change "Certificate not found or not readable: $cert"
    return 1
  fi
  if [[ -f "$key" && -r "$key" ]]; then
    ok "Private key found"
  else
    no_change "Private key not found or not readable: $key"
    return 1
  fi
  if openssl_ok x509 -in "$cert" -noout; then
    ok "Certificate valid"
  else
    no_change "Certificate PEM format invalid."
    return 1
  fi
  if openssl_ok pkey -in "$key" -noout; then
    ok "Private key valid"
  else
    no_change "Private key format invalid."
    return 1
  fi
  if cert_key_match "$cert" "$key"; then
    ok "Certificate/private key match"
  else
    no_change "Certificate and private key do not match."
    return 1
  fi
  if (( $(date_epoch "$(cert_start "$cert")") > $(date +%s) )); then
    no_change "Certificate is not valid yet."
    return 1
  fi
  if ! openssl_ok x509 -in "$cert" -checkend 0 -noout; then
    no_change "Certificate has expired."
    return 1
  fi
  if [[ -z "$(cert_dns_names "$cert" | head -n 1)" ]]; then
    no_change "Certificate does not contain a DNS Subject Alternative Name."
    return 1
  fi
  if cert_covers_fqdn "$cert" "$fqdn"; then
    ok "Certificate valid for $fqdn"
  else
    no_change "Certificate does not cover $fqdn."
    return 1
  fi
  warn_if_single_non_self_signed_cert "$cert"
  print_certificate_block "Certificate information" "$cert"
  remaining="$(days_remaining "$cert")"
  (( remaining < 30 )) && warning "Certificate expires in $remaining days."
  return 0
}

service_exists() {
  awk -v svc="$1" '$0 ~ "^  " svc ":$" { found=1 } END { exit found ? 0 : 1 }' "$COMPOSE_FILE"
}

compose_mount_counts() {
  awk '
    /^  nginx:$/ { svc="nginx"; next }
    /^  [A-Za-z0-9_-]+:$/ { svc="" }
    svc=="nginx" && /^[[:space:]]*-[[:space:]]+nginx_certificates_vol:\/etc\/nginx\/certs:ro/ { green++ }
    svc=="nginx" && /^[[:space:]]*-[[:space:]]+\/[^#]*\/certs:\/etc\/nginx\/certs:ro/ { custom++ }
    END { printf "%d %d\n", green, custom }
  ' "$COMPOSE_FILE"
}

compose_has_managed_mount() {
  awk '
    /^  nginx:$/ { svc="nginx"; next }
    /^  [A-Za-z0-9_-]+:$/ { svc="" }
    svc=="nginx" && /nginx_certificates_vol:\/etc\/nginx\/certs:ro/ { found=1 }
    svc=="nginx" && /\/certs:\/etc\/nginx\/certs:ro/ { found=1 }
    END { exit found ? 0 : 1 }
  ' "$COMPOSE_FILE"
}

validate_compose_structure() {
  local green custom
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    no_change "Unsupported Greenbone Compose structure."
    return 1
  fi
  service_exists nginx || { no_change "Unsupported Greenbone Compose structure."; return 1; }
  compose_has_managed_mount || { no_change "Unsupported Greenbone Compose structure."; return 1; }
  read -r green custom < <(compose_mount_counts)
  if (( green + custom != 1 )); then
    no_change "Unsupported Greenbone Compose structure."
    return 1
  fi
}

docker_compose_config() {
  (cd "$OPENVAS_DIR" && "$DOCKER_CMD" compose -f "$COMPOSE_FILE" config >/dev/null)
}

create_backup() {
  info "Creating rollback backup..."
  rm -rf -- "$BACKUP_DIR"
  mkdir -p -- "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  cp -- "$COMPOSE_FILE" "$BACKUP_DIR/compose.yaml"
  [[ -f "$CERT_DEST" ]] && cp -- "$CERT_DEST" "$BACKUP_DIR/server.cert.pem"
  if [[ -f "$KEY_DEST" ]]; then
    cp -- "$KEY_DEST" "$BACKUP_DIR/server.key"
    chmod 600 "$BACKUP_DIR/server.key"
  fi
  ok "Backup created"
}

restore_backup() {
  info "Restoring previous configuration..."
  cp -- "$BACKUP_DIR/compose.yaml" "$COMPOSE_FILE"
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

copy_certificate() {
  local cert="$1" key="$2" tmp_cert tmp_key
  mkdir -p -- "$CERTS_DIR"
  chown root:root "$CERTS_DIR" 2>/dev/null || true
  chmod 700 "$CERTS_DIR"
  tmp_cert="$(mktemp "$CERTS_DIR/.server.cert.pem.XXXXXX")"
  tmp_key="$(mktemp "$CERTS_DIR/.server.key.XXXXXX")"
  TMP_FILES+=("$tmp_cert" "$tmp_key")
  cp -- "$cert" "$tmp_cert"
  cp -- "$key" "$tmp_key"
  chown root:root "$tmp_cert" "$tmp_key" 2>/dev/null || true
  chmod 644 "$tmp_cert"
  chmod 600 "$tmp_key"
  mv -f -- "$tmp_cert" "$CERT_DEST"
  mv -f -- "$tmp_key" "$KEY_DEST"
  return 0
}

switch_compose_mount() {
  local mode="$1" tmp
  tmp="$(mktemp)"
  TMP_FILES+=("$tmp")
  awk -v mode="$mode" -v certs="$CERTS_DIR" '
    function emit_block() {
      if (emitted) return
      print "      # Greenbone default self-signed certificate:"
      if (mode == "self-signed") print "      - nginx_certificates_vol:/etc/nginx/certs:ro"
      else print "      # - nginx_certificates_vol:/etc/nginx/certs:ro"
      print ""
      print "      # Easy-OpenVAS custom certificate:"
      if (mode == "custom") print "      - " certs ":/etc/nginx/certs:ro"
      else print "      # - " certs ":/etc/nginx/certs:ro"
      emitted=1
    }
    /^  nginx:$/ { svc="nginx"; print; next }
    /^  [A-Za-z0-9_-]+:$/ {
      if (svc=="nginx" && !emitted) emit_block()
      svc=""
      print
      next
    }
    svc=="nginx" && /^[[:space:]]*#?[[:space:]]*Greenbone default self-signed certificate:/ { emit_block(); next }
    svc=="nginx" && /^[[:space:]]*#?[[:space:]]*Easy-OpenVAS custom certificate:/ { next }
    svc=="nginx" && /nginx_certificates_vol:\/etc\/nginx\/certs:ro/ { emit_block(); next }
    svc=="nginx" && /\/certs:\/etc\/nginx\/certs:ro/ { emit_block(); next }
    { print }
    END { if (svc=="nginx" && !emitted) emit_block() }
  ' "$COMPOSE_FILE" >"$tmp"
  mv -f -- "$tmp" "$COMPOSE_FILE"
  return 0
}

recreate_nginx() {
  (cd "$OPENVAS_DIR" && "$DOCKER_CMD" compose -f "$COMPOSE_FILE" up -d --force-recreate nginx >/dev/null)
}

nginx_running() {
  local id status
  id="$(cd "$OPENVAS_DIR" && "$DOCKER_CMD" compose -f "$COMPOSE_FILE" ps -q nginx 2>/dev/null | head -n 1)"
  [[ -n "$id" ]] || return 1
  status="$($DOCKER_CMD inspect --format='{{.State.Status}}' "$id" 2>/dev/null || true)"
  [[ "$status" == "running" ]]
}

retrieve_presented_certificate() {
  local output="$1" fqdn="$2"
  if [[ -n "$HTTPS_CERT_CMD" ]]; then
    EASY_OPENVAS_CERT_OUTPUT="$output" EASY_OPENVAS_FQDN="$fqdn" bash -c "$HTTPS_CERT_CMD"
    return
  fi
  "$OPENSSL_CMD" s_client -connect "$TLS_HOST:$TLS_PORT" -servername "$fqdn" -showcerts </dev/null 2>/dev/null \
    | "$OPENSSL_CMD" x509 -outform PEM >"$output"
}

wait_for_https() {
  local fqdn="$1" output="$2" attempt attempts delay
  attempts="${EASY_OPENVAS_HTTPS_RETRIES:-10}"
  delay="${EASY_OPENVAS_HTTPS_RETRY_DELAY:-2}"
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if retrieve_presented_certificate "$output" "$fqdn" && openssl_ok x509 -in "$output" -noout; then
      ok "HTTPS endpoint reachable"
      return 0
    fi
    (( attempt < attempts )) && sleep "$delay"
  done
  error "HTTPS endpoint did not become ready."
  return 1
}

post_install_checks() {
  local fqdn="$1" expected_cert="$2" presented expected_fp presented_fp
  printf '\nPost-installation checks\n\n'
  nginx_running && ok "nginx container running" || return 1
  presented="$(mktemp)"
  TMP_FILES+=("$presented")
  wait_for_https "$fqdn" "$presented" || return 1
  openssl_ok x509 -in "$presented" -noout && ok "TLS handshake successful" || return 1
  expected_fp="$(cert_fingerprint "$expected_cert")"
  presented_fp="$(cert_fingerprint "$presented")"
  if [[ "$expected_fp" == "$presented_fp" ]]; then
    ok "Expected certificate is presented"
    return 0
  fi
  error "The certificate presented by nginx does not match the installed certificate."
  return 1
}

compose_mode() {
  local green custom
  read -r green custom < <(compose_mount_counts)
  if (( custom == 1 )); then
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
  retrieve_presented_certificate "$cert" "$fqdn" && openssl_ok x509 -in "$cert" -noout \
    || { error "Unable to retrieve the certificate presented by nginx."; return 1; }
  printf '\nCurrent HTTPS certificate\n\n'
  printf 'Mode................ %s\n' "$(compose_mode)"
  printf 'Subject............. %s\n' "$(cert_subject "$cert")"
  printf 'Issuer.............. %s\n' "$(cert_issuer "$cert")"
  printf 'Valid from.......... %s\n' "$(cert_start "$cert")"
  printf 'Valid until......... %s\n' "$(cert_end "$cert")"
  remaining="$(days_remaining "$cert")"
  printf 'Days remaining...... %s\n' "$remaining"
  printf 'SAN................. %s\n' "$(cert_san "$cert")"
  if (( remaining < 0 )); then
    printf 'Status.............. [ERROR] Certificate has expired.\n'
  elif (( remaining < 30 )); then
    printf 'Status.............. [WARNING] Certificate expires in %s days.\n' "$remaining"
  else
    printf 'Status.............. [OK] Certificate valid\n'
  fi
  return 0
}

validate_compose_or_rollback() {
  if docker_compose_config; then
    ok "Docker Compose configuration valid"
    return 0
  fi
  error "Docker Compose configuration invalid."
  restore_backup
  return 1
}

rollback_and_recreate() {
  restore_backup
  recreate_nginx || true
}

install_custom_certificate() {
  local cert key fqdn
  cert="$(prompt_path "Certificate / fullchain path:")"
  key="$(prompt_path "Private key path:")"
  fqdn="$(prompt_value "OpenVAS FQDN:")"
  validate_certificate_files "$cert" "$key" "$fqdn" || return 1
  printf '\n'
  confirm "Apply this certificate to Easy-OpenVAS? [y/N]:" || return 0
  require_root
  validate_compose_structure || return 1
  create_backup
  copy_certificate "$cert" "$key"
  switch_compose_mount custom
  validate_compose_or_rollback || return 1
  if ! recreate_nginx || ! post_install_checks "$fqdn" "$CERT_DEST"; then
    rollback_and_recreate
    printf '\nCustom certificate installation aborted.\n'
    return 1
  fi
  printf '\nCertificate installation successful.\n'
}

restore_self_signed_certificate() {
  local fqdn before after
  printf 'This will restore the Greenbone self-signed certificate.\n\n'
  confirm "Continue? [y/N]:" || return 0
  fqdn="${EASY_OPENVAS_FQDN:-localhost}"
  require_root
  validate_compose_structure || return 1
  before="$(mktemp)"
  after="$(mktemp)"
  TMP_FILES+=("$before" "$after")
  retrieve_presented_certificate "$before" "$fqdn" >/dev/null 2>&1 || true
  create_backup
  switch_compose_mount self-signed
  validate_compose_or_rollback || return 1
  if ! recreate_nginx; then
    rollback_and_recreate
    return 1
  fi
  printf '\nPost-restoration checks\n\n'
  nginx_running && ok "nginx container running" || { rollback_and_recreate; return 1; }
  wait_for_https "$fqdn" "$after" || { rollback_and_recreate; return 1; }
  openssl_ok x509 -in "$after" -noout && ok "TLS handshake successful" || { rollback_and_recreate; return 1; }
  if [[ -s "$before" ]] && [[ "$(cert_fingerprint "$before")" == "$(cert_fingerprint "$after")" ]]; then
    error "The certificate presented by nginx did not change."
    rollback_and_recreate
    return 1
  fi
  ok "Greenbone self-signed certificate restored"
  printf '\nGreenbone self-signed certificate restored successfully.\n'
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
4. Exit

Choice:
MENU
    local choice
    IFS= read -r choice
    case "$choice" in
      1) install_custom_certificate ;;
      2) show_current_certificate ;;
      3) restore_self_signed_certificate ;;
      4) exit 0 ;;
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
    validate-installation) validate_compose_structure ;;
    copy-certificate) copy_certificate "$(resolve_path "$1")" "$(resolve_path "$2")" ;;
    apply-custom) validate_compose_structure && switch_compose_mount custom ;;
    apply-self-signed) validate_compose_structure && switch_compose_mount self-signed ;;
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
