# kirby-php

A reusable PHP 8.3 container for Kirby 5 behind an existing Caddy reverse proxy.
The image contains the runtime, PHP extensions and Composer. **All site files stay
in a bind mount on the host**, including Kirby itself, plugins, content, accounts,
uploads, `vendor/` and `composer.lock`.

```text
Internet → existing Caddy (HTTPS) → 127.0.0.1:8080 → FrankenPHP → mounted Kirby site
```

FrankenPHP combines an HTTP server and PHP in one process. It runs in classic PHP
mode; Kirby does not need a worker integration. The Alpine base keeps the image
smaller than a typical Apache/PHP installation. No database, Node.js, PHP-FPM
service or host PHP installation is needed.

## Deploy on your server

```sh
git clone https://github.com/hartlco/kirby-php.git
cd kirby-php
cp .env.example .env
```

Edit `.env`: set `KIRBY_ROOT` to the absolute path of the existing Kirby project
and `PUID`/`PGID` to its owner's numeric user and group IDs (`id -u` and `id -g`
when logged in as that user). Do not copy the site into this repository.

```sh
docker compose pull
docker compose up -d
docker compose logs -f php
```

The existing site must contain `index.php`, `kirby/`, `site/`, `content/` and its
dependencies. If dependencies are missing, install them first:

```sh
docker compose run --rm php composer install --no-dev --prefer-dist --optimize-autoloader
```

The service listens on `http://127.0.0.1:8080` on the Docker host. Set `KIRBY_PORT`
in `.env` if that port is already used. A missing source directory fails instead
of silently creating an empty one. The container runs as the configured user and
does not change ownership of the mounted files.

Kirby needs write access to `content/`, `media/`, `site/accounts/`, `site/cache/`,
`site/sessions/` and any plugin data/log directories. Composer also needs write
access to `composer.lock`, `vendor/`, `kirby/` and Composer-managed plugins. Match
the existing owner rather than granting world-write permissions.

## Caddy on the host

In your existing Caddyfile:

```caddyfile
hartl.co {
  reverse_proxy 127.0.0.1:8080
}
```

Your existing Caddy handles certificates, HTTPS and public traffic. The runtime
only speaks HTTP and publishes its port on loopback.

Set a fixed public base URL in the **mounted site's** `site/config/env.php`
(merge with an existing file if present):

```php
<?php

return [
  'url' => 'https://hartl.co',
];
```

This is Kirby's supported reverse proxy configuration. It keeps links, feeds,
Panel endpoints and secure session cookies on the public HTTPS URL. For a local
test use `http://localhost:8080` instead. Do not enable Kirby's wildcard URL
option just to trust arbitrary forwarded headers.

If Caddy runs in Docker, attach both containers to the same external Docker
network and use `reverse_proxy php:8080` (or a unique network alias). Loopback
inside a Caddy container refers to Caddy itself. In this setup the `ports` entry
can be removed; both services need to join that shared network.

## Composer and PHP

```sh
# Update Kirby and plugins within the constraints in the site's composer.json.
docker compose exec php composer update --no-dev --prefer-dist --optimize-autoloader

# Check the actual runtime against installed dependency requirements.
docker compose exec php composer check-platform-reqs --no-dev

# Other PHP commands use the same PHP version and extensions as web requests.
docker compose exec php php -v
docker compose exec php php -m
```

Composer changes the mounted site and lockfile, so updates survive container
replacement. The image never installs or updates site dependencies at startup.
Back up the site and lockfile before updating; an in-place update can interrupt
requests while Composer replaces files, so use a maintenance window. Restart
after updates to clear runtime caches:

```sh
docker compose restart php
```

PHP OPcache also checks mounted files on every request, so regular PHP edits are
visible immediately. Static asset builds remain a separate deployment step;
serve the generated `assets/` files from the mounted site.

## Runtime updates and local builds

The default Compose file pulls the public, versioned image
`ghcr.io/hartlco/kirby-php:0.1.0`. No GitHub or registry login is needed. It works
as a standalone deployment file: only `compose.yaml`, `.env` and the existing
site directory are needed on the server.

For rolling runtime patch updates, set
`KIRBY_IMAGE=ghcr.io/hartlco/kirby-php:8.3` in `.env`, then run:

```sh
docker compose pull
docker compose up -d
```

GitHub Actions tests the image, then publishes `linux/amd64` and `linux/arm64`
images to `ghcr.io/hartlco/kirby-php` on pushes to `main`, release tags, manual
runs and weekly rebuilds. Tags include `8.3`, `latest`, `sha-…` and version tags
such as `0.1.0`. `8.3` stays on PHP 8.3 while picking up patch updates. Weekly
builds do not update running containers; pull/recreate them explicitly. An image
digest can be used in `KIRBY_IMAGE` for a fixed deployment.

To build and run the image locally from this repository instead:

```sh
docker compose -f compose.yaml -f compose.build.yaml build --pull
docker compose -f compose.yaml -f compose.build.yaml up -d
```

Rebuild/recreate the image independently of Composer or Kirby updates. The image
contains no site files and the build context only includes the runtime config.

## Included configuration

- PHP 8.3 with all required Kirby extensions, GD (JPEG/WebP support), EXIF,
  Intl, ZIP, Sodium and OPcache; Composer 2, Git and unzip.
- A non-root user, configurable UID/GID, no Linux capabilities, and a 4-thread
  PHP default (`PHP_THREADS` in `.env`).
- Kirby front-controller routing, static assets and compression. Private Kirby
  directories, `vendor/`, `node_modules/`, hidden files at every depth and common
  project metadata return 404. Only the root `index.php` can execute through HTTP.
- No `.htaccess` support. Site-specific Apache redirects must be translated into
  Kirby routes or rules on the external Caddy. Hidden paths, including
  `.well-known`, are blocked here; serve any required `.well-known` resources
  through the external Caddy.
- PHP errors go to container logs. Uploads are limited to 64 MB per file and
  72 MB per POST; memory is limited to 256 MB per request. The PHP timezone is
  Europe/Berlin. Adjust `php.ini` and rebuild to change these defaults.
- A health check requests the mounted site's homepage every 30 seconds. A
  missing or broken application becomes unhealthy. Docker restart policies
  restart exited processes; they do not restart a merely unhealthy container.

Back up the mounted site as before. Replacing this container does not replace
site files. Removing or losing the host directory still loses the site's data.

## Verify changes

```sh
docker build -t kirby-php:8.3 .
sh tests/smoke.sh kirby-php:8.3
```

The smoke test mounts a disposable fixture and checks routing, static files,
protected files, authorization/proxy headers, mounted PHP edits, image support,
extensions and Composer. It never needs a real site's content or accounts.

References: [Kirby requirements](https://getkirby.com/docs/reference/system/requirements),
[Kirby base URL configuration](https://getkirby.com/docs/reference/system/options/url),
[FrankenPHP Docker images](https://frankenphp.dev/docs/docker/).
