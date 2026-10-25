# syntax=docker/dockerfile:1
ARG PHP_VERSION=8.3
FROM dunglas/frankenphp:1-php${PHP_VERSION}-alpine AS build

RUN install-php-extensions gd exif intl zip opcache \
  && apk add --no-cache git unzip \
  && cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
  && setcap -r /usr/local/bin/frankenphp \
  && addgroup -g 1000 app \
  && adduser -D -u 1000 -G app app \
  && mkdir -p /app/public \
  && chown app:app /app/public

COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer
COPY Caddyfile /etc/frankenphp/Caddyfile
COPY php.ini /usr/local/etc/php/conf.d/zz-kirby.ini

# Build tools and PHP headers are unnecessary in the runtime. Copy the finished
# filesystem into one layer so removing the binary's file capabilities does not
# leave a second copy of FrankenPHP in the final image's lower layers.
RUN rm -rf /usr/src/php* /usr/local/include/php /usr/local/lib/php/build \
  && rm -f /usr/local/bin/install-php-extensions /usr/local/bin/phpize /usr/local/bin/php-config \
  && frankenphp fmt --overwrite /etc/frankenphp/Caddyfile

FROM scratch
COPY --from=build / /

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  PHP_INI_DIR=/usr/local/etc/php \
  XDG_CONFIG_HOME=/tmp/caddy-config \
  XDG_DATA_HOME=/tmp/caddy-data \
  GODEBUG=cgocheck=0 \
  HOME=/tmp \
  COMPOSER_HOME=/tmp/composer \
  PHP_THREADS=4

WORKDIR /app/public
USER app

EXPOSE 8080

# Checks that the mounted application can respond, not just that the port is open.
HEALTHCHECK --interval=30s --timeout=6s --start-period=15s --retries=3 \
  CMD php -r '$context = stream_context_create(["http" => ["timeout" => 5]]); exit(@file_get_contents("http://127.0.0.1:8080/", false, $context) === false ? 1 : 0);'

CMD ["--config", "/etc/frankenphp/Caddyfile", "--adapter", "caddyfile"]
ENTRYPOINT ["docker-php-entrypoint"]
