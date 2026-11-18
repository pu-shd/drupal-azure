#!/usr/bin/env bash
set -euo pipefail
composer validate --strict
vendor/bin/phpunit --colors=always --testsuite unit
bash scripts/test.sh --shell
vendor/bin/phpcs --standard=phpcs.xml
vendor/bin/phpstan analyse --configuration=phpstan.neon --no-progress
echo 'PASS: container unit tests, shell tests, format checks, and type checks'
