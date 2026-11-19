<?php

declare(strict_types=1);

namespace Drupal\drupal_azure_sso\Routing;

use Drupal\Core\Routing\LocalRedirectResponse;
use Drupal\Core\Url;

/**
 * Sends Drupal sign-in requests to the configured Entra OAuth provider.
 */
final class LoginRedirect {

  public function login(): LocalRedirectResponse {
    $url = Url::fromRoute('azure_oauth_sso.oauthLogin')->toString();
    return new LocalRedirectResponse($url);
  }

}
