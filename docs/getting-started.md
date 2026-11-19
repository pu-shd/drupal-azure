# Getting started

From nothing to a deployed Drupal site. Roughly 20 minutes of work, most of it
waiting for Azure.

If you only want to poke at it locally, **[step 1](#1-run-it-locally)** is enough
and needs no Azure account.

---

## Prerequisites

| | Needed for | |
|---|---|---|
| Docker + `docker-compose` | local development, the image gate | [install](https://docs.docker.com/get-docker/) |
| Azure CLI (`az`) | everything on Azure | [install](https://aka.ms/install-azure-cli) |
| An Azure account | deploying | Must be able to create resource groups **and role assignments** — subscription Owner, or Contributor + User Access Administrator |
| `git` | cloning with submodules | |

You do **not** need PHP, Composer or Drush on your machine: everything runs in
the container. You do **not** need Docker to deploy — `az acr build` builds in
Azure.

```bash
git clone --recurse-submodules <this repo>
cd drupal-azure
```

The `--recurse-submodules` matters. The mailer module is a submodule; without it
the image builds without mail support and you find out at runtime.

---

## 1. Run it locally

```bash
./scripts/local-dev.sh
```

Brings up MySQL 8 and the web container, installs dependencies inside the
container, installs Drupal, and verifies it serves.

```
http://localhost:8080     admin / admin
```

The local database is **MySQL 8 with production's collation and `sql_mode`**, not
MariaDB with defaults. That is deliberate: the point of a local environment is to
reproduce failures, and a database differing from production in exactly the ways
Drupal is sensitive to cannot do that.

```bash
./scripts/local-dev.sh --shell     # a shell in the container
./scripts/local-dev.sh --down      # stop, keep the database
./scripts/local-dev.sh --reset     # discard the database and start over
docker-compose exec web vendor/bin/drush <command>
```

### Run the tests

```bash
./scripts/test.sh                  # everything
./scripts/test.sh --unit           # fast: settings-overlay logic only
```

The integration suite builds the production image and boots it against a real
MySQL 8, so it takes a few minutes. It is the one that would catch a broken
deploy before Azure does.

---

## 2. Choose a platform

This is the one real decision, and it is easier to make now than later.

**App Service is the default and is the right answer for most departmental
sites.** Take it unless you know you need otherwise.

| Pick | When |
|---|---|
| **App Service** (default) | Tens to low hundreds of users. A restart of tens of seconds during a deploy is acceptable. You want file transfer and commands-with-exit-codes into the running container without building them |
| **Container Apps** | Deploys must be zero-downtime and you will not pay for App Service S1. Or you genuinely need horizontal autoscaling |

Full comparison with the evidence behind it:
**[Choosing a platform](choosing-a-platform.md)**.

---

## 3. Deploy the infrastructure

```bash
az login

./scripts/azure-up.sh --what-if     # preview — creates nothing
./scripts/azure-up.sh
```

The script prompts for anything it needs and skips the prompt when the value is
already in the environment, so the same script works interactively and in CI.

**It does not ask for a password.** It generates the MySQL password and the Drupal
hash salt on the first run and writes them straight into Key Vault; later runs
pass empty values so the stored ones are left alone. Nothing is typed, pasted, or
left in your shell history. [Why](secrets.md#how-they-get-there).

Common overrides:

```bash
AZURE_LOCATION=canadacentral \
AZURE_BASE_NAME=mysite \
AZURE_PLATFORM=containerapps \
DRUPAL_TRUSTED_HOSTS=drupal.example.edu \
  ./scripts/azure-up.sh
```

`AZURE_BASE_NAME` is capped at **11 characters** — longer produces an invalid
storage account name. The script checks before provisioning anything.

Everything tunable is in **[Configuration](configuration.md)**.

If this site requires an Entra sign-in to browse, follow the gate setup before
making the first image available to visitors.
[Optional site-wide Entra gate](authentication.md#optional-site-wide-entra-gate)

### Capture the names it created

The script prints the deployment outputs at the end. Set them in your shell — the
rest of this guide, and every operational script, reads them from there:

```bash
export AZURE_RESOURCE_GROUP=rg-drupal-prod          # as printed
export AZURE_PLATFORM=appservice                    # or containerapps

# The rest can be read back from Azure at any time:
export AZURE_ACR_NAME=$(az acr list -g "$AZURE_RESOURCE_GROUP" --query '[0].name' -o tsv)
export AZURE_APP_NAME=$(az webapp list -g "$AZURE_RESOURCE_GROUP" --query '[0].name' -o tsv)

echo "registry: $AZURE_ACR_NAME"
echo "app:      $AZURE_APP_NAME"
```

Worth putting in a shell profile or a `.envrc` for the environment you work on
most. With them set, nothing prompts.

> **Migrating an existing site?** Stop here and read
> **[Migrating a site](migrating-a-site.md)** first. The collation of your
> existing data has to be set *before* you deploy, and getting it wrong surfaces
> months later.

---

## 4. Build and push the first image

The app is created pointing at an image tag that does not exist yet, so it will
not serve until you push one. That is expected, not a failure.

```bash
SHA=$(git rev-parse --short=12 HEAD)
az acr build --registry "$AZURE_ACR_NAME" \
  --image "drupal:$SHA" --image drupal:latest \
  --build-arg "COMMIT_SHA=$SHA" .
```

`az acr build` builds in Azure, so no local Docker is needed and the layers do not
travel up from your laptop.

`--build-arg COMMIT_SHA` is **not optional**. It becomes `CONTAINER_VERSION` in
the image, which is how the entrypoint tells a deploy apart from a restart.
Without it, every instance start re-runs the schema updates.
`verify-production-image.sh` fails a build that omits it.

Then point the app at it — on App Service that is one command:

```bash
az webapp config container set \
  -n "$AZURE_APP_NAME" -g "$AZURE_RESOURCE_GROUP" \
  --container-image-name "$AZURE_ACR_NAME.azurecr.io/drupal:$SHA"

az webapp restart -n "$AZURE_APP_NAME" -g "$AZURE_RESOURCE_GROUP"
```

(On Container Apps this is `az containerapp update --image …` instead, and the new
revision takes traffic only after it is healthy.)

Watch it come up:

```bash
./scripts/azure-logs.sh
```

The first boot connects to MySQL and starts the web server. With an empty
database, install Drupal from the container shell in the next step. Once Drupal
is installed, a restart runs the deployment tasks and records the image version.

---

## 5. Install Drupal and bootstrap the Entra admin

Use this step on a new database only. For an existing site, follow the
[migration runbook](migrating-a-site.md) to preserve its accounts and content.
Keep the site restricted to setup operators while configuring sign-in.

Get the administrator's exact `userPrincipalName` and `mail` from their Entra
user record. The UPN becomes Drupal's username for user 1, the initial super
admin. Use the value of `mail` for the account email, even when it differs from
the UPN. The bundled `azure_oauth_sso` module looks up existing Drupal users by
the `mail` value returned by Microsoft Graph. Choose an admin whose `mail` is set
and whose UPN meets Drupal's username rules, including the 60-character limit.

Open an interactive shell in the **running Drupal container**. Use the command
for your platform from a terminal signed in to Azure.

```bash
# App Service (preview command in Azure CLI 2.90.0 or later)
az webapp exec --resource-group "$AZURE_RESOURCE_GROUP" --name "$AZURE_APP_NAME"

# Container Apps
az containerapp exec --resource-group "$AZURE_RESOURCE_GROUP" \
  --name "$AZURE_APP_NAME" --command bash
```

The Azure portal also provides an [App Service container shell](https://learn.microsoft.com/en-us/azure/app-service/configure-linux-open-ssh-session)
and a [Container Apps console](https://learn.microsoft.com/en-us/azure/container-apps/container-console).

Run the following in that shell. It uses the database settings already present
in the container and stops if it finds any tables other than the entrypoint's
deployment-state table. Drush generates a random local password. `--quiet`
keeps it and the one-time login URL out of the command output.

```bash
(
  set -euo pipefail
  cd /var/www/html

  table_count=$(vendor/bin/drush sql:query --extra=--skip-column-names \
    "SELECT COUNT(*) FROM information_schema.tables
     WHERE table_schema = DATABASE() AND table_name <> 'azure_deploy_state'")
  if [[ "$table_count" != 0 ]]; then
    printf 'Installation requires a new database with no site tables.\n' >&2
    exit 1
  fi

  read -rsp 'Initial administrator Entra userPrincipalName: ' admin_upn
  printf '\n'
  read -rsp 'Initial administrator Microsoft Graph mail: ' admin_mail
  printf '\n'
  read -rp 'Drupal site name: ' site_name
  if [[ -z "$admin_upn" || -z "$admin_mail" || -z "$site_name" ]]; then
    printf 'Enter all three values to continue.\n' >&2
    exit 1
  fi

  chmod a-w web/sites/default/settings.php
  if ! vendor/bin/drush site:install standard --yes --quiet \
    --account-name="$admin_upn" --account-mail="$admin_mail" --site-name="$site_name"; then
    printf 'Drupal installation failed. Check the database state before retrying.\n' >&2
    exit 1
  fi

  if [[ "$(vendor/bin/drush user:information --uid=1 --field=name)" != "$admin_upn" ||
        "$(vendor/bin/drush user:information --uid=1 --field=mail)" != "$admin_mail" ]]; then
    printf 'Drupal user 1 does not match the requested Entra account.\n' >&2
    exit 1
  fi
  printf 'Drupal installed and the initial super admin verified.\n'
)
```

Restart the app or active revision, then check its logs. Complete the Entra app
registration and verify the initial admin sign-in before opening the site to
users. [Entra app registration](authentication.md#setting-up-the-app-registration)
· [Verify the initial admin sign-in](authentication.md#verify-the-initial-admin-sign-in)

---

## 6. Verify

```bash
HOST=$(az webapp show -n "$AZURE_APP_NAME" -g "$AZURE_RESOURCE_GROUP" \
  --query defaultHostName -o tsv)
./scripts/verify-site.sh "https://$HOST"
```

Three outcomes, and the third one matters:

| | Meaning |
|---|---|
| **pass** | The application answered, with the expected status and a clean body |
| **fail** | The application answered and something is wrong |
| **inconclusive** | The request never reached the application. **Not a pass** — nothing was verified |

An IP allowlist or the optional Entra gate can intercept the probe. Verify the
site from an allowed network and an authenticated browser when applicable.

---

## 7. Finish outbound email

The Logic App and Office 365 connection were created in step 3. Two things
remain, one of which needs a human:

```bash
./scripts/setup-email.sh
```

It stores the endpoint on the app, then prints a portal URL where someone must
sign in as the mailbox the site should send **as**. That consent cannot be
scripted — it is how a human proves they control the mailbox, which is what buys
you a deployment with no SMTP password.

```bash
./scripts/setup-email.sh --status
./scripts/setup-email.sh --test you@example.edu
```

Do not skip this and assume mail works. Drupal's fallback mail system accepts
every message and delivers none, with no error anywhere — so the first sign of
trouble is a user who cannot reset their password. Details in
**[Outbound email](email.md)**.

## 8. Hand the deploys to CI

Set up OIDC federation — no stored credentials — following
**[GitHub Actions](github-actions.md)**. After that, a push to `main` builds,
verifies, rolls out and smoke-tests on its own.

---

## What next

| | |
|---|---|
| Something broke | **[Troubleshooting](troubleshooting.md)** |
| Day-to-day running | **[Operations](operations.md)** |
| Set up logins | **[Authentication](authentication.md)** — the template is Entra-only |
| Email not arriving | **[Outbound email](email.md)** |
| Bring an existing site in | **[Migrating a site](migrating-a-site.md)** |
| Change a setting | **[Configuration](configuration.md)** |
| Understand a design decision | **[Design notes](design-notes.md)** |
