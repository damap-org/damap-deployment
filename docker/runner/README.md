# Deployment runner

Runs GitHub Actions jobs in a container on the deployment VM, using the host Docker
socket. The runner has its own Compose project, `damap-runner`.

Run the setup commands from the deployment checkout, as the account that owns it.
The account needs Docker access. The VM needs outbound HTTPS to GitHub and the
image registries.

## Setup

Create the directories and copy the configuration template:

```sh
install -d -m 700 "$HOME/.config" "$HOME/.local/share/damap-runner" "$HOME/db_backups"
cp docker/runner/example.env "$HOME/.config/damap-runner.env"
chmod 600 "$HOME/.config/damap-runner.env"
```

Fill in `$HOME/.config/damap-runner.env`:

| Variable | Value |
| --- | --- |
| `RUNNER_UID` | Output of `id -u` |
| `RUNNER_GID` | Output of `id -g` |
| `DOCKER_GID` | Output of `stat -c '%g' /var/run/docker.sock` |
| `DEPLOY_PATH` | Output of `pwd -P` in the application checkout |
| `DEPLOY_PROJECT` | Compose project name from the command below |
| `RUNNER_STATE_DIR` | Full path to `$HOME/.local/share/damap-runner` |
| `BACKUP_DIR` | Full path to the backup directory, e.g. `$HOME/db_backups` |

Get the project name from the running PostgreSQL container:

```sh
docker inspect damap-postgres --format '{{index .Config.Labels "com.docker.compose.project"}}'
```

Use that value for `DEPLOY_PROJECT` so deployment targets the existing stack and
database volume.

All fields are required. Write out the full paths, including the home directory.
Mount directories must exist and use the same paths inside and outside the runner.

Use this helper for the remaining commands. It loads the runner configuration
from the private file above and lasts for the current shell session:

```sh
runner() {
  docker compose --env-file "$HOME/.config/damap-runner.env" -f docker-compose.runner.yml "$@"
}
```

In GitHub, open **Settings → Actions → Runners → New self-hosted runner** and
get a Linux registration token. Paste it when prompted:

```sh
runner build
runner run --rm runner register
runner up -d runner
```

Check that `damap-runner` shows as **Idle** in GitHub.
Registration is stored in `RUNNER_STATE_DIR`, so restarts need no new token.
Jobs use a separate checkout under `RUNNER_STATE_DIR/_work`.

## Status and logs

```sh
runner ps
runner logs --tail 100 -f runner
runner restart runner
```

Restart only when no job is running. If the runner is offline in GitHub, check
its logs and outbound connectivity. No inbound port is needed.

## Deployment settings

In **Settings → Environments**, create `staging` and configure:

- Deployment branches: `master` only
- Required reviewers: the deployment maintainers
- Prevent self-review: unchecked if maintainers need to approve their own pushes

Required reviewers provide the manual approval step.

Add these variables under `staging`, matching the local runner configuration:

| Environment variable | Field in `damap-runner.env` |
| --- | --- |
| `DAMAP_DEPLOY_PATH` | `DEPLOY_PATH` |
| `DAMAP_COMPOSE_PROJECT` | `DEPLOY_PROJECT` |
| `DAMAP_BACKUP_DIR` | `BACKUP_DIR` |

In **Settings → Secrets and variables → Actions → Variables**, add the repository
variable `DAMAP_PUBLIC_URL` with the public HTTPS URL.

The workflow rejects paths or project names that differ from the runner settings.
If a mount path changes, update both configurations and recreate the idle runner.

Application settings and credentials stay in the VM's `.env`.
CI uses `scripts/ci/test.env`. The example file is only used during setup.

## Deploy

A push to `master` starts **CD**. It validates the stack, then waits for approval.
Open the run, check its commit, and select **Review deployments → Approve and
deploy** for `staging`.

After approval, the runner:

- Checks the deployment settings and server HTTPS reachability
- Backs up PostgreSQL
- Deploys the tested commit
- Checks backend readiness and reloads Nginx
- Checks the public endpoints

The first HTTPS check only warns if the server is unreachable.
The checks after deployment must pass.

PRs run **CI** with stack validation only. The application checkout must be clean,
and PostgreSQL must be running before deployment can take a backup.

The checkout stays at the deployed commit in detached-HEAD state.
Each run deploys its own tested commit, including older runs approved later.
Reject pending runs you no longer want to deploy.
Only one deployment runs at a time, and new pushes do not cancel an active update.

## Failed deployments

Check the failed step for the error, previous commit and backup path.
Failed dumps stay as `.partial` and stop deployment.
Completed backups have a `.sql` extension and mode `600`.

There is no automatic rollback. Check container logs and database migrations
before restoring an older version. CI starts with an empty database, so it does
not test migration of the existing data.

Recover database outages manually before deploying.
Backup retention and off-host copies need to be set up separately.

## Update the runner

Renovate opens a runner update PR. Check CI, merge it and approve the staging
deployment. Once the timer below is set up, it checks daily and updates the
runner from the deployed checkout after a job finishes.

The daily **Runner maintenance** workflow gives an idle runner a job so the
update can proceed. You can also start that workflow manually in GitHub Actions.

### One-time setup

After deploying the new version through the pipeline, wait until the runner is
idle. Then run these commands from the deployment checkout as the deployment
user, using the `runner` helper defined above:

```sh
runner up -d --build runner

install -d -m 700 "$HOME/.config/systemd/user" "$HOME/.local/bin"
install -m 700 scripts/update-runner.sh "$HOME/.local/bin/damap-update-runner"
cp docker/runner/systemd/damap-runner-update.* "$HOME/.config/systemd/user/"
```

Edit `~/.config/systemd/user/damap-runner-update.service`. Replace
`/absolute/deployment/path` with the physical path to the checkout; quote it if
it contains spaces. The service uses your existing `~/.config/damap-runner.env`.

Enable the timer, including when you are logged out:

```sh
systemctl --user daemon-reload
sudo loginctl enable-linger "$USER"
systemctl --user enable --now damap-runner-update.timer
systemctl --user list-timers damap-runner-update.timer
```

Repeat the script and unit installation if those files change later.

### If an update has not applied

Check the logs:

```sh
journalctl --user -u damap-runner-update.service
```

To start an update check now:

```sh
systemctl --user start --no-block damap-runner-update.service
```

The update may be waiting for a job to finish. After 23 hours it gives up,
restores the old runner's restart policy and tries again the next day.
The timer does not send failure alerts.

To apply the deployed version manually, wait until the runner is idle and run:

```sh
runner up -d --build runner
```

Check that the runner comes back online in GitHub.

## Remove the runner

Wait for the runner to become idle. Get a removal token from its GitHub settings,
then enter it when prompted:

```sh
runner stop runner
runner run --rm runner unregister
runner down
```

The state and backup directories remain on the VM.

## Host access

Jobs with Docker socket access can control the VM. Run trusted jobs only.
Runner labels route jobs; they do not restrict access.
Keep configuration, registration files and backups out of Git.

The runner's CPU and memory limits do not apply to application containers or
image builds started through the host Docker daemon.
