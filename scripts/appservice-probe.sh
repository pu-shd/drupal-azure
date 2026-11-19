#!/usr/bin/env bash
# Use from inside an App Service container. The SCM API can read the verdict
# from /home when the public application is protected by Easy Auth.
set -euo pipefail

probe_id="${1:-}"
image_tag="${2:-}"
if [[ ! "$probe_id" =~ ^[0-9]+-[0-9]+$ || ! "$image_tag" =~ ^[[:alnum:]_][[:alnum:]_.-]{0,127}$ ]] ||
  (( $# > 3 )) || [[ ${3:-} && ${3:-} != --dry-run ]]; then
  echo 'Usage: appservice-probe.sh <run-id>-<attempt> <image-tag> [--dry-run]' >&2
  exit 2
fi
if [[ "${CONTAINER_VERSION:-}" != "$image_tag" ]]; then
  echo 'The requested image is not serving yet.' >&2
  exit 1
fi
host="${WEBSITE_HOSTNAME:?WEBSITE_HOSTNAME is required}"
if [[ ! "$host" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+$ ]]; then
  echo 'Invalid App Service hostname.' >&2
  exit 2
fi

cd "$(dirname "$0")"
VERIFY_CONNECT_TO="$host:80:127.0.0.1:80" ./verify-site.sh \
  "http://$host" --endpoints / --expect 200,403 --attempts 1 --timeout 20
if [[ "${3:-}" != --dry-run ]]; then
  printf 'ready\n' > "/home/drupal-probe-$probe_id"
fi
