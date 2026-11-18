#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for value in -1 1 299 abc 01 999999999999999999999; do
  if DRUPAL_CRON_INTERVAL="$value" bash scripts/cron-loop.sh --check >"$tmp/out" 2>&1; then
    echo "FAIL: accepted invalid interval $value" >&2; exit 1
  fi
  echo "PASS: rejected invalid interval $value"
done
for value in 0 300 3600; do
  DRUPAL_CRON_INTERVAL="$value" bash scripts/cron-loop.sh --check
  echo "PASS: accepted interval $value"
done
cat > "$tmp/drush" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == cron ]]
echo call >> "$CRON_CALLS"
echo 'sensitive exception context'
[[ $(wc -l < "$CRON_CALLS") -gt 1 ]]
MOCK
chmod +x "$tmp/drush"
output="$(APP_ROOT="$PWD" CRON_CALLS="$tmp/calls" DRUPAL_CRON_INTERVAL=300 \
  DRUPAL_CRON_DELAY=0 DRUPAL_CRON_RUNS=2 DRUPAL_CRON_SLEEP=true \
  DRUPAL_CRON_DRUSH="$tmp/drush" bash scripts/cron-loop.sh)"
[[ $(wc -l < "$tmp/calls") -eq 2 ]]
[[ "$output" == *'exit 1'* && "$output" == *'exit 0'* ]]
[[ "$output" != *'sensitive exception context'* ]]
echo 'PASS: failed run is reported, sensitive output is suppressed, next run succeeds'
rm "$tmp/calls"
DRUPAL_CRON_INTERVAL=0 CRON_CALLS="$tmp/calls" DRUPAL_CRON_DRUSH="$tmp/drush" \
  bash scripts/cron-loop.sh
[[ ! -e "$tmp/calls" ]]
echo 'PASS: disabled cron never invokes drush'
