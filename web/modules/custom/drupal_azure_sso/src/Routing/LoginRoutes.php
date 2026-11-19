<?php

declare(strict_types=1);

namespace Drupal\drupal_azure_sso\Routing;

use Drupal\Core\Routing\RouteSubscriberBase;
use Symfony\Component\Routing\RouteCollection;

/**
 * Keeps the Drupal sign-in link and removes local account entry points.
 */
final class LoginRoutes extends RouteSubscriberBase {

  protected function alterRoutes(RouteCollection $collection): void {
    $login = $collection->get('user.login');
    if ($login !== NULL) {
      $defaults = $login->getDefaults();
      unset($defaults['_form']);
      $defaults['_controller'] = LoginRedirect::class . '::login';
      $login->setDefaults($defaults);
      $login->setMethods(['GET', 'HEAD']);
      $login->setOption('no_cache', TRUE);
    }

    foreach ([
      'user.login.http',
      'user.pass',
      'user.pass.http',
      'user.register',
      'rest.user_registration.POST',
      'user.reset',
      'user.reset.form',
      'user.reset.login',
    ] as $name) {
      $collection->get($name)?->setRequirement('_access', 'FALSE');
    }
  }

}
