"""Reject partial runner version updates before building the image."""

import pathlib
import re

root = pathlib.Path(__file__).resolve().parents[2]
dockerfile = (root / 'docker/runner/Dockerfile').read_text()
compose = (root / 'docker-compose.runner.yml').read_text()

# These values control the downloaded runtime, persistent copy and local image tag.
versions = []
for pattern, source in [
    (r'^FROM ghcr.io/actions/actions-runner:(\d+\.\d+\.\d+)$', dockerfile),
    (r'^ENV RUNNER_IMAGE_VERSION=(\d+\.\d+\.\d+)$', dockerfile),
    (r'^    image: damap-deployment-runner:(\d+\.\d+\.\d+)$', compose),
]:
    matches = re.findall(pattern, source, re.MULTILINE)
    if len(matches) != 1:
        raise SystemExit(f'Expected exactly one runner version matching {pattern}')
    versions.extend(matches)

if len(set(versions)) != 1:
    raise SystemExit(f'Runner versions disagree: {versions}')

print(f'Runner version: {versions[0]}')
