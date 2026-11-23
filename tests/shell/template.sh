#!/usr/bin/env bash
# Regression coverage for deployment patterns shared by the reference deployments.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - <<'PY'
import json
import pathlib
import re
import unittest

class TemplateTest(unittest.TestCase):
    def test_runtime_parity(self):
        for path in ('Dockerfile', 'Dockerfile.dev'):
            self.assertIn('ARG PHP_VERSION=8.4.27', pathlib.Path(path).read_text())
        manifest = json.loads(pathlib.Path('composer.json').read_text())
        self.assertEqual('8.4.27', manifest['config']['platform']['php'])
        self.assertEqual('^11.4', manifest['require']['drupal/core-recommended'])

    def test_database_version_parity(self):
        for path in ('infra/modules/mysql.bicep', 'infra/appservice/main.bicep', 'infra/containerapps/main.bicep'):
            self.assertIn("param mysqlVersion string = '8.4'", pathlib.Path(path).read_text())
        for platform in ('appservice', 'containerapps'):
            self.assertIn("'MYSQL_VERSION', '8.4'", pathlib.Path('infra', platform, 'main.bicepparam').read_text())
        self.assertIn('image: mysql:8.4.7', pathlib.Path('docker-compose.yml').read_text())
        self.assertIn('MYSQL_VERSION=8.4', pathlib.Path('example.env').read_text())

    def test_upload_chain(self):
        ini = pathlib.Path('docker/php/drupal.ini').read_text()
        def value(name):
            return int(re.search(r'^' + name + r'\s*=\s*(\d+)', ini, re.M)[1])
        self.assertGreater(value('post_max_size'), value('upload_max_filesize'))
        self.assertGreaterEqual(value('max_input_time'), 300)
        nginx = pathlib.Path('docker/nginx/default.conf').read_text()
        self.assertGreaterEqual(int(re.search(r'client_max_body_size (\d+)M', nginx)[1]), value('post_max_size'))
        self.assertIn('COPY docker/php/drupal.ini', pathlib.Path('Dockerfile.dev').read_text())

    def test_context_hygiene(self):
        for path in ('.gitignore', '.dockerignore'):
            content = pathlib.Path(path).read_text()
            for pattern in ('build/', '.audit/', 'cutovers/', 'rehearsals/', '__pycache__/', '*.db'):
                self.assertIn(pattern, content, (path, pattern))

    def test_local_ports_are_configurable(self):
        compose = pathlib.Path('docker-compose.yml').read_text()
        self.assertIn('${DRUPAL_HTTP_PORT:-8080}:80', compose)
        self.assertIn('${DRUPAL_DB_FORWARD_PORT:-13306}:3306', compose)

    def test_cron_wiring(self):
        self.assertIn('[program:drupal-cron]', pathlib.Path('docker/supervisor/supervisord.conf').read_text())
        self.assertIn('DRUPAL_CRON_INTERVAL', pathlib.Path('infra/modules/appservice.bicep').read_text())
        self.assertIn('DRUPAL_CRON_INTERVAL', pathlib.Path('infra/modules/aca.bicep').read_text())

    def test_site_auth_is_opt_in_and_covers_all_paths(self):
        for platform, module in (('appservice', 'appservice'), ('containerapps', 'aca')):
            main = pathlib.Path('infra', platform, 'main.bicep').read_text()
            hosting = pathlib.Path('infra', 'modules', module + '.bicep').read_text()
            self.assertIn('param siteAuthClientId string?', main)
            self.assertIn('siteAuthClientId: siteAuthClientId', main)
            self.assertIn('enabled: siteAuthEnabled', hosting)
            self.assertIn("siteAuthEnabled ? 'RedirectToLoginPage' : 'AllowAnonymous'", hosting)
            self.assertIn('excludedPaths: []', hosting)
            self.assertIn('allowedApplications: [siteAuthClientId!]', hosting)
            self.assertIn('secrets/site-auth-client-secret', main)

    # Lowest major version of each action whose runtime is Node 24. GitHub
    # forces Node 20 actions onto Node 24 with a deprecation warning, and will
    # eventually stop doing so. An action missing from this table fails the
    # test, so a new dependency has to be checked rather than slipping in.
    NODE24_MIN_MAJOR = {
        'actions/checkout': 5,
        'actions/create-github-app-token': 3,
        'azure/login': 3,
        'peter-evans/create-pull-request': 8,
        'shivammathur/setup-php': 2,
    }

    def test_workflow_actions_run_on_node24(self):
        uses = re.compile(r'^\s*(?:-\s*)?uses:\s*([\w.-]+/[\w.-]+)@v(\d+)\s*$', re.M)
        found = 0
        for path in sorted(pathlib.Path('.github/workflows').glob('*.yml')):
            for action, major in uses.findall(path.read_text()):
                found += 1
                self.assertIn(action, self.NODE24_MIN_MAJOR, f'{path}: {action} has no known Node 24 version')
                self.assertGreaterEqual(int(major), self.NODE24_MIN_MAJOR[action], f'{path}: {action}@v{major} runs on Node 20')
        # A regex that stopped matching would otherwise pass vacuously.
        self.assertGreater(found, 10)

    def test_composer_update_body_stays_out_of_the_commit(self):
        # create-pull-request commits every change in the working tree. A body
        # file written there lands in the update PR and then on main.
        workflow = pathlib.Path('.github/workflows/composer-update.yml').read_text()
        self.assertIsNone(re.search(r'(?<![/\w])pr-body\.md', workflow), 'composer-update.yml writes pr-body.md inside the checkout')
        self.assertFalse(pathlib.Path('pr-body.md').exists(), 'pr-body.md is checked in at the repository root')

unittest.main(verbosity=2)
PY
bash tests/shell/cron.sh
bash tests/shell/db-probe.sh
bash tests/shell/site-auth.sh
