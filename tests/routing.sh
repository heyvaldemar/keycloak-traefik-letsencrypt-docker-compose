#!/usr/bin/env bash
# Which requests reach Keycloak through Traefik: by hostname, path and source
# address, against the running stack.
#
#   tests/routing.sh              .env leaves KEYCLOAK_ADMIN_HOSTNAME,
#                                 KEYCLOAK_PUBLIC_REALMS and KEYCLOAK_ADMIN_ALLOWED_IPS
#                                 unset: one hostname, every path, every source
#   tests/routing.sh --split      .env sets all three, KEYCLOAK_PUBLIC_REALMS=company
#   tests/routing.sh --one-host   .env sets KEYCLOAK_PUBLIC_REALMS=company and
#                                 KEYCLOAK_ADMIN_ALLOWED_IPS, no admin hostname
#
# The last two need TEST_ALLOWED_IP and TEST_DENIED_IP: two free addresses on
# traefik-network, the first inside the allowlist and the second outside it.
#
# Requests come from throwaway curl containers on traefik-network, so Traefik
# sees a known source address, and reach Traefik by its container address with
# --resolve, so no DNS is needed. The last two create the realms company,
# customer and company-test and set or clear the master realm's frontend URL,
# the step the README gives: run them on a test stack, never on a deployment.
#
# CI runs the first form in deploy-and-test and the other two in their own job.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-keycloak}"
DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-keycloak-traefik-letsencrypt-docker-compose.yml}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.23.0@sha256:3fb7e13e5d179a845c97d78204f3f1064d1907037f26a3ebf91710571151fd93}"

MODE="default"
case "${1:-}" in
  "") ;;
  --split) MODE="split" ;;
  --one-host) MODE="one-host" ;;
  *) echo "usage: $0 [--split | --one-host]" >&2; exit 2 ;;
esac

[[ -f .env ]] || { echo "error: .env not found at $REPO_ROOT/.env" >&2; exit 1; }
# envval <NAME>: its value in .env, quotes removed; empty when absent
envval() { { grep -E "^$1=" .env || true; } | tail -n 1 | cut -d= -f2- | sed -e "s/^['\"]//" -e "s/['\"]$//"; }

PUBLIC="$(envval KEYCLOAK_HOSTNAME)"
ADMIN="$(envval KEYCLOAK_ADMIN_HOSTNAME)"
REALMS="$(envval KEYCLOAK_PUBLIC_REALMS)"
ALLOWED_IPS="$(envval KEYCLOAK_ADMIN_ALLOWED_IPS)"
ADMIN_USER="$(envval KEYCLOAK_ADMIN_USERNAME)"
[[ -n "$PUBLIC" && -n "$ADMIN_USER" ]] || { echo "error: .env lacks KEYCLOAK_HOSTNAME or KEYCLOAK_ADMIN_USERNAME" >&2; exit 1; }

case "$MODE" in
  default)
    [[ -z "$ADMIN$REALMS$ALLOWED_IPS" ]] || {
      echo "error: the default run needs KEYCLOAK_ADMIN_HOSTNAME, KEYCLOAK_PUBLIC_REALMS and KEYCLOAK_ADMIN_ALLOWED_IPS unset" >&2; exit 1; } ;;
  split)
    [[ -n "$ADMIN" && "$REALMS" == company && -n "$ALLOWED_IPS" ]] || {
      echo "error: --split needs KEYCLOAK_ADMIN_HOSTNAME, KEYCLOAK_PUBLIC_REALMS=company and KEYCLOAK_ADMIN_ALLOWED_IPS in .env" >&2; exit 1; } ;;
  one-host)
    [[ -z "$ADMIN" && "$REALMS" == company && -n "$ALLOWED_IPS" ]] || {
      echo "error: --one-host needs KEYCLOAK_PUBLIC_REALMS=company and KEYCLOAK_ADMIN_ALLOWED_IPS, and no KEYCLOAK_ADMIN_HOSTNAME, in .env" >&2; exit 1; } ;;
esac
if [[ "$MODE" != default ]]; then
  [[ -n "${TEST_ALLOWED_IP:-}" && -n "${TEST_DENIED_IP:-}" ]] || {
    echo "error: --$MODE needs TEST_ALLOWED_IP and TEST_DENIED_IP" >&2; exit 1; }
fi
ADMIN="${ADMIN:-$PUBLIC}"

TRAEFIK="$(docker compose -f "$DOCKER_COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" ps -q traefik | head -n 1)"
KEYCLOAK="$(docker compose -f "$DOCKER_COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" ps -q keycloak | head -n 1)"
[[ -n "$TRAEFIK" && -n "$KEYCLOAK" ]] || { echo "error: traefik or keycloak container not found" >&2; exit 1; }
TRAEFIK_IP="$(docker inspect -f '{{(index .NetworkSettings.Networks "traefik-network").IPAddress}}' "$TRAEFIK")"

OK="routing-test-allowed-$$"
NO="routing-test-denied-$$"
cleanup() { docker rm -f "$OK" "$NO" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# client <name> [ip]: a curl container on traefik-network that stays up
client() {
  docker run -d --name "$1" --network traefik-network ${2:+--ip "$2"} \
    --entrypoint sleep "$CURL_IMAGE" infinity >/dev/null
}

# c <client> <curl args...>: curl from that client, both hostnames resolved to Traefik
c() {
  local who="$1"; shift
  docker exec -i "$who" curl -sk --max-time 20 \
    --resolve "$PUBLIC:443:$TRAEFIK_IP" --resolve "$ADMIN:443:$TRAEFIK_IP" "$@"
}

FAILS=0
pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAILS=$((FAILS + 1)); }

# same <got> <want> <what>
same() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3: expected $2, got ${1:-nothing}"; fi; }

# expect <client> <code> <url> <what>
expect() {
  local got
  got="$(c "$1" -o /dev/null -w '%{http_code}' "$3" || true)"
  if [[ "$got" == "$2" ]]; then pass "$2 $4"; else fail "$4: expected $2, got $got ($3)"; fi
}

# issuer <client> <discovery-url>
issuer() { c "$1" "$2" | grep -oE '"issuer":"[^"]*"' | cut -d'"' -f4 || true; }

# token <client> <host>: an admin access token by the password grant, the
# password sent on stdin
token() {
  { printf 'grant_type=password&client_id=admin-cli&username=%s&password=' "$ADMIN_USER"; envval KEYCLOAK_ADMIN_PASSWORD | tr -d '\n'; } \
    | c "$1" -X POST --data-binary @- "https://$2/realms/master/protocol/openid-connect/token" \
    | sed -nE 's/.*"access_token":"([^"]+)".*/\1/p'
}

# bearer <client> <token> <curl args...>: the token goes in a config read
# from stdin, not on a command line
bearer() {
  local who="$1" tok="$2"; shift 2
  printf 'header = "Authorization: Bearer %s"\n' "$tok" | c "$who" -K - "$@"
}

# kcadm_master_frontend <url>: the README's own command, inside the Keycloak
# container, the password on stdin; an empty url clears the setting
kcadm_master_frontend() {
  envval KEYCLOAK_ADMIN_PASSWORD | docker exec -i "$KEYCLOAK" bash -c '
    read -r KC_CLI_PASSWORD; export KC_CLI_PASSWORD
    /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user "$1" >/dev/null 2>&1 &&
    /opt/keycloak/bin/kcadm.sh update realms/master -s "attributes.frontendUrl=$2"' _ "$ADMIN_USER" "$1"
}

# console_login <client> <host>: the Admin Console's own sign-in, PKCE and
# all. Prints "<form host> <post status> <token issuer> <admin API status>".
console_login() {
  local who="$1" h="$2" v ch ru page action host post code tok at iss api
  docker exec "$who" rm -f /tmp/jar
  v="$(openssl rand -hex 32)"
  ch="$(printf %s "$v" | openssl dgst -binary -sha256 | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
  ru="https%3A%2F%2F$h%2Fadmin%2Fmaster%2Fconsole%2F"
  page="$(c "$who" -c /tmp/jar -b /tmp/jar "https://$h/realms/master/protocol/openid-connect/auth?client_id=security-admin-console&redirect_uri=$ru&response_type=code&scope=openid&code_challenge=$ch&code_challenge_method=S256" || true)"
  action="$(tr '\n' ' ' <<<"$page" | grep -oE '<form[^>]*id="kc-form-login"[^>]*>' | grep -oE 'action="[^"]*"' | sed -e 's/^action="//' -e 's/"$//' -e 's/&amp;/\&/g' || true)"
  host="$(sed -E 's#^https://([^/:]+).*#\1#' <<<"$action")"
  post="$({ printf 'credentialId=&username=%s&password=' "$ADMIN_USER"; envval KEYCLOAK_ADMIN_PASSWORD | tr -d '\n'; } \
    | c "$who" -c /tmp/jar -b /tmp/jar -o /dev/null -w '%{http_code} %{redirect_url}' --data-binary @- "${action:-https://$h/}" || echo 000)"
  code="$(grep -oE '[?&]code=[^& ]+' <<<"$post" | head -n 1 | cut -d= -f2 || true)"
  iss="-" api="-"
  if [[ -n "$code" ]]; then
    tok="$(c "$who" -X POST "https://$h/realms/master/protocol/openid-connect/token" \
      --data-urlencode grant_type=authorization_code --data-urlencode client_id=security-admin-console \
      --data-urlencode "code=$code" --data-urlencode "redirect_uri=https://$h/admin/master/console/" \
      --data-urlencode "code_verifier=$v" || true)"
    at="$(sed -nE 's/.*"access_token":"([^"]+)".*/\1/p' <<<"$tok")"
    if [[ -n "$at" ]]; then
      iss="$(cut -d. -f2 <<<"$at" | tr '_-' '/+' | { base64 -d 2>/dev/null || true; } | grep -oE '"iss":"[^"]*"' | cut -d'"' -f4 || true)"
      api="$(bearer "$who" "$at" -o /dev/null -w '%{http_code}' "https://$h/admin/realms" || true)"
    fi
  fi
  echo "${host:--} ${post%% *} ${iss:--} $api"
}

# signs_in <client> <host>: the Admin Console sign-in on that host works end
# to end, its form and its token both on that host
signs_in() {
  local host post iss api
  read -r host post iss api <<<"$(console_login "$1" "$2")"
  if [[ "$host" == "$2" && "$post" == 302 && "$iss" == "https://$2/realms/master" && "$api" == 200 ]]; then
    pass "Admin Console sign-in: form on $host, token from $iss, Admin REST API 200"
  else
    fail "Admin Console sign-in on $2: form on $host, post $post, issuer $iss, Admin REST API $api"
  fi
}

# routed <client>: wait until Traefik routes the Admin Console on the admin
# hostname to that client. Traefik leaves a container out until its health
# check passes, so a just-recreated Keycloak answers 404 for a while.
routed() {
  local st=""
  for _ in $(seq 1 24); do
    st="$(c "$1" -o /dev/null -w '%{http_code}' "https://$ADMIN/admin/master/console/" || true)"
    [[ "$st" == 200 ]] && return 0
    sleep 5
  done
  echo "error: https://$ADMIN/admin/master/console/ still answers ${st:-nothing} after two minutes" >&2
  exit 1
}

# make_realms <client> <host>: company, customer and company-test, through
# the Admin REST API on that host
make_realms() {
  local tok r st
  tok="$(token "$1" "$2")"
  [[ -n "$tok" ]] || { echo "error: no admin token from https://$2" >&2; exit 1; }
  for r in company customer company-test; do
    st="$(bearer "$1" "$tok" -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -d "{\"realm\":\"$r\",\"enabled\":true}" "https://$2/admin/realms")"
    [[ "$st" == 201 || "$st" == 409 ]] || { echo "error: creating realm $r returned $st" >&2; exit 1; }
  done
  echo "realms company, customer and company-test exist"
}

# public_company <client>: what applications need of the realm company,
# from a source the allowlist does not name
public_company() {
  local page form css
  expect "$1" 200 "https://$PUBLIC/realms/company/.well-known/openid-configuration" "company discovery"
  expect "$1" 200 "https://$PUBLIC/.well-known/oauth-authorization-server/realms/company" "company RFC 8414 discovery"
  same "$(issuer "$1" "https://$PUBLIC/realms/company/.well-known/openid-configuration")" "https://$PUBLIC/realms/company" "company issuer"
  page="$(c "$1" "https://$PUBLIC/realms/company/protocol/openid-connect/auth?client_id=account-console&redirect_uri=https%3A%2F%2F$PUBLIC%2Frealms%2Fcompany%2Faccount%2F&response_type=code&scope=openid&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256" || true)"
  form="$(tr '\n' ' ' <<<"$page" | grep -oE '<form[^>]*id="kc-form-login"[^>]*>' | grep -oE 'action="https://[^/"]+' | cut -d/ -f3 || true)"
  same "$form" "$PUBLIC" "the company sign-in form posts to the public hostname"
  css="$(grep -oE '/resources/[^"]+\.css' <<<"$page" | head -n 1 || true)"
  if [[ -n "$css" ]]; then expect "$1" 200 "https://$PUBLIC$css" "a stylesheet of that page"; else fail "the sign-in page names no stylesheet"; fi
}

# closed <client> <code> <host>: everything but the public realm, refused
closed() {
  expect "$1" "$2" "https://$3/realms/master/.well-known/openid-configuration" "master discovery"
  expect "$1" "$2" "https://$3/.well-known/oauth-authorization-server/realms/master" "master RFC 8414 discovery"
  expect "$1" "$2" "https://$3/realms/master/protocol/openid-connect/token" "master token endpoint"
  expect "$1" "$2" "https://$3/realms/customer/.well-known/openid-configuration" "a realm not listed (customer)"
  expect "$1" "$2" "https://$3/realms/company-test/.well-known/openid-configuration" "a realm whose name starts like a listed one"
  expect "$1" "$2" "https://$3/admin/master/console/" "Admin Console"
  expect "$1" "$2" "https://$3/admin/realms" "Admin REST API"
  expect "$1" "$2" "https://$3/" "/"
}

case "$MODE" in
  default)
    echo "one hostname, nothing restricted: every path reaches Keycloak on $PUBLIC"
    client "$OK"
    routed "$OK"
    expect "$OK" 302 "https://$PUBLIC/" "/ redirects to the Admin Console"
    expect "$OK" 200 "https://$PUBLIC/admin/master/console/" "Admin Console"
    expect "$OK" 200 "https://$PUBLIC/realms/master/.well-known/openid-configuration" "master discovery"
    expect "$OK" 200 "https://$PUBLIC/.well-known/oauth-authorization-server/realms/master" "master RFC 8414 discovery"
    same "$(issuer "$OK" "https://$PUBLIC/realms/master/.well-known/openid-configuration")" "https://$PUBLIC/realms/master" "master issuer"
    signs_in "$OK" "$PUBLIC"
    ;;

  split)
    echo "public $PUBLIC (realm company), admin $ADMIN for $ALLOWED_IPS"
    client "$OK" "$TEST_ALLOWED_IP"
    client "$NO" "$TEST_DENIED_IP"
    kcadm_master_frontend ""
    routed "$OK"
    make_realms "$OK" "$ADMIN"

    echo "public hostname, from a source outside the allowlist:"
    public_company "$NO"
    closed "$NO" 404 "$PUBLIC"
    echo "admin hostname, from a source outside the allowlist:"
    expect "$NO" 403 "https://$ADMIN/admin/master/console/" "Admin Console"
    expect "$NO" 403 "https://$ADMIN/realms/master/.well-known/openid-configuration" "master discovery"
    echo "admin hostname, from a source inside the allowlist:"
    expect "$OK" 200 "https://$ADMIN/admin/master/console/" "Admin Console"

    # Keycloak builds the master realm's sign-in form from KC_HOSTNAME, so the
    # form served on the admin hostname posts to the public one: master is not
    # served there, and a browser would not send the admin hostname's cookies
    # there anyway. This is why the README sets master's frontend URL. Check
    # that the failure is still that one, take the step exactly as the README
    # gives it, and sign in again.
    read -r host post _ _ <<<"$(console_login "$OK" "$ADMIN")"
    if [[ "$host" == "$PUBLIC" && "$post" == 404 ]]; then
      pass "before the frontend URL is set, the sign-in form posts to $host and gets 404"
    else
      fail "before the frontend URL is set: expected the form on $PUBLIC and 404, got form on $host, post $post"
    fi
    kcadm_master_frontend "https://$ADMIN"
    echo "set the master realm's frontend URL to https://$ADMIN with kcadm.sh"
    signs_in "$OK" "$ADMIN"
    ;;

  one-host)
    echo "one hostname $PUBLIC: realm company for everyone, the rest for $ALLOWED_IPS"
    client "$OK" "$TEST_ALLOWED_IP"
    client "$NO" "$TEST_DENIED_IP"
    # A frontend URL left from a separate admin hostname would send the
    # sign-in to a hostname nothing routes; the README clears it first.
    kcadm_master_frontend ""
    routed "$OK"
    make_realms "$OK" "$PUBLIC"

    echo "from a source outside the allowlist:"
    public_company "$NO"
    closed "$NO" 403 "$PUBLIC"
    echo "from a source inside the allowlist:"
    expect "$OK" 200 "https://$PUBLIC/admin/master/console/" "Admin Console"
    expect "$OK" 200 "https://$PUBLIC/realms/customer/.well-known/openid-configuration" "a realm not listed (customer)"
    signs_in "$OK" "$PUBLIC"
    ;;
esac

if [[ "$FAILS" -gt 0 ]]; then
  echo "$FAILS check(s) failed"
  exit 1
fi
echo "every routing check passed"
