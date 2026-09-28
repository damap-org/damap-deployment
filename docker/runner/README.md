# Demo deployment runner

A deployment-only GitHub Actions runner on the existing DAMAP VM. Public CI runs
on GitHub-hosted runners on pushes to `master` and `ci-smoke-tests`; no PR trigger
is added. This runner uses the host Docker socket to deploy the
existing `damap-deployment` Compose project without SSH. Socket access grants
control of the Docker host; the container is not a security boundary from DAMAP.
Only trusted maintainers should be able to change or run deployment workflows.
Runner labels route jobs; they are not access controls.

## One-time host setup

The supplied example uses the confirmed host IDs: damap UID/GID 1001, Docker GID
998, and Compose project `damap-deployment`. Verify the absolute checkout path
with `pwd -P`. Keep the existing application `.env`, database and TLS files.

As `damap`, from the repository checkout containing this runner setup:

```sh
install -d -m 700 /home/damap/.config /home/damap/.local/share/damap-runner /home/damap/db_backups
cp docker/runner/example.env /home/damap/.config/damap-runner.env
chmod 600 /home/damap/.config/damap-runner.env
# Review paths before proceeding; every bind-mount directory must already exist.
docker compose --env-file /home/damap/.config/damap-runner.env -f docker-compose.runner.yml build
```

The checkout, runner state and backup directory are mounted at identical absolute
paths inside and outside the container. Host Docker resolves bind-mount sources
on the host, not inside the runner. Relative or remapped paths can mount the wrong
files. The runner uses its own workspace under the state directory; Actions
checkout never cleans the live deployment checkout.

In GitHub, open **Settings → Actions → Runners → New self-hosted runner**. Select
Linux and copy the short-lived registration token from the generated instructions.
Run the following command and paste the token when prompted (do not put it into a
workflow, committed `.env`, or shell command history):

```sh
docker compose --env-file /home/damap/.config/damap-runner.env -f docker-compose.runner.yml run --rm runner register
docker compose --env-file /home/damap/.config/damap-runner.env -f docker-compose.runner.yml up -d runner
```

Registration and runner credentials persist in the private state directory. A
restart needs no new token. No PAT or SSH key is needed. Confirm `damap-demo` is
**Idle** in GitHub; container running status alone does not prove connectivity.
The VM needs outbound HTTPS to GitHub's required runner endpoints and the image
registries; no inbound runner port is published.

## Deployment

Merge the tested workflow and scripts into `master` before using them. Configure
GitHub environment `demo` to allow only branch `master`; keep master protected.
Use external-contributor workflow approval controls and do not approve workflows
that route untrusted code to this runner. A new workflow can target a repository
runner: a `master` condition in our deployment YAML cannot prevent that.

Select **Actions → Deploy demo → Run workflow → master**. The selected SHA is
first tested on a GitHub-hosted runner. Only after success does the local runner
back up PostgreSQL, deploy that exact SHA, check backend readiness, reload Nginx
upstreams and verify public HTTPS routes. The host checkout must be clean and the
existing PostgreSQL container must be running under `damap-deployment`.
Concurrent deployments are serialized both by Actions and a host checkout lock.

The workflow uses the host's `.env`; CI uses its own disposable fixture settings.
Confirm the host's PostgreSQL and Keycloak versions are explicitly configured
before enabling automation. A passing fresh-database smoke test is not an upgrade
test against the demo's existing database.

Backups go to `/home/damap/db_backups` with mode 600. Failed dumps remain `.partial`
and never trigger deployment. Failure after database migration requires manual
assessment; there is no automatic database rollback. Backup retention and off-host
copies remain an operator responsibility. No `compose down` or volume removal is
performed on the live application.

## Lifecycle

The runner uses its own `damap-runner` Compose project. Do not include its service
in the application Compose file, and do not restart it during an active deployment.
The runner's CPU/memory limits apply to the runner process, not sibling application
containers or builds performed by the host Docker daemon.

Automatic runner updates are disabled for the pinned image. Bump the runner image
and `RUNNER_IMAGE_VERSION` together, rebuild, then recreate the idle runner.
GitHub requires timely runner updates (normally within 30 days of a new release,
and sooner for critical updates). New runtime files are copied into the persistent
state directory on version changes while keeping registration credentials.

To remove registration, stop the runner, obtain a removal token from GitHub, and
run `docker compose ... run --rm runner unregister`; enter the removal token when
prompted. Never commit or publish the runner state directory or its diagnostic logs.

References: [runner registration](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners),
[runner networking and updates](https://docs.github.com/en/actions/reference/runners/self-hosted-runners).
