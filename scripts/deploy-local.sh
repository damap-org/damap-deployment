#!/usr/bin/env bash
# Called only by the manual deployment job after its exact revision passes CI.
set -euo pipefail
checkout=${1:?Missing existing checkout path}
revision=${2:?Missing tested commit SHA}
project=${3:?Missing existing Compose project name}
backup_dir=${4:?Missing backup directory}
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || { echo 'Expected a full commit SHA.' >&2; exit 1; }
[[ "$project" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo 'Invalid Compose project name.' >&2; exit 1; }
[[ "$checkout" == /* && "$backup_dir" == /* ]] || { echo 'Use absolute host paths.' >&2; exit 1; }
cd "$checkout"
[[ $(pwd -P) == "$checkout" ]] || { echo 'Use the physical checkout path, without symlinks.' >&2; exit 1; }
test -f .env
exec 9>.git/deploy.lock
flock -n 9 || { echo 'Another deployment is running.' >&2; exit 1; }
test -z "$(git status --porcelain)" || { echo 'Deployment checkout must be clean.' >&2; exit 1; }
git fetch origin master
git cat-file -e "$revision^{commit}"
git merge-base --is-ancestor "$revision" origin/master
previous=$(git rev-parse HEAD)
compose=(docker compose --project-name "$project" --env-file .env -f docker-compose.yml)
# Never accidentally initialize an empty stack with a different project name.
test -n "$("${compose[@]}" ps --status running -q postgres)" || {
  echo "No running PostgreSQL container in project $project; refusing deployment." >&2
  exit 1
}
test -d "$backup_dir" && test -w "$backup_dir"
umask 077
backup="$backup_dir/$(date -u +%Y%m%dT%H%M%SZ)-$previous.sql"
# Expand the database user inside the PostgreSQL container.
# shellcheck disable=SC2016
"${compose[@]}" exec -T postgres sh -c 'pg_dumpall -U "$POSTGRES_USER"' > "$backup.partial"
test -s "$backup.partial"
mv "$backup.partial" "$backup"
printf 'Database backup: %s\nPrevious revision: %s\n' "$backup" "$previous"
trap 'echo "Deployment failed. Previous revision: $previous; database backup: $backup. Inspect before rolling back database migrations." >&2' ERR
git checkout --detach "$revision"
"${compose[@]}" config --quiet
"${compose[@]}" pull --ignore-buildable
"${compose[@]}" build --pull
"${compose[@]}" up -d --wait --wait-timeout 360
"${compose[@]}" exec -T damap-backend curl --fail --silent --show-error \
  --retry 20 --retry-delay 3 --retry-all-errors --max-time 10 http://localhost:8080/q/health/ready
# Refresh upstream addresses if application containers were recreated.
"${compose[@]}" exec -T nginx nginx -t
"${compose[@]}" exec -T nginx nginx -s reload
printf '\nDeployed %s\n' "$revision"
