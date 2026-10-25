#!/bin/sh
set -eu

image=${1:-kirby-php:8.3}
fixture=$(mktemp -d)
container=""

cleanup() {
  status=$?
  trap - EXIT
  if [ -n "$container" ]; then
    if [ "$status" -ne 0 ]; then
      docker logs "$container" >&2 || true
    fi
    docker rm -f "$container" >/dev/null 2>&1 || true
  fi
  rm -rf "$fixture"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

mkdir -p "$fixture/assets/nested/.private" "$fixture/media" \
  "$fixture/content" "$fixture/site/accounts" "$fixture/kirby" \
  "$fixture/vendor" "$fixture/.git" "$fixture/node_modules"

cat > "$fixture/index.php" <<'PHP'
<?php
header('Content-Type: application/json');
echo json_encode([
  'uri' => $_SERVER['REQUEST_URI'],
  'authorization' => $_SERVER['HTTP_AUTHORIZATION'] ?? null,
  'forwardedProto' => $_SERVER['HTTP_X_FORWARDED_PROTO'] ?? null,
  'writable' => is_writable(__DIR__),
]);
PHP

for filename in content/site.txt site/accounts/account.txt kirby/bootstrap.php \
  vendor/autoload.php .git/config .env composer.json composer.lock \
  node_modules/package.json assets/nested/.private/secret.txt; do
  printf 'PRIVATE\n' > "$fixture/$filename"
done
printf 'STATIC\n' > "$fixture/assets/style.css"
printf '<?php echo "EXECUTED";\n' > "$fixture/media/upload.php"
chmod -R a+rX "$fixture"
chmod a+w "$fixture"

container=$(docker run -d --user "$(id -u):$(id -g)" \
  --cap-drop ALL --security-opt no-new-privileges:true \
  -p 127.0.0.1::8080 \
  --mount "type=bind,source=$fixture,target=/app/public" "$image")
port=$(docker port "$container" 8080/tcp | sed 's/.*://')
base="http://127.0.0.1:$port"

attempt=0
until curl -fsS "$base/" > /dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 30 ]; then
    docker logs "$container"
    exit 1
  fi
  sleep 1
done

assert_status() {
  expected=$1
  request_path=$2
  actual=$(curl --path-as-is -sS -o /dev/null -w '%{http_code}' "$base$request_path")
  if [ "$actual" != "$expected" ]; then
    printf '%s: expected %s, got %s\n' "$request_path" "$expected" "$actual" >&2
    exit 1
  fi
}

for request_path in /content /content/site.txt /site/accounts/account.txt \
  /kirby/bootstrap.php /vendor/autoload.php /node_modules/package.json \
  /.git/config /.env /composer.json /composer.lock \
  /assets/nested/.private/secret.txt /media/upload.php /media/upload.php/path \
  /media/upload.PHP /content%2Fsite.txt /%2egit/config; do
  assert_status 404 "$request_path"
done

[ "$(curl -fsS "$base/assets/style.css")" = STATIC ]
curl -fsS "$base/notes/example?tag=kirby" | docker exec -i "$container" php -r '
$response = json_decode(stream_get_contents(STDIN), true, 512, JSON_THROW_ON_ERROR);
if ($response["uri"] !== "/notes/example?tag=kirby" || !$response["writable"]) exit(1);
'
curl -fsS -H 'Authorization: Bearer smoke-test' -H 'X-Forwarded-Proto: https' "$base/panel" \
  | docker exec -i "$container" php -r '
$response = json_decode(stream_get_contents(STDIN), true, 512, JSON_THROW_ON_ERROR);
if ($response["authorization"] !== "Bearer smoke-test" || $response["forwardedProto"] !== "https") exit(1);
'

# Editing mounted PHP must be visible with OPcache enabled.
printf '<?php echo "UPDATED";\n' > "$fixture/index.php"
attempt=0
until [ "$(curl -fsS "$base/")" = UPDATED ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 5 ] || exit 1
  sleep 1
done

docker exec "$container" php -r '
foreach (["ctype", "curl", "dom", "exif", "fileinfo", "filter", "gd", "hash", "iconv", "intl", "json", "libxml", "mbstring", "openssl", "SimpleXML", "sodium", "zip", "zlib", "Zend OPcache"] as $extension) {
  if (!extension_loaded($extension)) {
    fwrite(STDERR, "Missing extension: $extension\n");
    exit(1);
  }
}
$image = imagecreatetruecolor(4, 4);
if (!imagejpeg($image, "/tmp/smoke.jpg")) exit(1);
'
docker exec "$container" composer --version
docker exec "$container" php -r '
$context = stream_context_create(["http" => ["timeout" => 5]]);
exit(@file_get_contents("http://127.0.0.1:8080/", false, $context) === false ? 1 : 0);
'

printf 'Smoke tests passed: routing, private files, static assets, proxy headers, PHP updates, image support and Composer.\n'
