<?php
$CONFIG = array (
  'trusted_proxies'   => ['172.22.0.2'],
  'maintenance_window_start' => 2,
  'memcache.local' => '\OC\Memcache\APCu',
  'apps_paths' => array (
      0 => array (
              'path'     => '/var/www/nextcloud/apps',
              'url'      => '/apps',
              'writable' => false,
      ),
      1 => array (
              'path'     => '/var/www/nextcloud/apps_installed',
              'url'      => '/apps_installed',
              'writable' => true,
      ),
  ),
);
