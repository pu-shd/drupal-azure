#!/usr/bin/env bash
###############################################################################
# site-auth-check.sh — read back the site-wide Entra gate and check it
#
#   ./scripts/site-auth-check.sh [--expect-client-id <guid> | --expect-off]
#
# Reads what Azure actually stores for the app's platform authentication
# (App Service authsettingsV2, or the container app's authConfigs/current) and
# checks it field by field. With neither flag, the expectation comes from the
# app's siteAuthClientId tag, which the Bicep sets exactly when it enables the
# gate, so a change made in the portal shows up as a mismatch.
#
# Gate on, every one of these must hold:
#   - the platform is enabled, and unauthenticated requests are redirected
#     (App Service: requireAuthentication too)
#   - no excluded paths, so uploads and assets are gated as well
#   - the registration is the expected client, and its secret comes from the
#     setting the template wires to Key Vault
#   - only the gate's own client is an allowed application
#   - no token store
# Gate off: the platform is disabled.
#
# Run by azure-up.sh after a deployment and by the Deploy workflow after each
# rollout. Read-only. Needs AZURE_RESOURCE_GROUP (and AZURE_PLATFORM /
# AZURE_APP_NAME, which are detected when unset).
#
# Exit: 0 matches, 1 does not match, 2 could not read.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/platform.sh"

GUID_RE='^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$'
EXPECT="tag" CLIENT_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --expect-client-id) EXPECT="on"; CLIENT_ID="${2:-}"; shift 2 ;;
    --expect-off) EXPECT="off"; shift ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

fail() { echo "✗ $*" >&2; exit 1; }
unreadable() { echo "✗ $*" >&2; exit 2; }

[[ -n "${AZURE_RESOURCE_GROUP:-}" ]] || unreadable "AZURE_RESOURCE_GROUP is not set"
platform_resolve >/dev/null || exit 2
[[ -n "${AZURE_APP_NAME:-}" ]] || unreadable "no app found in $AZURE_RESOURCE_GROUP"

case "$AZURE_PLATFORM" in
  appservice)
    app_id=$(az webapp show --name "$AZURE_APP_NAME" --resource-group "$AZURE_RESOURCE_GROUP" --query id -o tsv) \
      || unreadable "could not read $AZURE_APP_NAME"
    url="https://management.azure.com${app_id}/config/authsettingsV2?api-version=2023-12-01"
    secret_setting="SITE_AUTH_CLIENT_SECRET"
    ;;
  containerapps)
    app_id=$(az containerapp show --name "$AZURE_APP_NAME" --resource-group "$AZURE_RESOURCE_GROUP" --query id -o tsv) \
      || unreadable "could not read $AZURE_APP_NAME"
    url="https://management.azure.com${app_id}/authConfigs/current?api-version=2024-03-01"
    secret_setting="site-auth-client-secret"
    ;;
esac

if [[ "$EXPECT" == "tag" ]]; then
  CLIENT_ID=$(az resource show --ids "$app_id" --query "tags.siteAuthClientId" -o tsv) \
    || unreadable "could not read the app's siteAuthClientId tag"
  [[ -n "$CLIENT_ID" ]] && EXPECT="on" || EXPECT="off"
fi
if [[ "$EXPECT" == "on" && ! "$CLIENT_ID" =~ $GUID_RE ]]; then
  unreadable "the expected client ID must be a GUID, got '$CLIENT_ID'"
fi

# One field per read, so a mismatch names the field.
field() {
  local got
  got=$(az rest --method get --url "$url" --query "$1" -o tsv) || unreadable "could not read the authentication settings"
  tr '\t\n' '  ' <<<"$got" | sed 's/ *$//'
}
expect() {
  local what="$1" query="$2" want="$3" got
  got=$(field "$query")
  [[ "$got" == "$want" ]] || fail "$what is '$got', expected '$want'"
}

echo "Entra gate on $AZURE_APP_NAME ($AZURE_PLATFORM): expecting $EXPECT${CLIENT_ID:+ for client $CLIENT_ID}"
if [[ "$EXPECT" == "off" ]]; then
  enabled=$(field "properties.platform.enabled")
  [[ "$enabled" != "true" ]] || fail "the gate is ON, but the app's siteAuthClientId tag says it should be off"
  echo "✓ gate is off (read back)"
  exit 0
fi

expect "platform.enabled" "properties.platform.enabled" "true"
if [[ "$AZURE_PLATFORM" == appservice ]]; then
  expect "requireAuthentication" "properties.globalValidation.requireAuthentication" "true"
fi
expect "unauthenticatedClientAction" "properties.globalValidation.unauthenticatedClientAction" "RedirectToLoginPage"
expect "excludedPaths" "length(properties.globalValidation.excludedPaths || \`[]\`)" "0"
expect "clientId" "properties.identityProviders.azureActiveDirectory.registration.clientId" "$CLIENT_ID"
expect "clientSecretSettingName" "properties.identityProviders.azureActiveDirectory.registration.clientSecretSettingName" "$secret_setting"
expect "allowedApplications" "properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications" "$CLIENT_ID"
expect "tokenStore" "properties.login.tokenStore.enabled" "false"
echo "✓ gate is on for client $CLIENT_ID: redirect to sign-in, no excluded paths, no token store (read back)"
