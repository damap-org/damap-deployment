#!/usr/bin/env bash
set -Eeuo pipefail

# The runner shares Docker with the host, but not its localhost. Probe from the backend.
curl() {
  if [[ -n ${SMOKE_CURL_CONTAINER:-} ]]; then
    docker exec "$SMOKE_CURL_CONTAINER" curl "$@"
  else
    command curl "$@"
  fi
}

base=${1:?Usage: smoke.sh https://host [--insecure]}
options=(--fail --silent --show-error --connect-timeout 10 --max-time 30)

if [[ ${2:-} == --insecure ]]; then options+=(--insecure); fi

probe="frontend HTML"

trap 'printf "Smoke probe failed: %s (line %s, exit %s)\n" "$probe" "$LINENO" "$?" >&2' ERR
printf 'Checking %s at %s/\n' "$probe" "$base"
html=$(curl "${options[@]}" "$base/")

if ! grep -i '<html' >/dev/null <<<"$html"; then
  printf 'Frontend response does not contain an HTML document.\n' >&2
  exit 1
fi

probe="API configuration"
printf 'Checking %s at %s/api/config\n' "$probe" "$base"
# Read the complete response first so curl failures are reported as HTTP failures.
config=$(curl "${options[@]}" "$base/api/config")
python3 -c 'import json,sys; c=json.load(sys.stdin); assert c["clientID"] == "damap"; assert c["issuer"].endswith("/auth/realms/damap"); assert {s["queryValue"] for s in c["personSearchServiceConfigs"]} == {"PURE", "ORCID"}; assert c["livePreviewAvailable"]' <<<"$config"

probe="OIDC discovery"
printf 'Checking %s at %s/auth/realms/damap/.well-known/openid-configuration\n' "$probe" "$base"
curl "${options[@]}" "$base/auth/realms/damap/.well-known/openid-configuration" | python3 -c 'import json,sys; c=json.load(sys.stdin); assert c["issuer"].endswith("/auth/realms/damap"); assert c["authorization_endpoint"]'
printf 'Frontend, database-backed API configuration and OIDC discovery passed.\n'
