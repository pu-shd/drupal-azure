#!/usr/bin/env bash
# Verify the opt-in preflight and ARM arguments without an Azure subscription.
set -euo pipefail
cd "$(dirname "$0")/../.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export SITE_AUTH_TEST_TRACE="$work/trace"
export AZURE_SUBSCRIPTION=test-subscription AZURE_LOCATION=eastus AZURE_BASE_NAME=gate
export AZURE_ENVIRONMENT=dev AZURE_PLATFORM=appservice DRUPAL_TRUSTED_HOSTS=site.example
export PATH="$work:$PATH"

cat > "$work/az" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$SITE_AUTH_TEST_TRACE"
case "$1 $2 $3" in
  'account show --query') printf 'test subscription\n' ;;
  'account set --subscription') ;;
  'group exists --name') printf '%s\n' "${SITE_AUTH_TEST_GROUP_EXISTS:-true}" ;;
  'resource list --resource-group')
    [[ "${SITE_AUTH_TEST_READ_FAIL:-false}" == false ]] || exit 1
    printf '%s\n' "${SITE_AUTH_TEST_EXISTING_CLIENT:-}"
    ;;
  'keyvault list --resource-group') printf 'kv-gate-test\n' ;;
  'keyvault secret show') printf 'fixture-db-password\n' ;;
  'keyvault secret list') printf '%s\n' "${SITE_AUTH_TEST_SECRET_ENABLED:-}" ;;
  'ad signed-in-user show') printf 'fixture-deployer\n' ;;
  'deployment sub create')
    [[ "$*" == *--what-if ]]
    ;;
  *) printf 'Unexpected Azure CLI invocation\n' >&2; exit 1 ;;
esac
MOCK
chmod +x "$work/az"

unset SITE_AUTH_CLIENT_ID
SITE_AUTH_TEST_GROUP_EXISTS=false ./scripts/azure-up.sh --dry-run > "$work/out" 2>&1
grep -q 'deployment sub create' "$SITE_AUTH_TEST_TRACE"
if grep -Eq 'siteAuthClientId=|keyvault secret list' "$SITE_AUTH_TEST_TRACE"; then
  echo 'FAIL: leaving the gate off should require no Entra setup' >&2
  exit 1
fi
echo 'PASS: the default deployment leaves the gate off'

client_id='11111111-2222-3333-4444-555555555555'
for invalid in invalid "$client_id"; do
  : > "$SITE_AUTH_TEST_TRACE"
  if SITE_AUTH_CLIENT_ID="$invalid" ./scripts/azure-up.sh --dry-run > "$work/out" 2>&1; then
    echo 'FAIL: a malformed client ID or missing gate secret was accepted' >&2
    exit 1
  fi
  if grep -q 'deployment sub create' "$SITE_AUTH_TEST_TRACE"; then
    echo 'FAIL: deployment proceeded with invalid gate configuration' >&2
    exit 1
  fi
done
echo 'PASS: enabling the gate requires a valid ID and a configured secret'

: > "$SITE_AUTH_TEST_TRACE"
unset SITE_AUTH_CLIENT_ID
SITE_AUTH_TEST_EXISTING_CLIENT="$client_id" SITE_AUTH_TEST_SECRET_ENABLED=true \
  ./scripts/azure-up.sh --dry-run > "$work/out" 2>&1
grep -q "siteAuthClientId=$client_id" "$SITE_AUTH_TEST_TRACE"
echo 'PASS: an omitted setting preserves a previously enabled gate'

: > "$SITE_AUTH_TEST_TRACE"
if SITE_AUTH_TEST_READ_FAIL=true ./scripts/azure-up.sh --dry-run > "$work/out" 2>&1; then
  echo 'FAIL: an unreadable existing gate was treated as off' >&2
  exit 1
fi
if grep -q 'deployment sub create' "$SITE_AUTH_TEST_TRACE"; then
  echo 'FAIL: deployment proceeded without reading the previous gate' >&2
  exit 1
fi
echo 'PASS: a failed gate lookup stops an infrastructure update'

: > "$SITE_AUTH_TEST_TRACE"
SITE_AUTH_CLIENT_ID='' SITE_AUTH_TEST_EXISTING_CLIENT="$client_id" \
  ./scripts/azure-up.sh --dry-run > "$work/out" 2>&1
grep -q 'deployment sub create' "$SITE_AUTH_TEST_TRACE"
if grep -Eq 'siteAuthClientId=|resource list' "$SITE_AUTH_TEST_TRACE"; then
  echo 'FAIL: explicitly disabling the gate reused the previous registration' >&2
  exit 1
fi
echo 'PASS: an explicitly empty client ID disables the gate'

for platform in appservice containerapps; do
  : > "$SITE_AUTH_TEST_TRACE"
  AZURE_PLATFORM="$platform" SITE_AUTH_CLIENT_ID="$client_id" SITE_AUTH_TEST_SECRET_ENABLED=true \
    ./scripts/azure-up.sh --dry-run > "$work/out" 2>&1
  grep -q "infra/$platform/main.bicep .*siteAuthClientId=$client_id .*--what-if" "$SITE_AUTH_TEST_TRACE"
  echo "PASS: $platform dry run passes the gate client ID to ARM"
done
