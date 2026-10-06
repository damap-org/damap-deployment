#!/usr/bin/env bash
set -euo pipefail

# The : builtin only expands these expressions; :? rejects unset or empty values.
: "${RUNNER_STATE_DIR:?Set RUNNER_STATE_DIR to the persistent runner directory}"
: "${RUNNER_REPOSITORY_URL:?Set RUNNER_REPOSITORY_URL}"
: "${RUNNER_IMAGE_VERSION:?Missing image version}"

# Keep registration and runner state on the persistent mount across container rebuilds.
cd "$RUNNER_STATE_DIR"

export HOME="$RUNNER_STATE_DIR"

# Registration files may contain credentials: new files are owner-only by default.
umask 077

# Hold an advisory lock on file descriptor 9 for the process lifetime.
# exec below preserves the descriptor; -n fails immediately if another process holds it.
# This prevents registration and listening from using the same state concurrently.
exec 9>.runner-lock
flock -n 9 || {
  echo 'Another runner process is using this state directory.' >&2
  exit 1
}

if [[ ! -f .image-version ]] || [[ $(cat .image-version) != "$RUNNER_IMAGE_VERSION" ]]; then
  # Copy the image's runtime on first use or version changes, including hidden files.
  # Existing registration files remain because the image has no credentials to overwrite.
  # Write the marker only after the copy succeeds so a failed copy is retried.
  cp -R /opt/actions-runner/. .
  printf '%s\n' "$RUNNER_IMAGE_VERSION" >.image-version
fi

# Replace this shell with the runner command so container signals reach it directly.
case ${1:-start} in
register)
  [[ ! -f .runner ]] || {
    echo 'Already registered; stop the service and unregister first.' >&2
    exit 1
  }
  # config.sh prompts for the short-lived registration token; no PAT is stored.
  # Disable self-updates so the runtime version stays tied to the container image.
  # _work holds job checkouts separately from the live application checkout.
  exec ./config.sh --url "$RUNNER_REPOSITORY_URL" \
    --name "${RUNNER_NAME:-damap-runner}" --labels damap-deploy \
    --work _work --disableupdate
  ;;
unregister)
  exec ./config.sh remove
  ;;
start)
  [[ -f .runner ]] || {
    echo 'Register first: docker compose ... run --rm runner register' >&2
    exit 1
  }
  # Jobs create Docker build contexts and bind-mounted fixtures read by other UIDs.
  # Credentials remain protected by the private state directory and registration umask.
  umask 022
  exec ./run.sh
  ;;
*)
  echo 'Expected start, register or unregister.' >&2
  exit 2
  ;;
esac
