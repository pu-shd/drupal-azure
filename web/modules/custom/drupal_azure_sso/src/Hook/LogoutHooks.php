<?php

declare(strict_types=1);

namespace Drupal\drupal_azure_sso\Hook;

use Drupal\Core\Extension\ProceduralCall;
use Drupal\Core\Hook\Attribute\Hook;
use Drupal\Core\Hook\Attribute\RemoveHook;
use Drupal\Core\Session\AccountInterface;
use Drupal\user\Entity\User;

/**
 * Keeps Drupal logout local while clearing stored OAuth tokens.
 */
#[RemoveHook('user_logout', class: ProceduralCall::class, method: 'azure_oauth_sso_user_logout')]
final class LogoutHooks {

  #[Hook('user_logout')]
  public function clearTokens(AccountInterface $account): void {
    $user = User::load($account->id());
    if ($user === NULL || ($user->get('field_access_token')->isEmpty() && $user->get('field_refresh_token')->isEmpty())) {
      return;
    }
    $user->set('field_access_token', NULL);
    $user->set('field_refresh_token', NULL);
    $user->save();
  }

}
