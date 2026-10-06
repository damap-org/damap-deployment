# Deployment runner

Containerized GitHub Actions runner for the demo VM. It uses the host Docker
socket and runs under the separate Compose project `damap-runner`.

Run these commands from the deployment checkout as its owner. The account needs
Docker access; the VM needs outbound HTTPS to GitHub and the image registries.

## Setup

Create the local directories and configuration file:

```sh
install -d -m 700 "$HOME/.config" "$HOME/.local/share/damap-runner" "$HOME/db_backups"
cp docker/runner/example.env "$HOME/.config/damap-runner.env"
chmod 600 "$HOME/.config/damap-runner.env"
```

Edit `$HOME/.config/damap-runner.env`. All fields are required.

| Variable           | How to obtain the value                                |
| ------------------ | ------------------------------------------------------ |
| `RUNNER_UID`       | `id -u`                                                |
| `RUNNER_GID`       | `id -g`                                                |
| `DOCKER_GID`       | `stat -c '%g' /var/run/docker.sock`                    |
| `DEPLOY_PATH`      | `pwd -P` in the application checkout                   |
| `DEPLOY_PROJECT`   | Read the existing project label with the command below |
| `RUNNER_STATE_DIR` | Full path to `$HOME/.local/share/damap-runner`         |
| `BACKUP_DIR`       | Full path to `$HOME/db_backups`                        |

Read the Compose project name from the running database container and use the
output as `DEPLOY_PROJECT`. This ensures deployment targets the existing stack
and its database volume.

```sh
docker inspect damap-postgres --format '{{index .Config.Labels "com.docker.compose.project"}}'
```

Write out the full paths in the file. The directories must exist, and their paths
must match inside and outside the runner.

Define a shorthand for the commands below in your current shell:

```sh
runner() {
  docker compose --env-file "$HOME/.config/damap-runner.env" -f docker-compose.runner.yml "$@"
}
```

In the repository's GitHub settings, open **Actions → Runners → New self-hosted
runner** and obtain a Linux registration token. Paste it when prompted:

```sh
runner build
runner run --rm runner register
runner up -d runner
```

Check that `damap-runner` is **Idle** in GitHub. Registration is saved in
`RUNNER_STATE_DIR`; restarting the container does not require another token.
Job checkouts are stored under `RUNNER_STATE_DIR/_work`.

## Routine commands

```sh
runner ps
runner logs --tail 100 -f runner
runner restart runner
```

Restart only when no job is running. If GitHub shows the runner as offline,
check the logs and outbound connectivity. No inbound port is needed.

## Update the runner

Automatic updates are disabled. Set the new version in all three places:

- Base-image tag in `docker/runner/Dockerfile`
- `RUNNER_IMAGE_VERSION` in the same file
- Image tag in `docker-compose.runner.yml`

When the runner is idle, rebuild and recreate it:

```sh
runner up -d --build runner
```

## Remove the runner

With no job running, obtain a removal token from the runner's GitHub settings.
Enter it at the unregister prompt:

```sh
runner stop runner
runner run --rm runner unregister
runner down
```

These commands leave the state and backup directories on the VM.

## Host access

The Docker socket gives runner jobs control of the VM. Only run trusted jobs;
labels select a runner but do not restrict who can use it. Keep the configuration,
registration files and backups out of Git.

CPU and memory limits in the runner Compose file apply to the runner container,
not the application containers or builds started through the host Docker daemon.
