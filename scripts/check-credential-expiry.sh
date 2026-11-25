#!/usr/bin/env bash
# Open, update or close a tracking issue for a credential that expires.
#
# Run daily by the Credential Expiry Reminder workflow, once per credential. The
# expiry comes from a repository variable that the script which creates the
# credential records (setup-site-gate.sh --set-repo-vars records SITE_AUTH_SECRET_EXPIRES).
# Reading it from Entra instead would need a Microsoft Graph permission with
# admin consent, which the deploy identity does not have.
#
#   more than WARN_DAYS left   close any open issue for it (it was rotated); exit 0
#   WARN_DAYS or fewer left    open the issue, or refresh its body; exit 0
#   expired                    open or refresh the issue, marked EXPIRED; exit 1
#   rejected (--invalid)       open or refresh the issue with the reason; exit 1
#   no expiry recorded         open or refresh an issue asking for it; exit 1
#   never expires (never)      close any open issue for it; exit 0
#
# One issue per credential, found by its label and title, so a daily run edits
# the same issue rather than filing a new one. Safe to re-run.
#
# Usage:
#   check-credential-expiry.sh --name NAME --expires DATE --rotate COMMAND
#                              [--invalid REASON] [--warn-days N] [--dry-run]
#
#   --name       what the credential is, e.g. "Sign-in gate client secret"
#   --expires    YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ (UTC), or "never"; empty
#                means unrecorded
#   --rotate     how to renew it (commands, one per line), quoted into the issue
#   --invalid    the credential is already rejected (e.g. HTTP 401), whatever its
#                date says; REASON goes into the issue
#   --warn-days  how far ahead to open the issue (default 30)
#   --dry-run    print what would happen to the issue; change nothing
#
# Environment: GH_TOKEN (and GH_REPO outside a checkout) for gh; NOW_EPOCH
# overrides the current time (tests).

set -euo pipefail

NAME="" EXPIRES="" ROTATE="" WARN_DAYS=30 DRY_RUN="no" EXPIRES_GIVEN="no" INVALID="" INVALID_GIVEN="no"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --expires) EXPIRES="${2:-}"; EXPIRES_GIVEN="yes"; shift 2 ;;
    --rotate) ROTATE="${2:-}"; shift 2 ;;
    --invalid) INVALID="${2:-}"; INVALID_GIVEN="yes"; shift 2 ;;
    --warn-days) WARN_DAYS="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="yes"; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "✗ $*" >&2; exit 2; }
[[ -n "$NAME" ]] || die "--name is required"
[[ "$EXPIRES_GIVEN" == "yes" ]] || die "--expires is required (pass an empty value if none is recorded)"
[[ -n "$ROTATE" ]] || die "--rotate is required"
[[ "$INVALID_GIVEN" == "no" || -n "$INVALID" ]] || die "--invalid needs a reason"
[[ "$WARN_DAYS" =~ ^[0-9]+$ ]] || die "--warn-days must be a whole number of days, got '$WARN_DAYS'"
# The name goes into an issue title and a gh search; keep it to plain text.
[[ "$NAME" =~ ^[A-Za-z0-9\ ._()-]+$ ]] || die "--name may hold only letters, digits, spaces and . _ ( ) -"

LABEL="credential-expiry"
TITLE="Credential expiring: $NAME"

# Seconds since the epoch for a UTC date, with GNU date (runners, containers)
# or BSD date (macOS).
to_epoch() {
  local d="$1"
  [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && d="${d}T00:00:00Z"
  [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]] || return 1
  d="${d%%.*}"; d="${d%Z}Z"
  date -u -d "$d" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$d" +%s 2>/dev/null
}

now="${NOW_EPOCH:-$(date -u +%s)}"
[[ "$now" =~ ^[0-9]+$ ]] || die "NOW_EPOCH must be seconds since the epoch"

state="" days="" expiry_date=""
if [[ -n "$INVALID" ]]; then
  state="invalid"
elif [[ "$EXPIRES" == "never" ]]; then
  state="never"
elif [[ -z "$EXPIRES" ]]; then
  state="unrecorded"
else
  exp=$(to_epoch "$EXPIRES") || die "--expires must be YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ, got '$EXPIRES'"
  expiry_date="${EXPIRES%%T*}"
  # Whole days left, rounded down: 0 means it expires within a day.
  days=$(( (exp - now) / 86400 ))
  if (( exp <= now )); then state="expired"
  elif (( days <= WARN_DAYS )); then state="due"
  else state="ok"
  fi
fi

run_url=""
if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
  run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/$GITHUB_RUN_ID"
fi

body_file=$(mktemp)
trap 'rm -f "$body_file"' EXIT
{
  case "$state" in
    unrecorded)
      echo "**$NAME** has no expiry date recorded, so nothing can remind anyone before it expires."
      echo
      echo "Record it by re-running the setup script, which reads the date from Entra and sets the repository variable:"
      ;;
    expired)
      echo "**$NAME expired on $expiry_date.** Whatever depends on it is failing now."
      echo
      echo "Rotate it:"
      ;;
    invalid)
      echo "**$NAME is being rejected:** $INVALID. Whatever depends on it is failing now."
      echo
      echo "Renew it:"
      ;;
    due)
      echo "**$NAME expires on $expiry_date**, in $days day(s). Rotate it before then."
      echo
      echo "Rotate it:"
      ;;
  esac
  echo
  echo '```sh'
  echo "$ROTATE"
  echo '```'
  echo
  echo "Renewing records the new expiry date (or the source reports it), and this issue closes on the next daily run."
  echo
  [[ -n "$run_url" ]] && echo "Checked by [this run]($run_url)." && echo
  echo "_This issue is updated daily by the Credential Expiry Reminder workflow, and closed once the recorded expiry is more than $WARN_DAYS days away._"
} > "$body_file"

say() { echo "$*"; }
act() {
  local what="$1"; shift
  if [[ "$DRY_RUN" == "yes" ]]; then
    say "would: $what"
  else
    "$@" >/dev/null || { echo "✗ failed: $what" >&2; exit 2; }
    say "$what"
  fi
}

open_issue() {
  gh issue list --state open --label "$LABEL" --search "\"$TITLE\" in:title" \
    --json number,title --jq ".[] | select(.title == \"$TITLE\") | .number" | head -n 1
}

case "$state" in
  ok|never)
    if [[ "$state" == "never" ]]; then
      say "✓ $NAME does not expire."; expiry_date="never"
    else
      say "✓ $NAME expires on $expiry_date, in $days days (more than $WARN_DAYS)."
    fi
    number=$(open_issue) || { echo "✗ could not list issues" >&2; exit 2; }
    if [[ -n "$number" ]]; then
      act "comment on and close issue #$number (expiry is now $expiry_date)" \
        gh issue comment "$number" --body "Resolved: $NAME now expires $([[ $expiry_date == never ]] && echo never || echo "on $expiry_date, more than $WARN_DAYS days away"). Closing automatically."
      act "close issue #$number" gh issue close "$number"
    fi
    exit 0
    ;;
esac

case "$state" in
  unrecorded) say "✗ $NAME: no expiry recorded." ;;
  expired) say "✗ $NAME expired on $expiry_date." ;;
  invalid) say "✗ $NAME is being rejected: $INVALID" ;;
  due) say "! $NAME expires on $expiry_date, in $days day(s)." ;;
esac

number=$(open_issue) || { echo "✗ could not list issues" >&2; exit 2; }
if [[ -n "$number" ]]; then
  act "update issue #$number" gh issue edit "$number" --body-file "$body_file"
else
  # Creating the label is idempotent; it may already exist.
  [[ "$DRY_RUN" == "yes" ]] || gh label create "$LABEL" --color D93F0B \
    --description "A credential is close to expiry" >/dev/null 2>&1 || true
  act "open issue \"$TITLE\"" gh issue create --title "$TITLE" --label "$LABEL" --body-file "$body_file"
fi
[[ "$DRY_RUN" == "yes" ]] && { echo "--- issue body ---"; cat "$body_file"; }

[[ "$state" == "due" ]] && exit 0
exit 1
