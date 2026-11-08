[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docker](https://img.shields.io/badge/docker-%230db7ed.svg?style=flat&logo=docker&logoColor=white)](../../pkgs/container/nextcloud-docker)
# Nextcloud (Alpine, nginx, PHP-FPM) in a single container

A small Nextcloud image built on [Alpine Linux](https://alpinelinux.org/). One container runs [nginx](https://nginx.org/), [PHP-FPM](https://php-fpm.org/) and cron under `supervisord`. It is meant to sit behind a reverse proxy (the examples use Traefik) and to talk to a separate MariaDB container.

| Component | Version / source |
| --- | --- |
| Base image | `alpine` |
| Nextcloud | `35.0.2` (build argument `NEXTCLOUD_VERSION`) |
| PHP | `phpXX` packages with APCu, OPcache, Imagick, LDAP and the extensions Nextcloud needs |
| Web server | nginx, listening on port 80 (plain HTTP, no TLS) |
| Process manager | supervisord (`php-fpm`, `nginx`, `crond`) |

## Repository layout

```
Dockerfile                    multi-stage build (downloader/verifier + runtime image)
nextcloud_signing_key.asc     Nextcloud's release signing key
entrypoint.sh                 fixes ownership of the mounted folders, then starts supervisord
upgrade_nextcloud.sh          runs the occ upgrade steps (see "Upgrading")
supervisor_conf/default.ini   supervisord programs: php-fpm, nginx, cron
nginx_conf/nginx.conf         main nginx config
nginx_conf/nextcloud.conf     Nextcloud server block
php-fpm_conf/php-fpm.conf     global PHP-FPM config
php-fpm_conf/www.conf         PHP-FPM pool (user, socket, limits)
php_conf/                     PHP ini files (apcu.ini, opcache.ini)
nextcloud_conf/config.php     default Nextcloud config (apps paths, APCu, proxies)
nextcloud_conf/autoconfig.php pre-fills the installation wizard (database, data folder)
nextcloud_conf/cron           job run every 15 minutes by crond
```

## Building

```sh
docker build -t nextcloud .
# or a different Nextcloud release:
docker build --build-arg NEXTCLOUD_VERSION=33.0.4 -t nextcloud .
# or with the uid/gid the container should use (see "Users and permissions"):
docker build --build-arg UID=1000 --build-arg GID=1000 -t nextcloud .
```

The build downloads the release tarball from `download.nextcloud.com` and aborts unless all of these pass:

1. The SHA-512 checksum matches.
2. The signature (`.asc`) verifies against `nextcloud_signing_key.asc`.
3. The imported key has the fingerprint pinned in the `GPG_NEXTCLOUD` build argument.

If Nextcloud rotates its signing key, replace `nextcloud_signing_key.asc` and update `GPG_NEXTCLOUD` (current key: <https://nextcloud.com/security/>).

The build uses `COPY --chmod`, so it needs BuildKit (the default in current Docker).

## Running

### Volumes

| Mount point | Purpose |
| --- | --- |
| `/var/www/nextcloud/config` | `config.php` and the instance configuration |
| `/var/www/nextcloud/data` | user files |
| `/var/www/nextcloud/apps_installed` | apps installed from the app store (writable app path) |
| `/external` (optional) | host folder for the "External storage" app |

Everything else in `/var/www/nextcloud` is part of the image and is replaced on each rebuild.

Named volumes are filled from the image only when they are created empty. This means `config.php` and `autoconfig.php` from this repository are used for a **new** volume. After that, edit the copies inside the `config` volume.

### Example `docker-compose.yml`

```yaml
services:
  nextcloud:
    build:
      context: .                  # directory containing the Dockerfile
      args:
        UID: 1000                 # optional: uid/gid of the nginx user, see "Users and permissions"
        GID: 1000                 # optional
    container_name: nextcloud
    restart: always
    networks:
      - backend
      - web
    volumes:
      - nextcloud_apps:/var/www/nextcloud/apps_installed
      - nextcloud_config:/var/www/nextcloud/config
      - nextcloud_data:/var/www/nextcloud/data
      - /path/on/host:/external   # optional
    depends_on:
      - db_nextcloud
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=nc-network"
      - "traefik.http.routers.nextcloud.entrypoints=websecure"
      - "traefik.http.routers.nextcloud.rule=Host(`cloud.example.com`)"
      - "traefik.http.routers.nextcloud.tls=true"
      - "traefik.http.services.nextcloud.loadbalancer.server.port=80"
      # security headers, redirects etc.: see "Reverse proxy"

  db_nextcloud:
    image: mariadb
    container_name: nextcloud_mysql
    restart: always
    # needed so Nextcloud can use tables with ROW_FORMAT=compressed on MariaDB 10.6+
    command: --innodb-read-only-compressed=OFF
    volumes:
      - data_mysql_nextcloud:/var/lib/mysql
    networks:
      - backend
    env_file:
      - ./.docker-mysql-nextcloud.env   # MYSQL_ROOT_PASSWORD, MYSQL_DATABASE, MYSQL_USER, MYSQL_PASSWORD

volumes:
  nextcloud_apps:
  nextcloud_config:
  nextcloud_data:
  data_mysql_nextcloud:

networks:
  backend:
  web:
    name: nc-network
```

### First start

`autoconfig.php` pre-fills the installation wizard with the database host `db_nextcloud`, database name `nextcloud`, database user `nextcloud` and the data folder. Open the site, create the admin account and enter the database password. The database name, user and password must match the values in your MariaDB env file.

### Reverse proxy

The container serves plain HTTP on port 80, and the nginx config deliberately does **not** send most security headers. Your proxy is expected to provide:

- TLS and HSTS
- `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`, `X-Robots-Tag`, `X-Permitted-Cross-Domain-Policies`
- `X-Forwarded-Proto` (nginx uses it to build redirect URLs)

`nextcloud_conf/config.php` sets `trusted_proxies` to a fixed address (`172.22.0.2`). **Change it to your proxy's IP or subnet** on the `config` volume, otherwise client IPs and protocol detection will be wrong.

## Users and permissions

nginx and PHP-FPM run as the user and group `nginx`. Their ids are set at **build time** with the build arguments `UID` and `GID` (both default to `102`). Choose the ids that own your volumes and bind mounts, for example `1000`, and pass them as shown in the examples above. Setting `UID`/`GID` in the container's runtime `environment` has no effect, so changing them means rebuilding the image.

On every start `entrypoint.sh` fixes ownership of the mounted folders:

- `config` and `apps_installed`: every file not owned by `nginx` is chowned.
- `data`: a recursive chown happens only if the top-level folder is not owned by `nginx` (first start, or after an id change). Files added later by another user inside an already-correct `data` folder are not fixed.

After you change the ids on an existing installation, the first start therefore runs one recursive chown over `data`, which can take a while on a large volume.

## Configuration

| Setting | Value | File |
| --- | --- | --- |
| PHP `memory_limit` | 2G | `php-fpm_conf/www.conf` |
| `upload_max_filesize` / `post_max_size` | 10G | `php-fpm_conf/www.conf` |
| nginx `client_max_body_size` | 10G | `nginx_conf/nextcloud.conf` |
| PHP-FPM process manager | `ondemand`, max 5 children | `php-fpm_conf/www.conf` |
| nginx workers | 1 | `nginx_conf/nginx.conf` |
| APCu | enabled, 1G shared memory, enabled for CLI (cron needs it) | `php_conf/apcu.ini` |
| OPcache | enabled, 128 MB | `php_conf/opcache.ini` |
| Local memcache | APCu | `nextcloud_conf/config.php` |
| Maintenance window | starts at 02:00 | `nextcloud_conf/config.php` |

If you raise the upload limits, change all three upload settings together (PHP `upload_max_filesize`, PHP `post_max_size` and nginx `client_max_body_size`).

## Background jobs

Nextcloud's background jobs run through cron, not AJAX. `crond` runs `nextcloud_conf/cron` every 15 minutes, which executes `cron.php` as the `nginx` user. The job's output goes to the container log. Check **Administration settings > Basic settings** in Nextcloud to see when the last run happened.

## Health check

The image has a built-in health check that runs every 30 seconds. The container is healthy when:

- `http://127.0.0.1/status.php` answers with HTTP 200, which proves that nginx, PHP-FPM and Nextcloud start up, and
- `crond` is running.

`status.php` also answers with 200 in maintenance mode and before the installation wizard has been completed, so neither state is reported as unhealthy. A container becomes unhealthy after 5 consecutive failures, and there is a 2 minute grace period after start. Check the state with `docker ps` or `docker inspect --format '{{.State.Health.Status}}' nextcloud`.

Docker itself does not restart unhealthy containers. Some reverse proxies do stop routing to them, so see the notes below if yours does.

- If all PHP-FPM children are busy (`pm.max_children` is 5), for example during large uploads, the check can time out. Raise `pm.max_children` in `php-fpm_conf/www.conf` or the `--retries` value of the `HEALTHCHECK` line if the container flaps.
- The check requests appear in the nginx access log every 30 seconds.

## Logs

All three processes log to the container's stdout/stderr, so `docker logs nextcloud` shows them.

- nginx access log: stdout, in the `custom` format defined in `nginx.conf`
- nginx error log: only level `crit` and above
- PHP-FPM errors, `crond` messages and the output of the cron job: stderr
- Nextcloud's own log: `data/nextcloud.log`, or whatever you configure in `config.php`

## Running occ

```sh
docker exec -u nginx nextcloud php84 /var/www/nextcloud/occ status
```

## Upgrading

1. **Back up** the three Nextcloud volumes and dump the database. Nextcloud cannot be downgraded.
2. **Pick the new version.** Nextcloud only upgrades one major version at a time (32 to 33, not 31 to 33). Change the default of `NEXTCLOUD_VERSION` in the Dockerfile, or pass it as a build argument.
3. **Rebuild and restart:**
   ```sh
   docker compose build --pull nextcloud
   docker compose up -d nextcloud
   ```
4. **Run the upgrade steps:**
   ```sh
   docker compose exec nextcloud /upgrade_nextcloud.sh
   ```
   This runs `occ upgrade`, `occ db:add-missing-indices` and `occ db:convert-filecache-bigint` as the `nginx` user.

Apps in `apps_installed` that are not yet compatible with the new version are disabled by the upgrade. Check them afterwards in the app store.

## Versioning
I use [SemVer](http://semver.org/) for versioning. For the versions available, see the [tags](../../tags) available for this repository.

## Authors
* **Patrick Baus** - *Initial work* - [PatrickBaus](https://github.com/PatrickBaus)

## License
This project is licensed under the MIT license - see the [LICENSE](LICENSE) file for details.
