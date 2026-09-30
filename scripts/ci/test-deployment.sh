#!/usr/bin/env bash
# Run from the repository root. Never reads the host .env or uses its volumes.
set -euo pipefail
root=$(pwd)
work=$(mktemp -d)
project="damap-ci-${GITHUB_RUN_ID:-$$}-${GITHUB_RUN_ATTEMPT:-1}"
compose=(docker compose --project-name "$project" --file "$work/compose.json")
cleanup() {
  result=$?
  if (( result != 0 )); then
    "${compose[@]}" ps --all || true
    "${compose[@]}" logs --no-color --tail 150 || true
  fi
  "${compose[@]}" down --volumes --remove-orphans || true
  rm -rf "$work"
  exit "$result"
}
trap cleanup EXIT
# Use committed test settings rather than host credentials or exported overrides.
env -i PATH="$PATH" HOME="$HOME" docker compose --env-file "$root/scripts/ci/test.env" -f "$root/docker-compose.yml" config --format json > "$work/base.json"
python3 - "$work" <<'PYCODE'
import json,sys
from pathlib import Path
work=Path(sys.argv[1]); config=json.loads((work/'base.json').read_text())
config.pop('name',None)
writable_directories={}
for service in config['services'].values():
    service.pop('container_name',None)
    service.pop('ports',None)
    service['restart']='no'
    for volume in service.get('volumes',[]):
        if volume['type']=='bind' and not volume.get('read_only'):
            source=Path(volume['source'])
            target=volume['target']
            # Input fixtures and entrypoint scripts remain repository files.
            if source.is_file():
                volume['read_only']=True
            else:
                name=writable_directories.setdefault(str(source), f'ci-data-{len(writable_directories)}')
                config.setdefault('volumes', {})[name]={}
                volume.clear()
                volume.update(type='volume', source=name, target=target)
# All checks use the private Compose network; publish no host ports.
# Exercise the service wiring without requesting certificates from Let's Encrypt.
config['services']['certbot']['entrypoint']=['/bin/sh','-c','sleep infinity']
for volume in config.get('volumes',{}).values():
    volume.pop('name',None)
for network in config.get('networks',{}).values():
    network.pop('name',None)
(work/'compose.json').write_text(json.dumps(config))
PYCODE
"${compose[@]}" config --quiet
"${compose[@]}" pull --ignore-buildable
"${compose[@]}" up --build --wait --wait-timeout 360
SMOKE_CURL_CONTAINER=$("${compose[@]}" ps -q damap-backend)
export SMOKE_CURL_CONTAINER
bash scripts/ci/smoke.sh "https://nginx" --insecure
"${compose[@]}" exec -T damap-backend curl --fail --silent http://localhost:8080/q/health/ready
