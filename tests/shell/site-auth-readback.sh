#!/usr/bin/env bash
# site-auth-check.sh reads the Entra gate back and refuses a mismatch, on both
# platforms, without an Azure subscription. The mock answers each read-back
# query from GATE_<FIELD> variables, defaulting to a correct gate for $client.
set -euo pipefail
cd "$(dirname "$0")/../.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PATH="$work:$PATH" GATE_TRACE="$work/trace"
export AZURE_RESOURCE_GROUP=rg-gate-test AZURE_APP_NAME=app-gate-test

cat > "$work/az" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GATE_TRACE"
query=""; prev=""
for a in "$@"; do [[ "$prev" == "--query" ]] && query="$a"; prev="$a"; done
[[ -n "${GATE_FAIL:-}" && "$*" == *"$GATE_FAIL"* ]] && exit 1
case "$*" in
  "webapp show"*"--query id"*) echo "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Web/sites/app-gate-test" ;;
  "containerapp show"*"--query id"*) echo "/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/containerApps/app-gate-test" ;;
  "webapp show"*|"containerapp show"*) echo "app-gate-test.example" ;;
  "resource show"*) echo "${GATE_TAG-11111111-2222-3333-4444-555555555555}" ;;
  "rest --method get"*)
    c=11111111-2222-3333-4444-555555555555
    case "$query" in
      properties.platform.enabled) echo "${GATE_ENABLED:-true}" ;;
      properties.globalValidation.requireAuthentication) echo "${GATE_REQUIRE:-true}" ;;
      properties.globalValidation.unauthenticatedClientAction) echo "${GATE_ACTION:-RedirectToLoginPage}" ;;
      'length(properties.globalValidation.excludedPaths || `[]`)') echo "${GATE_EXCLUDED:-0}" ;;
      *registration.clientId) echo "${GATE_CLIENT:-$c}" ;;
      *registration.clientSecretSettingName) echo "${GATE_SECRET_SETTING:?}" ;;
      *allowedApplications) printf '%s\n' ${GATE_ALLOWED:-$c} ;;
      properties.login.tokenStore.enabled) echo "${GATE_TOKEN_STORE:-false}" ;;
      *) echo "unexpected query $query" >&2; exit 1 ;;
    esac ;;
  *) echo "unexpected az $*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$work/az"

client=11111111-2222-3333-4444-555555555555
expect_rc() { # expect_rc <want> <description> <command...>
  local want="$1" what="$2" rc=0; shift 2
  "$@" > "$work/out" 2>&1 || rc=$?
  if [[ "$rc" != "$want" ]]; then
    echo "FAIL: $what (exit $rc, expected $want)" >&2; cat "$work/out" >&2; exit 1
  fi
}

for platform in appservice containerapps; do
  setting=SITE_AUTH_CLIENT_SECRET
  [[ "$platform" == containerapps ]] && setting=site-auth-client-secret
  export AZURE_PLATFORM="$platform" GATE_SECRET_SETTING="$setting"

  expect_rc 0 "$platform: a correct gate passes" ./scripts/site-auth-check.sh --expect-client-id "$client"
  grep -q "gate is on for client $client" "$work/out"
  expect_rc 0 "$platform: the tag supplies the expectation" ./scripts/site-auth-check.sh
  echo "PASS: $platform reads back a correct gate"

  for bad in GATE_ENABLED=false GATE_ACTION=AllowAnonymous GATE_EXCLUDED=1 \
             GATE_CLIENT=99999999-2222-3333-4444-555555555555 GATE_SECRET_SETTING=literal \
             "GATE_ALLOWED=$client 99999999-2222-3333-4444-555555555555" GATE_TOKEN_STORE=true; do
    expect_rc 1 "$platform: $bad must fail" env "$bad" ./scripts/site-auth-check.sh --expect-client-id "$client"
  done
  echo "PASS: $platform refuses each field that differs"

  expect_rc 0 "$platform: an untagged app with the gate off passes" env GATE_TAG= GATE_ENABLED=false ./scripts/site-auth-check.sh
  expect_rc 1 "$platform: an untagged app with the gate on fails" env GATE_TAG= ./scripts/site-auth-check.sh
  expect_rc 1 "$platform: --expect-off with the gate on fails" ./scripts/site-auth-check.sh --expect-off
  echo "PASS: $platform catches a gate that should be off"

  expect_rc 2 "$platform: unreadable settings are not a pass" env GATE_FAIL="rest --method get" ./scripts/site-auth-check.sh --expect-client-id "$client"
  expect_rc 2 "$platform: a malformed client ID is refused" ./scripts/site-auth-check.sh --expect-client-id 'x" || true'
  echo "PASS: $platform fails closed"
done

# App Service has requireAuthentication; Container Apps has no such field.
expect_rc 1 "appservice: requireAuthentication off must fail" \
  env AZURE_PLATFORM=appservice GATE_SECRET_SETTING=SITE_AUTH_CLIENT_SECRET GATE_REQUIRE=false \
  ./scripts/site-auth-check.sh --expect-client-id "$client"
if grep -q 'rest --method put\|rest --method patch\|resource update' "$GATE_TRACE"; then
  echo 'FAIL: the read-back wrote to Azure' >&2; exit 1
fi
echo 'PASS: the read-back is read-only'

: > "$GATE_TRACE"
AZURE_PLATFORM=containerapps GATE_SECRET_SETTING=site-auth-client-secret \
  ./scripts/site-auth-check.sh --expect-client-id "$client" > /dev/null
if grep -q requireAuthentication "$GATE_TRACE"; then
  echo 'FAIL: Container Apps has no requireAuthentication field to read' >&2; exit 1
fi
echo 'PASS: requireAuthentication is checked only on App Service'
