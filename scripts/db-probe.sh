#!/usr/bin/env bash
# Run inside the app container before and after a database engine/auth upgrade.
# Uses only the configured Drupal host and never writes a dump to disk.
set -euo pipefail
for name in DRUPAL_DB_HOST DRUPAL_DB_NAME DRUPAL_DB_USER DRUPAL_DB_PASSWORD; do
  if [[ -z "${!name:-}" || "${!name}" == '@Microsoft.KeyVault('* ]]; then
    echo "FAIL: $name is missing or unresolved" >&2; exit 1
  fi
done
port="${DRUPAL_DB_PORT:-3306}"
[[ "$port" =~ ^[0-9]{1,5}$ ]] && (( port > 0 && port <= 65535 )) || {
  echo 'FAIL: invalid database port' >&2; exit 1;
}
case "${1:-}" in
  '') with_drupal=false ;;
  --drupal) with_drupal=true ;;
  *) echo 'usage: db-probe.sh [--drupal]' >&2; exit 2 ;;
esac
flags=(--host="$DRUPAL_DB_HOST" --port="$port" --user="$DRUPAL_DB_USER")
case "${DRUPAL_DB_SSL_MODE:-verify}" in
  verify) flags+=(--ssl-ca="${DRUPAL_DB_SSL_CA:-/etc/ssl/certs/ca-certificates.crt}" --ssl-verify-server-cert) ;;
  on) flags+=(--ssl) ;;
  off) flags+=(--skip-ssl) ;;
  *) echo 'FAIL: invalid DRUPAL_DB_SSL_MODE' >&2; exit 1 ;;
esac
export MYSQL_PWD="$DRUPAL_DB_PASSWORD"
failed=0
check() {
  if "$@" >/dev/null 2>&1; then
    echo "PASS: $label"
  else
    echo "FAIL: $label"; failed=1
  fi
}
label=cli_login
check timeout 30 mysql "${flags[@]}" "$DRUPAL_DB_NAME" -e 'SELECT 1'
label=pdo_login
check timeout 30 php -r '
  $options = [PDO::ATTR_TIMEOUT => 10];
  $mode = getenv("DRUPAL_DB_SSL_MODE") ?: "verify";
  if ($mode !== "off") {
    $options[PDO::MYSQL_ATTR_SSL_CA] = getenv("DRUPAL_DB_SSL_CA") ?: "/etc/ssl/certs/ca-certificates.crt";
    $options[PDO::MYSQL_ATTR_SSL_VERIFY_SERVER_CERT] = $mode === "verify";
  }
  $pdo = new PDO("mysql:host=" . getenv("DRUPAL_DB_HOST") . ";port=" . (getenv("DRUPAL_DB_PORT") ?: "3306") . ";dbname=" . getenv("DRUPAL_DB_NAME"), getenv("DRUPAL_DB_USER"), getenv("DRUPAL_DB_PASSWORD"), $options);
  exit($pdo->query("SELECT 1")->fetchColumn() == 1 ? 0 : 1);'
# A zero exit alone cannot establish that the dump finished.
dump=''
if dump=$(timeout 30 mysqldump "${flags[@]}" --no-data --single-transaction "$DRUPAL_DB_NAME" 2>/dev/null) \
   && [[ "$dump" == *'-- Dump completed'* && "$dump" == *'CREATE TABLE'* ]]; then
  echo 'PASS: schema_dump'
else
  echo 'FAIL: schema_dump'; failed=1
fi
if "$with_drupal"; then
  boot=''
  if boot=$(timeout 120 vendor/bin/drush status --field=bootstrap 2>/dev/null) && [[ "$boot" == Successful ]]; then
    echo 'PASS: drupal_bootstrap'
  else
    echo 'FAIL: drupal_bootstrap'; failed=1
  fi
fi
if (( failed )); then echo 'RESULT: FAIL'; exit 1; fi
echo 'RESULT: PASS'
