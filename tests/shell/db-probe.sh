#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for cmd in mysql mysqldump php; do
  cat > "$tmp/$cmd" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$PROBE_ARGS"
case "$(basename "$0")" in
  mysql) exit "${CLI_EXIT:-0}" ;;
  php) exit "${PDO_EXIT:-0}" ;;
  mysqldump)
    [[ "${DUMP_EMPTY:-0}" == 1 ]] && exit 0
    echo 'CREATE TABLE example (id int);'
    echo '-- Dump completed'; exit "${DUMP_EXIT:-0}" ;;
esac
MOCK
  chmod +x "$tmp/$cmd"
done
export PATH="$tmp:$PATH" PROBE_ARGS="$tmp/args"
export DRUPAL_DB_HOST=db DRUPAL_DB_NAME=drupal DRUPAL_DB_USER=test DRUPAL_DB_PASSWORD=secret
bash scripts/db-probe.sh > "$tmp/out"
grep -q 'RESULT: PASS' "$tmp/out"
grep -q -- '--ssl-verify-server-cert' "$tmp/args"
! grep -q 'secret' "$tmp/args" "$tmp/out"
echo 'PASS: probe uses verified TLS and keeps password out of argv/logs'
for failure in CLI_EXIT PDO_EXIT DUMP_EXIT DUMP_EMPTY; do
  if env "$failure=1" bash scripts/db-probe.sh > "$tmp/out"; then
    echo "FAIL: ignored $failure" >&2; exit 1
  fi
  grep -q 'RESULT: FAIL' "$tmp/out"
  echo "PASS: probe fails for $failure"
done
for invalid in DRUPAL_DB_PASSWORD= DRUPAL_DB_PORT=0 DRUPAL_DB_SSL_MODE=invalid 'DRUPAL_DB_PASSWORD=@Microsoft.KeyVault(SecretUri=unresolved)'; do
  if env "$invalid" bash scripts/db-probe.sh > "$tmp/out" 2>&1; then
    echo 'FAIL: invalid probe configuration was accepted' >&2; exit 1
  fi
  echo 'PASS: rejected invalid probe configuration'
done
