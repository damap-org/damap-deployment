#!/usr/bin/env bash
set -euo pipefail
: "${RUNNER_STATE_DIR:?Set RUNNER_STATE_DIR to the persistent runner directory}"
: "${RUNNER_REPOSITORY_URL:?Set RUNNER_REPOSITORY_URL}"
: "${RUNNER_IMAGE_VERSION:?Missing image version}"
cd "$RUNNER_STATE_DIR"
export HOME="$RUNNER_STATE_DIR"
umask 077
# Prevent registration or a second listener from sharing the same credentials.
exec 9>.runner-lock
flock -n 9 || { echo 'Another runner process is using this state directory.' >&2; exit 1; }
if [[ ! -f .image-version ]] || [[ $(cat .image-version) != "$RUNNER_IMAGE_VERSION" ]]; then
  # Preserve registration credentials while replacing the runtime on image upgrades.
  cp -R /opt/actions-runner/. .
  printf '%s\n' "$RUNNER_IMAGE_VERSION" > .image-version
fi
case ${1:-start} in
  register)
    [[ ! -f .runner ]] || { echo 'Already registered; stop the service and unregister first.' >&2; exit 1; }
    # config.sh prompts for the short-lived registration token; no PAT is stored.
    exec ./config.sh --url "$RUNNER_REPOSITORY_URL" \
      --name "${RUNNER_NAME:-damap-demo}" --labels damap-deploy \
      --work _work --disableupdate
    ;;
  unregister)
    exec ./config.sh remove
    ;;
  start)
    [[ -f .runner ]] || { echo 'Register first: docker compose ... run --rm runner register' >&2; exit 1; }
    exec ./run.sh
    ;;
  *) echo 'Expected start, register or unregister.' >&2; exit 2 ;;
esac
