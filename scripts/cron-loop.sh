#!/usr/bin/env bash
# Sequential cron for App Service. Container Apps uses its scheduled Job instead.
# Supervisor runs this as www-data, preserving environment-based Drupal settings.
set -euo pipefail
interval="${DRUPAL_CRON_INTERVAL:-0}"
delay="${DRUPAL_CRON_DELAY:-120}"
runs="${DRUPAL_CRON_RUNS:-0}"
for name in interval delay runs; do
  value="${!name}"
  if [[ ! "$value" =~ ^(0|[1-9][0-9]{0,8})$ ]]; then
    echo "cron: $name must be a nonnegative integer below 1000000000" >&2
    exit 1
  fi
done
if (( interval != 0 && interval < 300 )); then
  echo 'cron: DRUPAL_CRON_INTERVAL must be 0 (off) or at least 300 seconds' >&2
  exit 1
fi
case "${1:-}" in
  --check) echo 'cron: configuration valid'; exit 0 ;;
  '') ;;
  *) echo 'usage: drupal-cron-loop [--check]' >&2; exit 2 ;;
esac
if (( interval == 0 )); then
  echo 'cron: disabled; an external scheduler must own cron'
  exit 0
fi
cd "${APP_ROOT:-/var/www/html}"
sleeper="${DRUPAL_CRON_SLEEP:-sleep}"
drush="${DRUPAL_CRON_DRUSH:-vendor/bin/drush}"
echo "cron: every $interval seconds; first run in $delay seconds"
"$sleeper" "$delay"
n=0
while :; do
  status=0
  # Drupal output may contain user data or credentials from exception contexts.
  # Report status only; investigate failures through a separate drush invocation.
  "$drush" cron >/dev/null 2>&1 || status=$?
  echo "cron: run completed with exit $status"
  n=$((n + 1))
  if (( runs > 0 && n >= runs )); then
    break
  fi
  "$sleeper" "$interval"
done
