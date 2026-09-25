#!/usr/bin/env bash
set -euo pipefail
base=${1:?Usage: smoke.sh https://host [--insecure]}
options=(--fail --silent --show-error --connect-timeout 10 --max-time 30)
if [[ ${2:-} == --insecure ]]; then options+=(--insecure); fi
curl "${options[@]}" "$base/" | grep -i '<html' > /dev/null
config=$(curl "${options[@]}" "$base/api/config")
python3 -c 'import json,sys; c=json.load(sys.stdin); assert c["clientID"] == "damap"; assert c["issuer"].endswith("/auth/realms/damap"); assert {s["queryValue"] for s in c["personSearchServiceConfigs"]} == {"PURE", "ORCID"}; assert c["livePreviewAvailable"]' <<< "$config"
curl "${options[@]}" "$base/auth/realms/damap/.well-known/openid-configuration" | python3 -c 'import json,sys; c=json.load(sys.stdin); assert c["issuer"].endswith("/auth/realms/damap"); assert c["authorization_endpoint"]'
printf 'Frontend, database-backed API configuration and OIDC discovery passed.\n'
