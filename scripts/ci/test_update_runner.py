"""Exercise host update sequencing without touching a Docker daemon."""
import os
from pathlib import Path
import subprocess
import tempfile
from textwrap import dedent
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'update-runner.sh'


class RunnerUpdateTests(unittest.TestCase):
    def run_update(self, mode):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            checkout = root / 'checkout'
            checkout.mkdir()
            (checkout / 'docker/runner').mkdir(parents=True)
            (checkout / 'docker/runner/Dockerfile').write_text('FROM example:1\n')
            (checkout / 'docker-compose.runner.yml').write_text('name: damap-runner\n')
            for args in [
                ['init', '-q'], ['add', '.'],
                ['-c', 'commit.gpgsign=false', '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
                 'commit', '-qm', 'fixture'],
            ]:
                subprocess.run(['git', '-C', str(checkout), *args], check=True)

            binary = root / 'bin'
            binary.mkdir()
            docker = binary / 'docker'
            # Record Docker calls and simulate failures without a real daemon.
            # dedent keeps this fixture readable and the generated shebang at column 1.
            docker.write_text(dedent("""\
                #!/usr/bin/env python3
                import os
                import sys

                args = sys.argv[1:]
                with open(os.environ['CALLS'], 'a') as log:
                    log.write(' '.join(args) + '\\n')

                mode = os.environ['MODE']
                if args[0] == 'compose':
                    if 'ps' in args:
                        print('container-id')
                    elif 'build' in args and mode == 'build-fail':
                        sys.exit(1)
                    elif '--images' in args:
                        print('runner:2')
                elif args[0] == 'inspect':
                    print('sha256:old')
                elif args[:2] == ['image', 'inspect']:
                    print('sha256:old' if mode == 'current' else 'sha256:new')
                elif args[0] == 'wait' and mode == 'wait-fail':
                    sys.exit(1)
            """))
            docker.chmod(0o755)

            calls = root / 'calls'
            result = subprocess.run(
                ['bash', str(SCRIPT), str(checkout), str(root / 'runner.env')],
                env={**os.environ, 'PATH': f'{binary}:{os.environ["PATH"]}',
                     'MODE': mode, 'CALLS': str(calls)},
                capture_output=True, text=True,
            )
            return result, calls.read_text()

    def test_current_image_does_not_restart(self):
        result, calls = self.run_update('current')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('update --restart', calls)

    def test_build_failure_leaves_runner_alone(self):
        result, calls = self.run_update('build-fail')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('update --restart', calls)

    def test_wait_failure_restores_runner(self):
        result, calls = self.run_update('wait-fail')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('update --restart unless-stopped container-id', calls)
        self.assertIn('start container-id', calls)
        self.assertNotIn('up -d', calls)

    def test_recreate_only_after_natural_exit(self):
        result, calls = self.run_update('replace')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(calls.index('update --restart no'), calls.index('wait container-id'))
        self.assertLess(calls.index('wait container-id'), calls.index('up -d --no-build'))
        self.assertNotIn('stop ', calls)
        self.assertNotIn('kill ', calls)


if __name__ == '__main__':
    unittest.main()
