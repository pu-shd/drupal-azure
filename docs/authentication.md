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

1. Create a separate, single-tenant Entra app registration for the gate in the
   Azure subscription's tenant. Enable ID token issuance. Register
   `https://<hostname>/.auth/login/aad/callback` as a **Web** redirect URI for
   each hostname people use. Leave user assignment optional for access by any
   user in that tenant. Keep Drupal's app registration and `/oauth/login` callback.
2. Create a client secret for the gate registration. In the deployment Key
   Vault, save it as `site-auth-client-secret`. On a new deployment that must
   stay private, provision the infrastructure with an ingress allowlist first.
   Enable the gate before bringing the site online or widening ingress access.
3. Set `SITE_AUTH_CLIENT_ID` to the gate registration's application client ID.
   Preview the change with `./scripts/azure-up.sh --dry-run`, then apply it with
   `./scripts/azure-up.sh`. Later runs of the script reuse that registration if
   the variable is unset. To disable the gate, run
   `SITE_AUTH_CLIENT_ID='' ./scripts/azure-up.sh`. Image-only rollouts preserve
   the Azure authentication settings.
4. From a private browser session on a network permitted by ingress, check the
   home page and a direct static asset URL. Both should require Entra sign-in.
   Sign in to Azure, check that Drupal still shows **Log in**, then sign in to
   Drupal. Log out and check that the Drupal session ends while the gate session
   still allows public pages to load.

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
