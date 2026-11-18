#!/usr/bin/env bash
# Reproducible checks without installing PHP or dependencies on the host.
set -euo pipefail
cd "$(dirname "$0")/.."
docker build -f Dockerfile.dev -t drupal-azure-dev:8.4.27 .
docker build -f Dockerfile.test -t drupal-azure-tests:8.4.27 .
docker run --rm drupal-azure-tests:8.4.27
