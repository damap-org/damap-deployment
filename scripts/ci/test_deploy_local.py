"""Exercise deployment ordering and failure safeguards with Git and a fake Docker CLI."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'deploy-local.sh'


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.origin = self.root / 'origin'
        self.checkout = self.root / 'checkout'
        self.backups = self.root / 'backups'
        self.backups.mkdir()
        self.env = os.environ.copy()
        self.env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
                        GIT_AUTHOR_NAME='Test', GIT_AUTHOR_EMAIL='test@example.invalid',
                        GIT_COMMITTER_NAME='Test', GIT_COMMITTER_EMAIL='test@example.invalid')
        self.run_command('git', 'init', '-b', 'master', str(self.origin))
        (self.origin / '.gitignore').write_text('.env\n')
        (self.origin / 'docker-compose.yml').write_text('services: {}\n')
        self.run_command('git', '-C', str(self.origin), 'add', '.')
        self.run_command('git', '-C', str(self.origin), 'commit', '-m', 'initial')
        self.previous = self.git(self.origin, 'rev-parse', 'HEAD').strip()
        self.run_command('git', 'clone', str(self.origin), str(self.checkout))
        (self.checkout / '.env').write_text('POSTGRES_PASSWORD=test\n')
        (self.origin / 'release').write_text('tested release\n')
        self.run_command('git', '-C', str(self.origin), 'add', '.')
        self.run_command('git', '-C', str(self.origin), 'commit', '-m', 'release')
        self.revision = self.git(self.origin, 'rev-parse', 'HEAD').strip()
        bindir = self.root / 'bin'
        bindir.mkdir()
        docker = bindir / 'docker'
        docker.write_text('''#!/usr/bin/env bash
set -eu
printf '%s|%s\\n' "$(git rev-parse HEAD)" "$*" >> "$TEST_DOCKER_LOG"
case "$*" in
  *'ps --status running -q postgres'*)
    if [[ ${TEST_NO_DATABASE:-0} == 0 ]]; then printf 'postgres-id\\n'; fi ;;
  *pg_dumpall*)
    if [[ ${TEST_DUMP_FAIL:-0} == 1 ]]; then exit 1; fi
    printf 'database-backup\\n' ;;
  *'up -d'*)
    if [[ ${TEST_UP_FAIL:-0} == 1 ]]; then exit 1; fi ;;
esac
''')
        docker.chmod(0o755)
        self.env.update(PATH=f'{bindir}:{self.env["PATH"]}',
                        TEST_DOCKER_LOG=str(self.root / 'docker.log'))

    def run_command(self, *args):
        return subprocess.run(args, env=self.env, text=True, capture_output=True, check=True)

    def git(self, directory, *args):
        return self.run_command('git', '-C', str(directory), *args).stdout

    def deploy(self, **extra):
        return subprocess.run(['bash', str(SCRIPT), str(self.checkout), self.revision,
                               'damap-deployment', str(self.backups)],
                              env=dict(self.env, **extra), text=True, capture_output=True)

    def assert_unchanged(self):
        self.assertEqual(self.git(self.checkout, 'rev-parse', 'HEAD').strip(), self.previous)

    def test_success_backs_up_before_checkout_and_deploys_exact_revision(self):
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git(self.checkout, 'rev-parse', 'HEAD').strip(), self.revision)
        calls = (self.root / 'docker.log').read_text().splitlines()
        dump = next(line for line in calls if 'pg_dumpall' in line)
        up = next(line for line in calls if 'up -d' in line)
        self.assertTrue(dump.startswith(self.previous + '|'))
        self.assertTrue(up.startswith(self.revision + '|'))
        backup, = self.backups.glob('*.sql')
        self.assertEqual(backup.read_text(), 'database-backup\n')
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        self.assertTrue(any('/q/health/ready' in line for line in calls))
        self.assertFalse(any(' down ' in line for line in calls))

    def test_dirty_checkout_is_rejected(self):
        (self.checkout / 'local-edit').write_text('keep me')
        result = self.deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('must be clean', result.stderr)
        self.assert_unchanged()

    def test_missing_database_is_rejected(self):
        result = self.deploy(TEST_NO_DATABASE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('No running PostgreSQL', result.stderr)
        self.assert_unchanged()

    def test_failed_backup_prevents_checkout(self):
        result = self.deploy(TEST_DUMP_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assert_unchanged()
        self.assertEqual(list(self.backups.glob('*.sql')), [])

    def test_failed_startup_keeps_backup_without_automatic_database_rollback(self):
        result = self.deploy(TEST_UP_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Inspect before rolling back', result.stderr)
        self.assertEqual(len(list(self.backups.glob('*.sql'))), 1)
        self.assertEqual(self.git(self.checkout, 'rev-parse', 'HEAD').strip(), self.revision)

    def test_revision_outside_master_is_rejected(self):
        self.run_command('git', '-C', str(self.origin), 'checkout', '-b', 'unreviewed')
        (self.origin / 'unreviewed').write_text('not master')
        self.run_command('git', '-C', str(self.origin), 'add', '.')
        self.run_command('git', '-C', str(self.origin), 'commit', '-m', 'unreviewed')
        self.revision = self.git(self.origin, 'rev-parse', 'HEAD').strip()
        self.assertNotEqual(self.deploy().returncode, 0)
        self.assert_unchanged()


if __name__ == '__main__':
    unittest.main()
