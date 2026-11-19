#!/usr/bin/env bash
# Exercise Drupal's session independently of the Azure front end.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/compose.sh

url="$1"
upn="$2"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
drush() { "${COMPOSE[@]}" exec -T web vendor/bin/drush "$@"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Establish a Drupal session with a disposable local fixture before the new
# module is enabled. The live Entra callback creates the same Drupal session.
password='local-integration-only-password'
drush user:password "$upn" "$password" >/dev/null 2>&1
payload=$(python3 -c 'import json, sys; print(json.dumps({"name": sys.argv[1], "pass": sys.argv[2]}))' "$upn" "$password")
logout_token=$(curl -fsS -c "$work/cookies" -H 'Content-Type: application/json' \
  --data "$payload" "$url/user/login?_format=json" \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["logout_token"])')
[[ -n "$logout_token" ]] || fail 'fixture did not return a logout token'

drush pm:enable drupal_azure_sso genpass --yes >/dev/null 2>&1
drush config:set azure_oauth_sso.settings enable_sso_logout true --input-format=yaml --yes >/dev/null 2>&1

./scripts/verify-site.sh "$url" --attempts 1 || fail 'public Drupal pages or Entra sign-in link failed'
code=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  --data "$payload" "$url/user/login?_format=json")
[[ "$code" == 403 ]] || fail 'Drupal still accepts password sign-in'
code=$(curl -sS -o /dev/null -w '%{http_code}' "$url/user/password")
[[ "$code" == 403 ]] || fail 'Drupal still serves local password reset'
printf 'PASS: public browsing works and Drupal requires Entra for sign-in\n'

session_url="$url/user/login_status?_format=json"
[[ "$(curl -fsS -b "$work/cookies" "$session_url")" == 1 ]] || fail 'existing Drupal session was lost'
[[ "$(curl -fsS -H 'X-MS-CLIENT-PRINCIPAL-ID: fixture' "$session_url")" == 0 ]] \
  || fail 'a gateway identity created a Drupal session'
code=$(curl -sS -b "$work/cookies" -c "$work/cookies" -o /dev/null -w '%{http_code}' \
  --get -X POST --data-urlencode '_format=json' --data-urlencode "token=$logout_token" "$url/user/logout")
[[ "$code" == 204 ]] || fail 'Drupal logout did not return its normal response'
[[ "$(curl -fsS -b "$work/cookies" "$session_url")" == 0 ]] || fail 'Drupal session remained active after logout'
printf 'PASS: Drupal login state is independent of gateway identity and logout clears it\n'

appservice_probe() {
  "${COMPOSE[@]}" exec -T -e CONTAINER_VERSION=integration -e WEBSITE_HOSTNAME=localhost \
    web bash scripts/appservice-probe.sh 123-1 "$1" --dry-run
}
appservice_probe integration || fail 'App Service probe cannot reach Drupal locally'
if appservice_probe stale >/dev/null 2>&1; then
  fail 'App Service probe passed on the wrong image'
fi
printf 'PASS: the App Service probe checks Drupal on the expected image\n'
