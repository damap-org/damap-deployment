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
# Verify the API exposes the expected realm and integrations, not just HTTP 200.
python3 -c '
"""Check the application configuration returned by the public API."""
import json
import sys

config = json.load(sys.stdin)
assert config["clientID"] == "damap", "Unexpected OIDC client ID"
assert config["issuer"].endswith("/auth/realms/damap"), "Unexpected OIDC realm"
services = {service["queryValue"] for service in config["personSearchServiceConfigs"]}
assert services == {"PURE", "ORCID"}, "Unexpected person search services"
assert config["livePreviewAvailable"], "Live preview is unavailable"
' <<<"$config"

probe="OIDC discovery"
printf 'Checking %s at %s/auth/realms/damap/.well-known/openid-configuration\n' "$probe" "$base"
discovery=$(curl "${options[@]}" "$base/auth/realms/damap/.well-known/openid-configuration")
python3 -c '
"""Check that Nginx routes OIDC discovery to the expected Keycloak realm."""
import json
import sys

discovery = json.load(sys.stdin)
assert discovery["issuer"].endswith("/auth/realms/damap"), "Unexpected OIDC realm"
assert discovery["authorization_endpoint"], "Missing OIDC authorization endpoint"
' <<<"$discovery"
printf 'Frontend, database-backed API configuration and OIDC discovery passed.\n'
