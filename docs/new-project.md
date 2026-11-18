# Starting a new project

The template baseline is Drupal 11.4, PHP 8.4.27 and MySQL 8.4. It incorporates
shared deployment lessons from two maintained Drupal applications. Application
modules, content, identities, tenant configuration and production exports belong
to the new project.

1. Create a repository from this template and initialize the mailer submodule
   with `git submodule update --init --recursive`.
2. Review `example.env`, choose resource names and a hosting platform, and follow
   [Getting started](getting-started.md). Scripts read exported environment
   variables; they do not source an env file automatically.
3. Add custom code under `web/modules/custom` and `web/themes/custom`. Install
   contributed modules through Composer and commit both manifest and lockfile.
   This template uses the recommended `web/` layout; applications with a root
   docroot need their Composer installer paths and file locations adapted.
4. Export configuration to `config/sync`. Use Drupal update hooks for schema/data
   changes. For an existing site, follow [migration](migrating-a-site.md) and audit
   its collation before importing. Never copy a source settings file containing
   credentials, a database dump, uploaded files, logs, or deployment evidence
   into the template or image context.
5. Configure Entra application registrations, trusted hosts, managed identities,
   mail delivery and network access for the new site. See
   [Authentication](authentication.md) and [Email](email.md). Do not reuse tenant
   IDs, OAuth controller overrides, or role mappings from another application.
6. Choose one [cron scheduler](operations.md#background-cron). Set upload field
   limits within PHP's 128 MB file limit; the 144 MB request limit leaves room
   for multipart overhead. Local and production images share these settings.
   Verify the effective web limits, including any application `.user.ini` files.
7. Run `./scripts/test-container.sh` for unit, shell, format and type checks in
   Docker. Set `DRUPAL_HTTP_PORT` and `DRUPAL_DB_FORWARD_PORT` if the default
   local ports are already in use. Then run `./scripts/test.sh --integration` for the production image and
   real MySQL stack. The latter uses disposable Compose volumes; run it in a
   separate checkout from local work whose database you need to keep.
8. Provision a new environment, test SSO, upload/download permissions and real
   email delivery, and confirm successful cron runs. MySQL 8.4 is provisioned
   directly with the defaults; no upgrade or rehearsal is needed.

Base image patches and Composer dependencies are reviewed pins. Update production,
development, Compose, CI and Composer's platform setting together. The test suite
checks runtime parity. Nginx emits request and upstream duration without client
IPs, query strings or auth headers; use those timings to distinguish PHP work
from proxy latency. Add application observability with the same data discipline.
