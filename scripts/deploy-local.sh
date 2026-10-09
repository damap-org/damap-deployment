#!/usr/bin/env bash
# Called by the manual workflow after the selected revision passes stack validation.

set -Eeuo pipefail

checkout=${1:?Missing existing checkout path}
revision=${2:?Missing tested commit SHA}
project=${3:?Missing existing Compose project name}
backup_dir=${4:?Missing backup directory}

stage="validate deployment checkout"
previous=""
backup=""
group_open=false

# Use the same collapsible phases as the isolated stack test.
end_group() {
  if [[ $group_open == true ]]; then
    printf '::endgroup::\n'
    group_open=false
  fi
}

announce() {
  end_group
  stage=$1
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    printf '::group::%s\n' "$stage"
    group_open=true
  else
    printf '\n=== %s ===\n' "$stage"
  fi
}

failed() {
  local result=$1
  local line=$2
  end_group
  printf 'Deployment failed during %s (line %s, exit %s).\n' "$stage" "$line" "$result" >&2
  if [[ -n $previous ]]; then
    printf 'Previous revision: %s\n' "$previous" >&2
  fi
  if [[ -n $backup ]]; then
    printf 'Backup path: %s (only a completed .sql file is usable).\n' "$backup" >&2
  fi
  # The application may already have migrated the database. Never roll it back blindly.
  echo 'Inspect before rolling back database migrations.' >&2
  exit "$result"
}

trap 'failed "$?" "$LINENO"' ERR
trap end_group EXIT
announce "$stage"

[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || { echo 'Expected a full commit SHA.' >&2; exit 1; }
[[ "$project" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo 'Invalid Compose project name.' >&2; exit 1; }
[[ "$checkout" == /* && "$backup_dir" == /* ]] || { echo 'Use absolute host paths.' >&2; exit 1; }

cd "$checkout"
[[ $(pwd -P) == "$checkout" ]] || { echo 'Use the physical checkout path, without symlinks.' >&2; exit 1; }
test -f .env

# Keep the lock open until this process exits, including backup and readiness checks.
exec 9>.git/deploy.lock
flock -n 9 || { echo 'Another deployment is running.' >&2; exit 1; }
test -z "$(git status --porcelain)" || { echo 'Deployment checkout must be clean.' >&2; exit 1; }

# Deploy the tested SHA, which may no longer be the latest commit on master.
git fetch origin master
git cat-file -e "$revision^{commit}"
git merge-base --is-ancestor "$revision" origin/master
previous=$(git rev-parse HEAD)

compose=(docker compose --project-name "$project" --env-file .env -f docker-compose.yml)

# A wrong project name could start a new stack with an empty database volume.
test -n "$("${compose[@]}" ps --status running -q postgres)" || {
  echo "No running PostgreSQL container in project $project; refusing deployment." >&2
  exit 1
}
test -d "$backup_dir" && test -w "$backup_dir"
[[ $(cd "$backup_dir" && pwd -P) == "$backup_dir" ]] || {
  echo 'Use the physical backup path, without symlinks.' >&2
  exit 1
}

announce "back up PostgreSQL"

# Restrict the dump permissions, then restore the mask before checkout and builds.
previous_umask=$(umask)
umask 077
backup="$backup_dir/$(date -u +%Y%m%dT%H%M%SZ)-$previous.sql"

# Resolve POSTGRES_USER inside the running container, using its current configuration.
# shellcheck disable=SC2016
"${compose[@]}" exec -T postgres sh -c 'pg_dumpall -U "$POSTGRES_USER"' > "$backup.partial"
test -s "$backup.partial"
# Only complete, nonempty dumps receive the .sql extension.
mv "$backup.partial" "$backup"
umask "$previous_umask"
printf 'Database backup: %s\nPrevious revision: %s\n' "$backup" "$previous"

announce "deploy the tested revision"

# Detached HEAD ensures a later branch update cannot change this deployment's revision.
git checkout --detach "$revision"
"${compose[@]}" config --quiet
"${compose[@]}" pull --ignore-buildable
"${compose[@]}" build --pull
"${compose[@]}" up -d --wait --wait-timeout 360

announce "verify backend readiness and reload Nginx"

"${compose[@]}" exec -T damap-backend curl --fail --silent --show-error \
  --retry 20 --retry-delay 3 --retry-all-errors --max-time 10 http://localhost:8080/q/health/ready

# Recreated containers can have new IPs. Reload Nginx to resolve its upstreams again.
"${compose[@]}" exec -T nginx nginx -t
"${compose[@]}" exec -T nginx nginx -s reload

end_group
printf '\nDeployed %s\n' "$revision"
