#!/usr/bin/env bash
###############################################################################
# setup-site-gate.sh — create, update or rotate the Entra gate's registration
#
#   ./scripts/setup-site-gate.sh [--dry-run] [--rotate] [--set-repo-vars]
#
# The optional site-wide gate (docs/authentication.md) needs its own app
# registration, separate from Drupal's, with only the grants it uses -- nothing
# that requires admin consent:
#
#   - single tenant: any valid login from the subscription's tenant
#   - no API permissions; at sign-in the gate asks for openid, profile and
#     email, which users can normally consent to themselves
#   - web redirect URIs: /.auth/login/aad/callback on each hostname
#   - ID token issuance on. The gate requests response_type=code id_token, and
#     with it off every sign-in ends in a 401 at the callback.
#   - a client secret, written straight into the deployment Key Vault as
#     site-auth-client-secret and never printed. Created when the vault has
#     none, or on --rotate.
#
# --set-repo-vars records the secret's expiry in the GitHub repository variable
# SITE_AUTH_SECRET_EXPIRES. The Credential Expiry Reminder workflow checks it
# daily and opens an issue 30 days ahead. Re-run with just this flag to record
# it again.
#
# Turning the gate on is separate: SITE_AUTH_CLIENT_ID=<printed ID>
# ./scripts/azure-up.sh. Safe to re-run: the registration is found by name.
# Needs a signed-in user who can create app registrations and set Key Vault
# secrets. Reads AZURE_RESOURCE_GROUP, AZURE_PLATFORM, AZURE_APP_NAME; optional
# GATE_APP_NAME (default <app>-site-gate), GATE_HOSTS (default: the app's
# hostnames), GATE_SECRET_YEARS (default 1), GITHUB_REPO (default: this checkout's).
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/prompt.sh"
source "$SCRIPT_DIR/lib/secrets.sh"
source "$SCRIPT_DIR/lib/platform.sh"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
die()  { printf '%s✗ %s%s\n' "$RED" "$*" "$NC" >&2; exit 1; }
ok()   { printf '%s✓ %s%s\n' "$GREEN" "$*" "$NC"; }
step() { printf '\n%s%s%s%s\n' "$BLUE" "$BOLD" "$*" "$NC"; }

DRY_RUN="no" ROTATE="no" SET_VARS="no"
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN="yes" ;;
    --rotate) ROTATE="yes" ;;
    --set-repo-vars) SET_VARS="yes" ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# Run a change, or describe it under --dry-run. Messages go to stderr, because
# ensure_app's stdout is the app ID its caller captures.
change() {
  local what="$1"; shift
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "  would: $what" >&2
  else
    "$@" || die "failed: $what"
  fi
}

prompt_resource_group
platform_resolve || exit 1
APP="${AZURE_APP_NAME:?no app found in $AZURE_RESOURCE_GROUP}"
KV="$(keyvault_name "$AZURE_RESOURCE_GROUP" || true)"
[[ -n "$KV" ]] || die "no Key Vault found in $AZURE_RESOURCE_GROUP; deploy the infrastructure first (azure-up.sh)"

GATE_APP_NAME="${GATE_APP_NAME:-$APP-site-gate}"
GATE_SECRET_NAME="site-auth-client-secret"
GATE_SECRET_YEARS="${GATE_SECRET_YEARS:-1}"
[[ "$GATE_SECRET_YEARS" =~ ^[1-9]$ ]] || die "GATE_SECRET_YEARS must be 1-9"
if [[ -z "${GATE_HOSTS:-}" ]]; then
  case "$AZURE_PLATFORM" in
    appservice)
      GATE_HOSTS=$(az webapp show -n "$APP" -g "$AZURE_RESOURCE_GROUP" --query "hostNames" -o tsv) ;;
    containerapps)
      GATE_HOSTS=$(az containerapp show -n "$APP" -g "$AZURE_RESOURCE_GROUP" \
        --query "[properties.configuration.ingress.fqdn, properties.configuration.ingress.customDomains[].name][]" -o tsv) ;;
  esac
fi
GATE_HOSTS=$(tr '\t\n' '  ' <<<"$GATE_HOSTS")
for h in $GATE_HOSTS; do
  [[ "$h" =~ ^[A-Za-z0-9.-]+$ ]] || die "not a hostname: '$h'"
done
[[ -n "${GATE_HOSTS// /}" ]] || die "no hostnames found for $APP; set GATE_HOSTS"

# appId of the single registration with this display name ("" if none).
app_id_for() {
  local ids count
  ids=$(az ad app list --display-name "$1" --query "[].appId" -o tsv) || die "could not list app registrations"
  count=$(grep -c . <<<"$ids" || true)
  [[ "$count" -le 1 ]] || die "$count app registrations are named '$1'; resolve that by hand first"
  echo "$ids"
}

step "[1/3] Gate app registration: $GATE_APP_NAME"
GATE_ID=$(app_id_for "$GATE_APP_NAME") || exit 1
if [[ -z "$GATE_ID" ]]; then
  change "create app registration $GATE_APP_NAME (single tenant)" \
    az ad app create --display-name "$GATE_APP_NAME" --sign-in-audience AzureADMyOrg --output none
  if [[ "$DRY_RUN" == "yes" ]]; then
    GATE_ID="<new>"
  else
    GATE_ID=$(app_id_for "$GATE_APP_NAME") || exit 1
    [[ -n "$GATE_ID" ]] || die "created $GATE_APP_NAME but cannot find it"
  fi
fi
redirects=()
for h in $GATE_HOSTS; do redirects+=("https://$h/.auth/login/aad/callback"); done
if [[ "$GATE_ID" == "<new>" ]]; then
  echo "  would: set redirect URIs (${redirects[*]}), ID tokens on, no API permissions" >&2
else
  change "set single tenant, redirect URIs, ID tokens on, no API permissions" \
    az ad app update --id "$GATE_ID" --sign-in-audience AzureADMyOrg \
      --web-redirect-uris "${redirects[@]}" \
      --enable-id-token-issuance true --required-resource-accesses "[]" --output none
  if [[ "$DRY_RUN" == "no" ]]; then
    want="AzureADMyOrg 0 0 ${#redirects[@]} true"
    got=$(az ad app show --id "$GATE_ID" --query "[signInAudience, length(requiredResourceAccess), length(appRoles), length(web.redirectUris), web.implicitGrantSettings.enableIdTokenIssuance]" -o tsv | tr '\t\n' '  ' | sed 's/ *$//')
    [[ "$got" == "$want" ]] || die "read back: $GATE_APP_NAME is '$got', expected '$want'"
  fi
  if ! az ad sp show --id "$GATE_ID" --query id -o tsv >/dev/null 2>&1; then
    change "create its service principal" az ad sp create --id "$GATE_ID" --output none
  fi
fi
ok "$GATE_APP_NAME: $GATE_ID"

step "[2/3] Gate secret in Key Vault $KV as $GATE_SECRET_NAME"
has_secret="no"
az keyvault secret show --vault-name "$KV" --name "$GATE_SECRET_NAME" --query id -o tsv >/dev/null 2>&1 && has_secret="yes"
if [[ "$has_secret" == "yes" && "$ROTATE" == "no" ]]; then
  ok "already in Key Vault; not rotated (use --rotate)"
elif [[ "$DRY_RUN" == "yes" || "$GATE_ID" == "<new>" ]]; then
  echo "  would: add a ${GATE_SECRET_YEARS}-year client secret and store it in $KV/$GATE_SECRET_NAME"
else
  umask 077
  secret_file=$(mktemp)
  trap 'rm -f "$secret_file" "$secret_file.raw"' EXIT
  # Straight from Entra into a 0600 file and from there into the vault; the
  # value never reaches the terminal, the process list or a log.
  az ad app credential reset --id "$GATE_ID" --append --display-name "site-gate $(date -u +%Y-%m-%d)" \
    --years "$GATE_SECRET_YEARS" --query password -o tsv > "$secret_file.raw" \
    || die "could not create a client secret"
  # -o tsv ends the value with a newline, and secret set --file stores the file
  # byte for byte: strip it, or the gate sends it as part of the secret.
  tr -d '\r\n' < "$secret_file.raw" > "$secret_file"
  rm -f "$secret_file.raw"
  [[ -s "$secret_file" ]] || die "Entra returned an empty secret"
  az keyvault secret set --vault-name "$KV" --name "$GATE_SECRET_NAME" --file "$secret_file" \
    --encoding utf-8 --output none || die "could not store the secret in $KV"
  rm -f "$secret_file"
  ok "new client secret stored in $KV/$GATE_SECRET_NAME (not printed)"
fi

step "[3/3] Expiry"
# The newest secret is the one in Key Vault (this script stores each one it
# creates), so its end date is the one that matters. Dates only, no values.
EXPIRES=""
if [[ "$GATE_ID" != "<new>" ]]; then
  EXPIRES=$(az ad app credential list --id "$GATE_ID" --query "max_by(@, &endDateTime).endDateTime" -o tsv) \
    || die "could not read the gate's secret end dates"
  EXPIRES="${EXPIRES%%.*}"; [[ -z "$EXPIRES" || "$EXPIRES" == *Z ]] || EXPIRES="${EXPIRES}Z"
fi
echo "  SITE_AUTH_SECRET_EXPIRES=${EXPIRES:-(set from the new secret on the next run)}"
if [[ "$SET_VARS" == "yes" ]]; then
  repo="${GITHUB_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)}"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "could not determine the GitHub repository; set GITHUB_REPO=owner/name"
  if [[ -n "$EXPIRES" ]]; then
    change "set SITE_AUTH_SECRET_EXPIRES=$EXPIRES on $repo" \
      gh variable set SITE_AUTH_SECRET_EXPIRES --repo "$repo" --body "$EXPIRES"
  elif [[ "$DRY_RUN" == "yes" ]]; then
    echo "  would: set SITE_AUTH_SECRET_EXPIRES on $repo to the new secret's end date"
  else
    die "$GATE_APP_NAME has no secrets, so there is no expiry to record"
  fi
else
  echo "  Record it for the expiry reminder: re-run with --set-repo-vars."
fi

printf '\n%s%sDone.%s\n' "$GREEN" "$BOLD" "$NC"
echo "  Gate client ID: $GATE_ID"
echo "  Turn the gate on with: SITE_AUTH_CLIENT_ID=$GATE_ID ./scripts/azure-up.sh"
if [[ "$ROTATE" == "yes" ]]; then
  echo "  The app reads the new secret at its next restart. Restart it, check sign-in,"
  echo "  then delete the old credential: az ad app credential list --id $GATE_ID"
fi
