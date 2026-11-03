#!/usr/bin/env bash
# Host only: use the approved, deployed checkout without changing its revision.
set -euo pipefail

checkout=${1:?Pass the absolute deployment checkout}
config=${2:?Pass the absolute runner env file}
[[ $checkout == /* && $config == /* ]]
cd "$checkout"

# Only one updater may build or replace the runner at a time.
exec 8>"$(git rev-parse --git-path runner-update.lock)"
flock -n 8 || exit 0

snapshot=$(mktemp -d)
container=''

restore() {
  # A failed wait must leave the existing runner able to accept jobs again.
  if [[ -n $container ]]; then
    docker update --restart unless-stopped "$container" >/dev/null
    docker start "$container" >/dev/null
  fi
  rm -rf "$snapshot"
}

trap restore EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# Serialize the snapshot with application deployments, then release the lock:
# the next deployment job must be able to finish while we wait for runner exit.
exec 9>"$(git rev-parse --git-path deploy.lock)"
flock -n 9 || exit 0
test -z "$(git status --porcelain)"
git archive HEAD docker/runner docker-compose.runner.yml | tar -x -C "$snapshot"
flock -u 9

compose=(docker compose --env-file "$config" -f "$snapshot/docker-compose.runner.yml")
"${compose[@]}" config --quiet
current=$("${compose[@]}" ps --all -q runner)
test -n "$current"

# Bootstrap must be done once while idle, before enabling this service.
docker exec "$current" grep -q 'exec ./run.sh --once' /usr/local/bin/damap-runner
# Build before changing the running container, so build failures leave it alone.
"${compose[@]}" build --pull runner
desired=$("${compose[@]}" config --images)
if [[ $(docker inspect --format '{{.Image}}' "$current") == "$(docker image inspect --format '{{.Id}}' "$desired")" ]]; then
  echo 'Runner image is already current.'
  exit 0
fi

# --once exits after a job. Disable restart so it stays offline for replacement.
container=$current
docker update --restart no "$container" >/dev/null
echo 'Waiting for the runner to exit after its next job; no job will be interrupted.'
timeout 23h docker wait "$container"

# The listener has exited, so no new job can race with container recreation.
"${compose[@]}" up -d --no-build runner
# The replacement now owns the restart policy; skip recovery of the old container.
container=''
echo 'Runner container updated. Check its status in GitHub.'
