"""Windows integration tests. Standard library only; no GPU, model, or npm needed."""
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 aktsmm
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1]
PWSH = shutil.which('pwsh')
MOCK_SERVER = '''import argparse,json,os,time
from http.server import HTTPServer,BaseHTTPRequestHandler
p=argparse.ArgumentParser();p.add_argument('--config');p.add_argument('--port',type=int);p.add_argument('--host');p.add_argument('--engine');a=p.parse_args()
c=json.load(open(a.config,encoding='utf-8-sig'))
with open(c['starts'],'a',encoding='utf-8') as f:f.write(str(os.getpid())+'\\n')
if c.get('behavior')=='exit':raise SystemExit(7)
if c.get('behavior')=='timeout':time.sleep(15)
time.sleep(c.get('delay',0))
class H(BaseHTTPRequestHandler):
 def do_GET(self):
  body=json.dumps({'status':'ok','service':c.get('service','strata'),'model':c['model_name'],'loaded':False,'api_key':c.get('auth',False),'max_context':65536}).encode()
  self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
 def log_message(self,*a):pass
s=HTTPServer((a.host,a.port),H)
print('MOCK_READY',flush=True)
s.serve_forever()
'''
MOCK_CODEX = '''import json,os,sys
from pathlib import Path
Path(os.environ['CODEX_STRATA_TEST_RECEIPT']).write_text(json.dumps({'args':sys.argv[1:],'codex_home':os.environ.get('CODEX_HOME')}),encoding='utf-8')
raise SystemExit(int(os.environ.get('CODEX_STRATA_TEST_EXIT','0')))
'''


@unittest.skipUnless(os.name == 'nt' and PWSH, 'Windows and PowerShell 7 required')
class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='codex strata tests ')
        self.root = Path(self.temp.name)
        self.strata = self.root / 'Strata with spaces'
        (self.strata / 'serve').mkdir(parents=True)
        (self.strata / 'serve' / 'server.py').write_text(MOCK_SERVER, encoding='utf-8')
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            self.port = sock.getsockname()[1]
        self.starts = self.root / 'starts.txt'
        self.engine_path = self.strata / 'engine.json'
        self.engine = {'model_name': 'local-test-model', 'port': self.port,
                       'args': ['--max-context', '65536'], 'starts': str(self.starts)}
        self.fake_codex = self.root / 'fake codex.cmd'
        self.fake_code = self.root / 'fake codex.py'
        self.fake_code.write_text(MOCK_CODEX, encoding='utf-8')
        self.fake_codex.write_text(f'@echo off\r\n"{sys.executable}" -I -B "{self.fake_code}" %*\r\nexit /b %errorlevel%\r\n', encoding='utf-8')
        self.receipt = self.root / 'receipt.json'
        self.settings_path = self.root / 'settings.json'
        self.settings = {'strata_root': str(self.strata), 'engine_config': 'engine.json',
                         'python_path': sys._base_executable, 'codex_command': sys._base_executable,
                         'codex_args_prefix': ['-I', '-B', str(self.fake_code)],
                         'codex_home': str(self.root / 'isolated codex home'),
                         'logs_dir': str(self.root / 'logs'), 'startup_timeout_seconds': 10}
        self.env = {**os.environ, 'CODEX_STRATA_CONFIG': str(self.settings_path),
                    'CODEX_STRATA_TEST_RECEIPT': str(self.receipt)}
        self.external = []
        self.write_configs()

    def write_configs(self):
        self.engine_path.write_text(json.dumps(self.engine), encoding='utf-8')
        self.settings_path.write_text(json.dumps(self.settings), encoding='utf-8')

    def run_launcher(self, *args, shim=False):
        command = [str(SOURCE / 'codex-strata.cmd')] if shim else [PWSH, '-NoProfile', '-File', str(SOURCE / 'codex-strata.ps1')]
        return subprocess.run(command + list(args), env=self.env, capture_output=True,
                              text=True, encoding='utf-8', errors='replace', timeout=35)

    def start_mock(self):
        process = subprocess.Popen([sys._base_executable, '-I', '-B', str(self.strata / 'serve' / 'server.py'),
                                    '--config', str(self.engine_path), '--port', str(self.port),
                                    '--host', '127.0.0.1', '--engine', 'strata'],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.external.append(process)
        self.assertEqual(process.stdout.readline().strip(), 'MOCK_READY')
        return process

    def tearDown(self):
        # These PIDs are fixtures written by our mock server, never production processes.
        if self.starts.exists():
            for pid in self.starts.read_text().splitlines():
                root_literal = str(self.root).replace("'", "''")
                cleanup = f"$p=Get-Process -Id {int(pid)} -ErrorAction SilentlyContinue; if($p){{$null=$p.Handle; $c=Get-CimInstance Win32_Process -Filter 'ProcessId={int(pid)}'; if($c -and $c.Name -eq 'python.exe' -and $c.CommandLine.Contains('{root_literal}')){{$p.Kill(); $null=$p.WaitForExit(5000)}}}}"
                subprocess.run([PWSH, '-NoProfile', '-Command', cleanup], capture_output=True, timeout=15)
        for process in self.external:
            process.wait(timeout=10)
            process.stdout.close()
            process.stderr.close()
        # Verify the recursive cleanup target and allow Windows to release file
        # handles after terminating the fixture. The venv launcher is not used
        # for mock servers, so no parent stub retains their working directory.
        self.assertEqual(self.root.resolve().parent, Path(tempfile.gettempdir()).resolve())
        self.assertTrue(self.root.name.startswith('codex strata tests '))
        try:
            self.temp.cleanup()
        except PermissionError:
            time.sleep(0.5)
            self.temp.cleanup()

    def test_auto_start_and_reuse_with_spaces_and_arguments(self):
        result = self.run_launcher('exec', '--skip-git-repo-check', 'a prompt with spaces')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Ready', result.stdout)
        receipt = json.loads(self.receipt.read_text())
        self.assertEqual(receipt['args'][-3:], ['exec', '--skip-git-repo-check', 'a prompt with spaces'])
        self.assertIn('model_context_window=65536', receipt['args'])
        self.assertEqual(receipt['codex_home'], self.settings['codex_home'])
        first_pids = self.starts.read_text()
        again = self.run_launcher('exec', '--help', shim=True)
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertIn('Reusing', again.stdout)
        self.assertEqual(first_pids, self.starts.read_text())
        catalog = json.loads((Path(self.settings['codex_home']) / 'codex-strata-models.json').read_text())
        self.assertEqual(catalog['models'][0]['slug'], 'local-test-model')

    def test_concurrent_launchers_start_only_one_server(self):
        self.engine['delay'] = 1
        self.write_configs()
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            results = list(pool.map(lambda _: self.run_launcher('exec', '--help'), range(2)))
        for result in results:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.starts.read_text().splitlines()), 1)

    def test_wrong_service_is_not_replaced(self):
        self.engine['service'] = 'another-application'
        self.write_configs()
        self.start_mock()
        result = self.run_launcher('exec', '--help')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not a healthy Strata server', result.stderr)
        self.assertFalse(self.receipt.exists())
        self.assertEqual(len(self.starts.read_text().splitlines()), 1)

    def test_wrong_model_is_not_replaced(self):
        self.start_mock()
        self.engine['model_name'] = 'different-model'
        self.write_configs()
        result = self.run_launcher('exec', '--help')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('expected', result.stderr)
        self.assertFalse(self.receipt.exists())

    def test_auth_key_is_referenced_but_never_forwarded(self):
        self.engine['auth'] = True
        self.settings['api_key_env'] = 'LOCAL_MODEL_TEST_KEY'
        self.env['LOCAL_MODEL_TEST_KEY'] = 'fixture-secret-do-not-log'
        self.write_configs()
        self.start_mock()
        result = self.run_launcher('exec', '--help')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        receipt = self.receipt.read_text()
        self.assertIn('model_providers.strata.env_key=LOCAL_MODEL_TEST_KEY', receipt)
        self.assertNotIn(self.env['LOCAL_MODEL_TEST_KEY'], receipt + result.stdout + result.stderr)

    def test_missing_auth_key_blocks_codex(self):
        self.engine['auth'] = True
        self.write_configs()
        self.start_mock()
        result = self.run_launcher('exec', '--help')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('requires authentication', result.stderr)
        self.assertFalse(self.receipt.exists())

    def test_startup_crash_reports_logs_and_blocks_codex(self):
        self.engine['behavior'] = 'exit'
        self.write_configs()
        result = self.run_launcher('exec', '--help')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('exited before becoming ready', result.stderr)
        self.assertIn('Startup log:', result.stderr)
        self.assertFalse(self.receipt.exists())

    def test_timeout_leaves_starting_server_running(self):
        self.engine['behavior'] = 'timeout'
        self.settings['startup_timeout_seconds'] = 1
        self.write_configs()
        result = self.run_launcher('exec', '--help')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('left running', result.stderr)
        self.assertFalse(self.receipt.exists())
        pid = self.starts.read_text().strip()
        listing = subprocess.run(['tasklist.exe', '/FI', f'PID eq {pid}', '/FO', 'CSV'], capture_output=True, text=True)
        self.assertIn(pid, listing.stdout)

    def test_global_help_and_version_do_not_start_server(self):
        for argument in ('--help', '--version'):
            result = self.run_launcher(argument, shim=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.starts.exists())
        self.assertFalse(Path(self.settings['codex_home']).exists())

    def test_codex_exit_code_is_preserved(self):
        self.env['CODEX_STRATA_TEST_EXIT'] = '23'
        self.start_mock()
        result = self.run_launcher('exec', '--help')
        self.assertEqual(result.returncode, 23)

    def test_invalid_config_is_rejected(self):
        self.settings['port'] = 0
        self.write_configs()
        result = self.run_launcher('exec', '--help')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('port must be', result.stderr)
        self.assertFalse(self.starts.exists())

    def test_quoted_arguments_are_preserved(self):
        self.start_mock()
        prompt = 'Explain the function named "parse_input".'
        override = 'custom={label="two words"}'
        result = self.run_launcher('exec', '-c', override, prompt)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        receipt = json.loads(self.receipt.read_text())
        self.assertEqual(receipt['args'][-4:], ['exec', '-c', override, prompt])

    def test_shell_characters_are_literal(self):
        self.start_mock()
        self.env['CODEX_STRATA_TEST_LITERAL'] = 'unexpected-expansion'
        prompt = 'Explain "A&B" and %CODEX_STRATA_TEST_LITERAL% exactly.'
        result = self.run_launcher('exec', prompt)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        receipt = json.loads(self.receipt.read_text())
        self.assertEqual(receipt['args'][-2:], ['exec', prompt])

    def test_unknown_batch_launcher_is_rejected_before_start(self):
        self.settings['codex_command'] = str(self.fake_codex)
        self.settings['codex_args_prefix'] = []
        self.write_configs()
        result = self.run_launcher('exec', 'a prompt')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Custom batch launchers', result.stderr)
        self.assertFalse(self.starts.exists())

    def test_occupied_port_without_health_is_not_replaced(self):
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', self.port))
            sock.listen()
            result = self.run_launcher('exec', '--help')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('occupied', result.stderr)
        self.assertFalse(self.starts.exists())

    def test_install_and_update_preserve_settings_and_make_backup(self):
        venv = self.strata / '.venv' / 'Scripts'
        venv.mkdir(parents=True)
        (venv / 'python.exe').write_bytes(b'fixture; not executed')
        destination = self.root / 'installed launcher'
        command = [PWSH, '-NoProfile', '-File', str(SOURCE / 'install.ps1'),
                   '-StrataRoot', str(self.strata), '-EngineConfig', 'engine.json',
                   '-InstallDir', str(destination)]
        first = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=15)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertTrue((destination / 'start-server.py').is_file())
        self.assertTrue((destination / 'NOTICE').is_file())
        self.assertTrue((destination / 'docs' / 'licenses' / 'Strata-MIT.txt').is_file())
        local_settings = destination / 'settings.json'
        customized = json.loads(local_settings.read_text(encoding='utf-8-sig'))
        customized['startup_timeout_seconds'] = 42
        local_settings.write_text(json.dumps(customized), encoding='utf-8')
        before = local_settings.read_bytes()
        refused = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=15)
        self.assertNotEqual(refused.returncode, 0)
        updated = subprocess.run(command + ['-Force'], capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=15)
        self.assertEqual(updated.returncode, 0, updated.stdout + updated.stderr)
        self.assertEqual(local_settings.read_bytes(), before)
        self.assertTrue(list((destination / 'backups').glob('*/codex-strata.ps1')))


if __name__ == '__main__':
    unittest.main(verbosity=2)
