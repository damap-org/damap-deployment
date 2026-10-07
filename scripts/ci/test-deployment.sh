#!/usr/bin/env bash
# Run from the repository root. Never reads the host .env or uses its volumes.

set -Eeuo pipefail

# Give each run its own Compose project so cleanup cannot target the live stack.
root=$(pwd)
work=$(mktemp -d)
project="damap-ci-${GITHUB_RUN_ID:-$$}-${GITHUB_RUN_ATTEMPT:-1}"
compose=(docker compose --project-name "$project" --file "$work/compose.json")
stage="generate isolated Compose configuration"
failed_line=""
group_open=false

trap 'failed_line=$LINENO' ERR

# GitHub folds each phase; local runs keep plain headings.
end_group() {
  if [[ $group_open == true ]]; then
    printf '::endgroup::\n'
    group_open=false
  fi
}

begin_group() {
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    printf '::group::%s\n' "$1"
    group_open=true
  else
    printf '\n=== %s ===\n' "$1"
  fi
}

announce() {
  end_group
  stage=$1
  begin_group "$stage"
}

cleanup() {
  result=$?
  trap - ERR EXIT
  set +e
  end_group

  if ((result != 0)); then
    printf 'FAILED: %s (exit %s, line %s)\n' "$stage" "$result" "${failed_line:-unknown}" >&2
    begin_group "Failure diagnostics"
    "${compose[@]}" ps --all

    # Healthcheck output is not always included in application logs.
    while IFS= read -r container; do
      [[ -n $container ]] || continue
      docker inspect --format '{{.Name}} {{json .State}}' "$container"
    done < <("${compose[@]}" ps --all --quiet)

    "${compose[@]}" logs --no-color --tail 150
    end_group
  fi

  # Cleanup must not hide the original failing phase or exit code.
  begin_group "Clean up disposable project $project"

  if ! "${compose[@]}" down --volumes --remove-orphans; then
    printf 'Cleanup failed for project %s; inspect remaining resources.\n' "$project" >&2

    if ((result == 0)); then
      result=1
      stage="Compose cleanup"
    fi
  fi

  if ! rm -rf "$work"; then
    printf 'Could not remove temporary directory %s\n' "$work" >&2

    if ((result == 0)); then
      result=1
      stage="temporary directory cleanup"
    fi
  fi

  end_group

  if ((result != 0)); then
    printf '::error::Deployment smoke test failed during %s (exit %s; script line %s). See diagnostics above cleanup.\n' "$stage" "$result" "${failed_line:-unknown}" >&2
  else
    printf 'Deployment smoke test and cleanup passed.\n'
  fi

  exit "$result"
}

trap cleanup EXIT
announce "$stage"

# Keep the host .env and exported integration settings out of the test stack.
env -i PATH="$PATH" HOME="$HOME" docker compose --env-file "$root/scripts/ci/test.env" -f "$root/docker-compose.yml" config --format json >"$work/base.json"

python3 - "$work" <<'PYCODE'
import json
import sys
from pathlib import Path

work = Path(sys.argv[1])
config = json.loads((work / 'base.json').read_text())
config.pop('name', None)
writable_directories = {}
for service in config['services'].values():
    service.pop('container_name', None)
    service.pop('ports', None)
    service['restart'] = 'no'

    for volume in service.get('volumes', []):
        if volume['type'] == 'bind' and not volume.get('read_only'):
            source = Path(volume['source'])
            target = volume['target']

            # Keep fixtures and entrypoint scripts, but mount them read-only.
            if source.is_file():
                volume['read_only'] = True
            else:
                # Services sharing a writable directory must share its test volume too.
                name = writable_directories.setdefault(
                    str(source), f'ci-data-{len(writable_directories)}'
                )
                config.setdefault('volumes', {})[name] = {}
                volume.clear()
                volume.update(type='volume', source=name, target=target)

# All checks use the private Compose network; publish no host ports.
# Use the bundled certificate; certbot must not request or renew real certificates.
config['services']['certbot']['entrypoint'] = ['/bin/sh', '-c', 'sleep infinity']

for volume in config.get('volumes', {}).values():
    volume.pop('name', None)

for network in config.get('networks', {}).values():
    network.pop('name', None)

(work / 'compose.json').write_text(json.dumps(config))
PYCODE

announce "validate isolated Compose configuration"
"${compose[@]}" config --quiet

announce "pull test images"
"${compose[@]}" pull --ignore-buildable

announce "build and start stack; wait for healthchecks"
"${compose[@]}" up --build --wait --wait-timeout 360

announce "verify frontend, API and OIDC routes"
SMOKE_CURL_CONTAINER=$("${compose[@]}" ps -q damap-backend)
export SMOKE_CURL_CONTAINER
bash scripts/ci/smoke.sh "https://nginx" --insecure

announce "verify backend readiness"
"${compose[@]}" exec -T damap-backend curl --fail --silent --show-error --connect-timeout 10 --max-time 30 http://localhost:8080/q/health/ready
