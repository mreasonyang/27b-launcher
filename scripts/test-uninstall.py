#!/usr/bin/env python3
"""Run the uninstaller against isolated fixtures with mocked OS side effects."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('uninstall.sh').read_text()

class UninstallContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='27b-uninstall-test-')
        self.root = Path(self.temp.name)
        self.fixture = self.root / 'fixture-user'
        self.fixture.mkdir()
        self.support = self.fixture / 'Library/Application Support/Bonsai2'
        self.support.mkdir(parents=True)
        (self.support / 'model').write_bytes(b'model-fixture')
        self.preferences = self.fixture / 'Library/Preferences/com.zenxiv.Launcher27B.plist'
        self.preferences.parent.mkdir(parents=True)
        self.preferences.write_text('fixture')
        self.log = self.root / 'calls'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for command, body in {
            'defaults': 'printf "defaults %s\\n" "$*" >> "$TEST_LOG"',
            'security': 'printf "security %s\\n" "$*" >> "$TEST_LOG"',
            'sfltool': 'exit 0',
            'ps': 'printf "%s\\n" "${TEST_PROCESSES:-}"',
        }.items():
            p = self.bin / command
            p.write_text('#!/bin/sh\n' + body + '\n')
            p.chmod(0o755)
        # Substitute only the home locator in the disposable script. The parent
        # process and child HOME are untouched; no real user path is a target.
        self.script = self.root / 'uninstall.sh'
        self.script.write_text(SCRIPT.replace('HOME_DIR="${HOME:-}"', 'HOME_DIR="$TEST_ROOT"'))
        self.env = dict(os.environ, TEST_ROOT=str(self.fixture), TEST_LOG=str(self.log), PATH=str(self.bin) + ':/usr/bin:/bin:/usr/sbin:/sbin', SFLTOOL_TIMEOUT_SECONDS='1')

    def tearDown(self):
        self.temp.cleanup()

    def run_script(self, *args):
        return subprocess.run(['/bin/sh', str(self.script), '--keep-app', *args], env=self.env, capture_output=True, text=True, timeout=8)

    def test_dry_run_never_mutates(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.support.exists())
        self.assertTrue(self.preferences.exists())
        self.assertFalse(self.log.exists())

    def test_keep_preferences_preserves_defaults_and_keychain(self):
        result = self.run_script('--yes', '--keep-preferences')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.preferences.exists())
        self.assertFalse(self.support.exists())
        self.assertFalse(self.log.exists())

    def test_full_removal_targets_only_current_credential(self):
        result = self.run_script('--yes')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text()
        self.assertIn('defaults delete com.zenxiv.Launcher27B', calls)
        self.assertIn('security delete-generic-password -s com.zenxiv.Launcher27B -a llama-server-api-key', calls)
        self.assertNotIn('com.example', calls)
        self.assertFalse(self.support.exists())
        self.assertFalse(self.preferences.exists())

    def test_current_runtime_path_blocks_deletion(self):
        runtime = self.support / 'runtime/mac/llama-server'
        self.env['TEST_PROCESSES'] = '2147483646 ' + str(runtime)
        result = self.run_script('--yes')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('still running', result.stderr)
        self.assertTrue(self.support.exists())
        self.assertFalse(self.log.exists())

    def test_similar_path_is_not_treated_as_owned(self):
        self.env['TEST_PROCESSES'] = '2147483646 ' + str(self.support / 'runtime/mac/llama-server-other')
        result = self.run_script('--yes', '--keep-preferences')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_external_models_are_reported_and_preserved(self):
        external = self.root / 'external-models'
        external.mkdir()
        (external / 'model').write_bytes(b'keep')
        (self.support / 'model-location.json').write_text(json.dumps({'path': str(external)}))
        result = self.run_script('--yes')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(external), result.stderr)
        self.assertEqual((external / 'model').read_bytes(), b'keep')

if __name__ == '__main__':
    unittest.main(verbosity=2)
