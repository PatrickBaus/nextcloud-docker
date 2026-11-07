#!/bin/sh

# Bash "strict mode"
# Exit if any return value is non zero (-e), any variables are not reclared (-u)
# and do not mask errors in pipelines (using |) (-o pipefail)
set -euo pipefail

# Set the permissions of the container
echo -n 'Settings permissions for the Nextcloud config/data folders...'

find /var/www/nextcloud/config/ ! -user nginx -exec chown nginx {} +
find /var/www/nextcloud/apps_installed/ ! -user nginx -exec chown nginx {} +

# data can be huge, so a recursive chown on every start is slow. Only recurse if the
# top-level folder is not owned by nginx, e.g. on first start or after a UID change.
if [ "$(stat -c %U /var/www/nextcloud/data/)" != "nginx" ]; then
  chown -R nginx /var/www/nextcloud/data/
fi
echo 'Done.'

exec "$@"
