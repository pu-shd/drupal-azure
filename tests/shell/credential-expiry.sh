#!/usr/bin/env bash
# check-credential-expiry.sh against a stub gh with a fixed clock: one issue per
# credential, opened 30 days ahead, refreshed, closed after rotation, and a red
# run when the secret has expired or no date is recorded.
set -euo pipefail
cd "$(dirname "$0")/../.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PATH="$work:$PATH" STUB_DIR="$work" GITHUB_RUN_ID=

cat > "$work/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >> "$STUB_DIR/calls"
[[ -n "${STUB_FAIL:-}" && "$*" == *"$STUB_FAIL"* ]] && exit 1
prev=""
for a in "$@"; do [[ "$prev" == "--body-file" ]] && cp "$a" "$STUB_DIR/body"; prev="$a"; done
[[ "$1 $2" == "issue list" && -f "$STUB_DIR/open" ]] && cat "$STUB_DIR/open"
exit 0
STUB
chmod +x "$work/gh"

# 2027-10-26T00:00:00Z: 30 days before a 2027-11-25 expiry.
NOW=1824508800
reset() { rm -f "$work/calls" "$work/body" "$work/open"; touch "$work/calls"; }
check() { # check <want-exit> <now> <expires> [extra args...]
  local want="$1" now="$2" expires="$3" rc=0; shift 3
  NOW_EPOCH="$now" ./scripts/check-credential-expiry.sh --name "Entra gate client secret" \
    --expires "$expires" --rotate "./scripts/setup-site-gate.sh --rotate --set-repo-vars" "$@" \
    > "$work/out" 2>&1 || rc=$?
  [[ "$rc" == "$want" ]] || { echo "FAIL: exit $rc, expected $want" >&2; cat "$work/out" >&2; exit 1; }
}
called() { grep -qF -- "$1" "$work/calls"; }
must() { "$@" || { echo "FAIL: $*" >&2; cat "$work/calls" >&2; exit 1; }; }
mustnt() { if "$@"; then echo "FAIL: not $*" >&2; cat "$work/calls" >&2; exit 1; fi; }

reset; check 0 $((NOW - 86400 * 60)) 2027-11-25T14:01:17Z
must grep -q 'in 90 days' "$work/out"; mustnt called 'issue create'
echo 'PASS: far from expiry, nothing happens'

reset; check 0 "$NOW" 2027-11-25T14:01:17Z
must called 'issue create --title Credential expiring: Entra gate client secret --label credential-expiry'
must grep -q 'in 30 day(s)' "$work/body"
must grep -qF './scripts/setup-site-gate.sh --rotate --set-repo-vars' "$work/body"
must called 'select(.title == "Credential expiring: Entra gate client secret")'
echo 'PASS: 30 days ahead, one issue opens with the rotation command'

reset; echo 42 > "$work/open"; check 0 "$NOW" 2027-11-25
must called 'issue edit 42 --body-file'; mustnt called 'issue create'
echo 'PASS: an open issue is refreshed, not duplicated'

reset; check 1 $((NOW + 86400 * 31)) 2027-11-25
must grep -q 'expired on 2027-11-25' "$work/body"
echo 'PASS: an expired secret fails the run'

reset; check 1 "$NOW" ''
must grep -q 'no expiry date recorded' "$work/body"
echo 'PASS: an unrecorded expiry fails the run and asks for it'

reset; echo 42 > "$work/open"; check 0 "$NOW" 2028-11-25T09:00:00Z
must called 'issue comment 42'; must called 'issue close 42'
echo 'PASS: a rotation closes the issue'

reset; echo 42 > "$work/open"; check 0 "$NOW" 2027-11-25 --dry-run
must grep -q 'would: update issue #42' "$work/out"
mustnt grep -Eq 'issue (edit|create|close)|label create' "$work/calls"
reset; echo 42 > "$work/open"; check 0 "$NOW" 2028-11-25 --dry-run
must grep -q 'would: close issue #42' "$work/out"; mustnt called 'issue close'
echo 'PASS: --dry-run changes nothing'

reset; check 2 "$NOW" 2027-13-45x; [[ ! -s "$work/calls" ]] || { echo 'FAIL: gh called on bad input' >&2; exit 1; }
reset; check 2 "$NOW" 2027-11-25 --warn-days soon
reset; STUB_FAIL='issue create' check 2 "$NOW" 2027-11-25
echo 'PASS: bad input and a failed issue write are errors'

reset; echo 42 > "$work/open"; check 0 "$NOW" never
must grep -q 'does not expire' "$work/out"; must called 'issue close 42'
echo 'PASS: a credential that never expires closes the issue'

reset; check 1 "$NOW" 2030-01-01 --invalid 'GitHub rejects it (HTTP 401)'
must grep -q 'is being rejected:\*\* GitHub rejects it (HTTP 401)' "$work/body"
reset; check 2 "$NOW" 2030-01-01 --invalid ''
echo 'PASS: a rejected credential fails whatever its date'

wf=.github/workflows/credential-expiry.yml
must grep -q 'vars.DRUPAL_SSO_SECRET_EXPIRES' "$wf"
[[ $(grep -c "if: \${{ !cancelled() &&" "$wf") -ge 2 ]] || { echo 'FAIL: each check must run after an earlier failure' >&2; exit 1; }
echo 'PASS: the workflow checks both secrets independently'
