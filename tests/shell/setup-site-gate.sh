#!/usr/bin/env bash
# setup-site-gate.sh: --dry-run writes nothing to Entra, Key Vault or GitHub;
# a real run asks for a minimal registration and records the expiry.
set -euo pipefail
cd "$(dirname "$0")/../.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PATH="$work:$PATH" TRACE="$work/trace"
export AZURE_RESOURCE_GROUP=rg-gate-test AZURE_PLATFORM=appservice AZURE_APP_NAME=app-gate-test
export GITHUB_REPO=example/site

cat > "$work/az" <<'MOCK'
#!/usr/bin/env bash
printf 'az %s\n' "$*" >> "$TRACE"
case "$*" in
  "account show"*) echo sub ;;
  "keyvault list"*) echo kv-gate-test ;;
  "webapp show"*"hostNames"*) printf 'app-gate-test.example.net\tsite.example.edu\n' ;;
  "webapp show"*) echo app-gate-test.example.net ;;
  "ad app list"*) if [[ -f "$STUB_DIR_EXISTS" ]]; then echo 11111111-2222-3333-4444-555555555555; fi ;;
  "ad app show"*) printf 'AzureADMyOrg\t0\t0\t2\ttrue\n' ;;
  "ad sp show"*) echo sp ;;
  "keyvault secret show"*) echo id ;;
  "ad app credential list"*) echo 2027-11-25T14:01:17.123Z ;;
  "ad app update"*|"ad app create"*|"ad sp create"*|"keyvault secret set"*|"ad app credential reset"*) ;;
  *) echo "unexpected az $*" >&2; exit 1 ;;
esac
MOCK
printf '#!/usr/bin/env bash\nprintf "gh %%s\\n" "$*" >> "$TRACE"\n' > "$work/gh"
chmod +x "$work/az" "$work/gh"

export STUB_DIR_EXISTS="$work/no-such-file"
./scripts/setup-site-gate.sh --dry-run --rotate --set-repo-vars > "$work/out" 2>&1
if grep -Eq 'ad app (create|update)|ad sp create|credential reset|secret set|gh variable set' "$TRACE"; then
  echo 'FAIL: --dry-run changed something' >&2; cat "$TRACE" >&2; exit 1
fi
grep -q 'https://site.example.edu/.auth/login/aad/callback' "$work/out"
echo 'PASS: --dry-run writes nothing and lists a callback per hostname'

: > "$TRACE"; touch "$work/exists"; export STUB_DIR_EXISTS="$work/exists"
./scripts/setup-site-gate.sh --set-repo-vars > "$work/out" 2>&1
grep -q -- '--sign-in-audience AzureADMyOrg' "$TRACE"
grep -q -- '--required-resource-accesses \[\]' "$TRACE"
grep -q -- '--enable-id-token-issuance true' "$TRACE"
if grep -q 'credential reset' "$TRACE"; then
  echo 'FAIL: a secret was created although the vault has one and --rotate was not given' >&2; exit 1
fi
grep -q 'gh variable set SITE_AUTH_SECRET_EXPIRES --repo example/site --body 2027-11-25T14:01:17Z' "$TRACE"
echo 'PASS: a minimal registration, no surprise secret, expiry recorded without fractions'

: > "$TRACE"
if GATE_HOSTS='bad host;rm' ./scripts/setup-site-gate.sh --dry-run > "$work/out" 2>&1; then
  echo 'FAIL: a malformed hostname was accepted' >&2; exit 1
fi
echo 'PASS: hostnames are validated'
