ARG NEXTCLOUD_VERSION=35.0.2
ARG GPG_NEXTCLOUD="2880 6A87 8AE4 23A2 8372  792E D758 99B9 A724 937A"

FROM alpine:3.24.0 AS base

#############
# Builder   #
#############
FROM base AS builder
ARG NEXTCLOUD_VERSION
# This key needs to be hardcoded to make sure the files were not tampered with
# See https://nextcloud.com/security/ for the current key
ARG GPG_NEXTCLOUD

COPY nextcloud_signing_key.asc /

# Download, verify (checksum + signature + pinned key fingerprint) and unpack Nextcloud
RUN set -eu; \
  apk --no-cache add gnupg tar; \
  base_url="https://download.nextcloud.com/server/releases"; \
  tarball="nextcloud-${NEXTCLOUD_VERSION}.tar.bz2"; \
  metadata="nextcloud-${NEXTCLOUD_VERSION}.metadata"; \
  fingerprint="$(echo "${GPG_NEXTCLOUD}" | tr -d ' ')"; \
  cd "$(mktemp -d)"; \
  for file in "${tarball}" "${tarball}.sha512" "${tarball}.asc" "${metadata}"; do \
    wget -q "${base_url}/${file}"; \
  done; \
  sha512sum -c "${tarball}.sha512"; \
  gpg --batch --import /nextcloud_signing_key.asc; \
  gpg --batch --list-keys "${fingerprint}"; \
  gpg --batch --verify "${tarball}.asc" "${tarball}"; \
  mkdir /app; \
  tar xjf "${tarball}" --strip-components=1 -C /app

#############
# Runtime   #
#############
FROM base AS prod

# Upgrade the base packages and install everything in a single layer:
# PHP, nginx and supervisor
RUN apk --no-cache upgrade && \
  apk --no-cache add \
  ca-certificates \
  gnu-libiconv \
  imagemagick-svg \
  nginx \
  openssl \
  php85 \
  php85-apcu \
  php85-bcmath \
  php85-bz2 \
  php85-ctype \
  php85-curl \
  php85-dom \
  php85-exif \
  php85-fileinfo \
  php85-fpm \
  php85-gd \
  php85-gmp \
  php85-iconv \
  php85-intl \
  php85-json \
  php85-ldap \
  php85-mbstring \
  php85-openssl \
  php85-pcntl \
  php85-pdo_mysql \
  php85-pecl-imagick \
  php85-posix \
  php85-session \
  php85-simplexml \
  php85-sodium \
  php85-sysvsem \
  php85-xml \
  php85-xmlreader \
  php85-xmlwriter \
  php85-zip \
  supervisor

# Ids of the nginx user/group inside the container. Set them to the owner of your
# volumes/bind mounts, e.g. --build-arg UID=1000 --build-arg GID=1000
# (declared here, right before they are used, so changing them keeps the layers above cached)
ARG UID=102
ARG GID=102

# Nginx: replace the package's nginx user/group (uid/gid 101) with ${UID}/${GID},
# fix ownership of files still owned by the old ids, and set up the runtime dirs/logs.
# -xdev keeps find away from /proc and /sys, -h avoids following symlinks.
RUN set -eu; \
  deluser nginx; \
  addgroup -g ${GID} nginx; \
  adduser -D -S -u ${UID} -h /var/lib/nginx -s /sbin/nologin -g nginx -G nginx nginx; \
  find / -xdev -user 101 -exec chown -h nginx {} +; \
  find / -xdev -group 101 -exec chgrp -h nginx {} +; \
  mkdir -p /run/nginx; \
  ln -sf /dev/stdout /var/log/nginx/access.log; \
  ln -sf /dev/stderr /var/log/nginx/error.log; \
  chown -R nginx:nginx /var/log/nginx; \
  rm -f /etc/nginx/http.d/default.conf

# Copy the default php and php-fpm config to the image
# Do not touch these files unless you know what you doing
COPY php-fpm_conf/php-fpm.conf /etc/php85/
COPY php-fpm_conf/www.conf /etc/php85/php-fpm.d/
COPY php_conf/ /etc/php85/conf.d/

# Copy the default nginx config to the image
# Do not touch these files unless you know what you doing
COPY nginx_conf/nginx.conf /etc/nginx/
COPY nginx_conf/nextcloud.conf /etc/nginx/http.d/

# Supervisor config
# Do not touch this file unless you know what you doing
COPY supervisor_conf/default.ini /etc/supervisor.d/

# Nextcloud (this changes most often, so it comes late to keep the cache useful)
COPY --from=builder /app /var/www/nextcloud/

# Copy the default Nextcloud config to the image
# Do not touch these files unless you know what you doing
COPY nextcloud_conf/config.php nextcloud_conf/autoconfig.php /var/www/nextcloud/config/

# Install the Nextcloud cron job, which replaces AJAX cron
COPY --chmod=755 nextcloud_conf/cron /etc/periodic/15min/nextcloud

# Run the Nextcloud cron job once. This needs to happen after nginx was installed,
# because it uses the nginx user account.
RUN /etc/periodic/15min/nextcloud

COPY --chmod=755 upgrade_nextcloud.sh entrypoint.sh /

EXPOSE 80

# Healthy when nginx and PHP-FPM answer Nextcloud's status.php (it returns 200 even in
# maintenance mode or before the installation wizard was completed) and crond is running.
# 127.0.0.1 is always accepted by Nextcloud's trusted domain check, localhost may resolve to ::1.
# start-period covers the entrypoint's chown, retries are generous so a busy server
# (all PHP-FPM children in use) is not marked unhealthy right away.
HEALTHCHECK --interval=30s --timeout=10s --start-period=2m --retries=5 \
  CMD wget -q -O /dev/null http://127.0.0.1/status.php && pidof crond > /dev/null || exit 1

ARG NEXTCLOUD_VERSION
LABEL maintainer="Patrick Baus <patrick.baus@physik.tu-darmstadt.de>" \
  description="A server software for creating file hosting services" \
  nextcloud="Nextcloud v${NEXTCLOUD_VERSION}"

ENTRYPOINT ["/entrypoint.sh"]

CMD ["supervisord", "-c", "/etc/supervisor.d/default.ini"]
