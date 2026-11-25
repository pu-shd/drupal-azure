# Authentication

**Read this before letting anyone use the site.** How people log in.

Not to be confused with **[GitHub Actions](github-actions.md)**, which is about
how *CI* authenticates to Azure.

Drupal sign-in uses Entra ID once the site completes the authentication setup.
Visitors can browse public content without signing in. Enable the optional
Azure Entra gate to require a sign-in before any request reaches Drupal.

---

## The modules

| Module | Source | Role |
|---|---|---|
| `drupal_azure_sso` | included | Redirects Drupal sign-in to Entra, disables core password login and reset, and keeps Drupal logout local |
| `drupal/azure_oauth_sso` | contrib, Composer | The OAuth login route. Redirects to Entra, consumes the callback, maps the returning identity to a Drupal account |
| `drupal/externalauth` | contrib, Composer (dependency) | The account↔external-identity mapping table. What makes "this Entra object is this Drupal user" durable |
| `drupal/genpass` | contrib, Composer | Generates a random password on every account, and hides the field |
| `azure_logic_app_mailer` | **submodule**, `pu-orfe/azure_logic_app_mailer` | Outbound mail via a managed-identity-authenticated Azure Logic App |

All three contrib modules are in `composer.json`. The mailer is a submodule
because it is first-party, has no drupal.org release, and depends on Azure
resources — so it is versioned alongside the sites that use it rather than
vendored into each one:

```bash
git clone --recurse-submodules <this repo>
# or, in an existing checkout:
git submodule update --init --recursive
```

The Docker build needs the submodule present. `actions/checkout` does not fetch
submodules by default — add `with: submodules: true` to any workflow that builds
the image, or the mailer is silently absent from it.

---

## Why `genpass` is not optional

Accounts are NetID-shaped: username is the NetID, email is derived from it, and
the password is a random value that is **never displayed and never used**.

Without `genpass`, three things go wrong, and none of them announces itself:

- **`/admin/people/create` demands a password.** An administrator creating an
  account has to invent one, which means either a weak shared convention or a
  real credential that now exists and is written down somewhere.
- **Programmatic account creation gets an empty password.** A bulk NetID import,
  or any `User::create()` without an explicit password, produces an account whose
  password hash is for the empty string. Drupal will not authenticate it — until
  a module or a future core change makes empty-password login behave differently,
  at which point every imported account is open.
- **`/user/password` becomes a working side channel.** A password reset link
  lets someone set a local password and bypass Entra entirely, which quietly
  undoes the "Entra only" property the deployment is built on.

`genpass` generates a strong random value and hides the password field.
The template's `drupal_azure_sso` module redirects `/user/login` to
`/oauth/login` and disables core password login, reset and public registration.

---

## What the settings overlay contributes

`docker/drupal/settings.azure.php` does not configure SSO — that is site
configuration, exported to `config/sync`. What it does provide is the three
things an OAuth flow needs from the *environment*, all of which are easy to get
wrong behind a TLS-terminating ingress:

**HTTPS normalisation.** The ingress terminates TLS and forwards over HTTP, so
without normalisation Drupal builds `http://` absolute URLs. The redirect URI
Drupal sends to Entra then does not match the one registered on the app
registration, and the failure is Entra's generic
`AADSTS50011: redirect URI mismatch` — which points at the app registration
rather than at the proxy.

**Reverse-proxy trust.** Without it Drupal sees the ingress as the client for
every request, so `X-Forwarded-*` is ignored — which breaks the same absolute
URLs and makes flood control treat all traffic as one IP.

**Trusted hosts.** Drupal builds those absolute URLs from the `Host` header, so
an untrusted or over-permissive host list is how a password-reset link ends up
pointing at somebody else's domain. Built from `DRUPAL_TRUSTED_HOSTS` with proper
escaping; see `tests/php/TrustedHostsTest.php`, where most of the assertions are
about which hosts are *refused*.

---

## Optional site-wide Entra gate

App Service and Container Apps support Azure platform authentication in front of
Drupal. The gate is off by default. Drupal still controls permissions and
account mapping through its own OAuth sign-in. IP restrictions apply in both
modes.

With the gate on, a visitor with a valid sign-in from the deployment's Entra
tenant can reach the site. Azure checks requests for pages, assets, and uploaded
files. Drupal treats that visitor as anonymous until they choose **Log in** and
complete Drupal's OAuth flow. The browser may reuse its Microsoft sign-in,
so the second flow may complete without a prompt.

**Log out** ends the Drupal session. The visitor can still browse pages available
to anonymous Drupal users while the eight-hour Azure gate session lasts. To
leave both sessions, log out of Drupal first and then visit `/.auth/logout`.

### Enable or disable the gate

1. Create the gate's own app registration and its secret:
   `./scripts/setup-site-gate.sh --set-repo-vars` (preview with `--dry-run`).
   It finds or creates `<app>-site-gate`. The registration is single tenant,
   has no API permissions and issues ID tokens. It has a **Web** redirect URI
   `https://<hostname>/.auth/login/aad/callback` for each of the app's
   hostnames; set `GATE_HOSTS` to list them yourself. The script writes a
   one-year client secret straight into the deployment Key Vault as
   `site-auth-client-secret` and never prints it. With `--set-repo-vars` it
   records the secret's expiry in the repository variable
   `SITE_AUTH_SECRET_EXPIRES`. Run it as someone who can create app
   registrations and set Key Vault secrets. Leave user assignment optional
   for access by any user in the tenant. Keep Drupal's own app registration
   and its `/oauth/login` callback. On a new deployment that must stay
   private, provision the infrastructure with an ingress allowlist first, and
   enable the gate before you bring the site online or widen ingress access.
2. Run `SITE_AUTH_CLIENT_ID=<printed client ID> ./scripts/azure-up.sh`
   (preview with `--dry-run`). Later runs reuse that registration if the
   variable is unset. To disable the gate, run
   `SITE_AUTH_CLIENT_ID='' ./scripts/azure-up.sh`. Image-only rollouts keep
   the Azure authentication settings.
3. `azure-up.sh` and every CI rollout then **read the gate back**
   (`scripts/site-auth-check.sh`). They check that it redirects unauthenticated
   requests, excludes no paths, uses the expected client and Key Vault secret,
   allows only the gate's own client and keeps no token store. They take the
   expectation from the app's `siteAuthClientId` tag, so a change made in the
   portal fails the next rollout. The image is not rolled back, because the
   image is not what is wrong.
4. From a private browser session on a network that ingress permits, check
   the home page and a direct static asset URL. Both should require Entra
   sign-in. Sign in to Azure, check that Drupal still shows **Log in**, then
   sign in to Drupal. Log out and check that the Drupal session ends while
   the gate session still allows public pages to load.

### When the gate's secret expires

The secret lasts a year. When it lapses, nobody can sign in. The **Credential
Expiry Reminder** workflow runs daily and reads `SITE_AUTH_SECRET_EXPIRES`:

- 30 days ahead, it opens an issue labelled `credential-expiry` and refreshes
  it each day.
- When the secret has expired, it turns the run red.
- After a rotation records a later date, it closes the issue.

It needs no Azure access. Reading the date from Entra would need a Microsoft
Graph permission with admin consent, so the date is recorded when the secret
is made. While the gate is on and the variable is unset, every rollout warns.

To rotate:

1. Run `./scripts/setup-site-gate.sh --rotate --set-repo-vars`.
2. Restart the app so that it reads the new secret.
3. Check that sign-in works.
4. Delete the old credential from the registration
   (`az ad app credential list --id <client ID>`, then
   `az ad app credential delete`).

App Service CI rollouts on gated sites use Azure CLI 2.90.0 or later to verify
Drupal inside the container. Azure uses its internal probes on both hosting
platforms. [App Service authentication](https://learn.microsoft.com/en-us/azure/app-service/app-service-authentication-overview)
· [Container Apps authentication](https://learn.microsoft.com/en-us/azure/container-apps/authentication)

---

## Patching contrib

`azure_oauth_sso` frequently needs a small change — the login route, or the
controller's account-matching logic. Both live deployments do it by copying
replacement files over the installed module in the Dockerfile:

```dockerfile
COPY docker/patches/azure_oauth_sso.routing.yml \
     web/modules/contrib/azure_oauth_sso/azure_oauth_sso.routing.yml
```

That works and has one sharp edge worth naming: a `COPY` over a contrib path is
**silent** when the module restructures. The file lands somewhere harmless, the
patch has no effect, and SSO breaks at runtime rather than at build time. If you
patch this way, assert the target afterwards — `verify-production-image.sh` is
the place, and it already has the pattern for asserting a file is present and
non-empty in the built image.

The alternative is `cweagans/composer-patches` with a real diff, which fails
loudly at install time when a patch stops applying. Prefer it for anything you
expect to carry across more than one module release.

---

## Setting up the app registration

The redirect URIs must include every hostname the site answers on — the Container
Apps default domain *and* every custom domain — because Drupal builds the
redirect URI from the request's `Host` header:

```bash
APP_ID=$(az ad app create --display-name "drupal-sso" --query appId -o tsv)
az ad sp create --id "$APP_ID"

FQDN=$(az containerapp show -n app-drupal -g rg-drupal-prod \
  --query properties.configuration.ingress.fqdn -o tsv)

az ad app update --id "$APP_ID" --enable-id-token-issuance true \
  --web-redirect-uris \
    "https://$FQDN/oauth/login" \
    "https://drupal.example.edu/oauth/login"
```

A client secret is needed for the OAuth exchange. Put it in the same Key Vault as
the other secrets and reference it from the container app, rather than storing it
as a literal — the reasoning and the rotation procedure are in
[secrets.md](secrets.md), and they apply unchanged.

A custom-domain cutover therefore needs the redirect URI added **before** the
domain goes live, or the first login on the new hostname fails with a redirect-URI
mismatch. Add the domain to `DRUPAL_TRUSTED_HOSTS` at the same time.

### Renewing Drupal's client secret

Drupal's client secret expires; Entra issues them for at most two years. Use a
registration of its own for Drupal, not the identity CI deploys with, so the
secret grants nothing but sign-in. Renew without an outage:

1. Add a new secret **alongside** the current one, so sign-in keeps working,
   straight into a file the shell does not echo:
   `az ad app credential reset --id <client ID> --append --display-name "drupal-sso $(date -u +%F)" --years 1 --query password -o tsv | tr -d '\n' > new-secret`
2. Store it in the deployment Key Vault, under the name the app setting
   references: `az keyvault secret set --vault-name <vault> --name <secret name> --file new-secret`.
   Then delete the file.
3. Restart the app so that it reads the new version. An unversioned Key Vault
   reference is cached until restart. Sign in at `/oauth/login`.
4. Record the new end date for the daily reminder:
   `gh variable set DRUPAL_SSO_SECRET_EXPIRES --body "$(az ad app credential list --id <client ID> --query 'max_by(@, &endDateTime).endDateTime' -o tsv)"`
5. Delete the old credential (`az ad app credential list --id <client ID>`,
   then `az ad app credential delete --id <client ID> --key-id <old key ID>`).
   Until then, putting the old value back undoes the renewal.

With `DRUPAL_SSO_SECRET_EXPIRES` set, the **Credential Expiry Reminder**
workflow handles it the same way as the gate secret. It opens an issue 30
days ahead, closes it after renewal, and turns red once the secret expires.

### Verify the initial admin sign-in

After [installing Drupal](getting-started.md#5-install-drupal-and-bootstrap-the-entra-admin),
enable `drupal_azure_sso` and `genpass` from the Drupal container shell. The
first module enables `azure_oauth_sso` as a dependency. Set the
field mapping so Drupal's username and email track the two Graph fields.

```bash
vendor/bin/drush pm:enable drupal_azure_sso genpass --yes
vendor/bin/drush config:set azure_oauth_sso.fields_mapping custom_attr_table.name userPrincipalName --yes
vendor/bin/drush config:set azure_oauth_sso.fields_mapping custom_attr_table.mail mail --yes
```

Configure the module's `azure_oauth_sso.settings` with your tenant ID
(`ad_tenant`) and client ID (`client_id`). In the site's settings overlay,
override `$config['azure_oauth_sso.settings']['client_secret']` with the value
of its Key Vault-backed environment variable.

During setup, set **Assignment required?** to **Yes** on the Entra enterprise
application, assign the intended administrator, and arrange admin consent for
the required Graph permissions. [Restrict an Entra application to assigned users](https://learn.microsoft.com/en-us/entra/identity-platform/howto-restrict-your-app-to-a-set-of-users)

In a private browser session, open `/oauth/login` and sign in with the specified
Entra UPN. Open `/user` and confirm it resolves to `/user/1`, then verify access
to `/admin/people`. If a different Drupal account opens, check the Graph `mail`
value and the Drupal field mapping before granting any roles.

The UPN is the Drupal username. The bundled module matches accounts by `mail`.
For durable privileged account binding, use an SSO integration that maps the
validated Entra tenant ID and user object ID to the Drupal account. [Microsoft
guidance on validating identity claims](https://learn.microsoft.com/en-us/entra/identity-platform/claims-validation)

---

## See also

- **[Secrets](secrets.md)** — where the client secret goes, and how to rotate it.
- **[Configuration](configuration.md)** — `DRUPAL_TRUSTED_HOSTS` and the session
  variables that an OAuth flow depends on.
- **[Getting started](getting-started.md)** — if you have not deployed yet.
