#!/usr/bin/env python3
"""Offline behavioral tests; uses CLI doubles, no kubeconfig or network."""
import copy
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'sleep-mode.sh'
MOCK = Path(__file__).with_name('mock_cluster.py')
MUTATIONS = {'create', 'replace', 'apply', 'patch', 'annotate', 'scale', 'delete', 'label', 'upgrade'}
HPA = {'apiVersion': 'autoscaling/v2', 'kind': 'HorizontalPodAutoscaler',
       'metadata': {'name': 'old-hpa', 'namespace': 'dev', 'uid': 'original-hpa',
                    'resourceVersion': '42', 'creationTimestamp': '2026-10-01T00:00:00Z'},
       'spec': {'minReplicas': 2, 'maxReplicas': 5, 'scaleTargetRef':
                {'apiVersion': 'apps/v1', 'kind': 'Deployment', 'name': 'orders-api'}}}


class SleepModeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.bin = self.work / 'bin'
        self.bin.mkdir()
        for name in ('kubectl', 'helm', 'curl'):
            (self.bin / name).symlink_to(MOCK)
        self.state_file = self.work / 'state.json'
        self.trace_file = self.work / 'trace.jsonl'
        self.initial = {'crd': True, 'hpas': {}, 'deployment': {
            'metadata': {'name': 'orders-api', 'namespace': 'dev', 'uid': 'deployment-uid',
                         'resourceVersion': '7', 'generation': 1, 'annotations': {}},
            'spec': {'replicas': 2, 'template': {'metadata': {'labels': {'app': 'orders-api'}}}},
            'status': {'replicas': 2, 'readyReplicas': 2, 'observedGeneration': 1}}}
        self.write(self.initial)
        self.env = os.environ.copy()
        for key in ('NAMESPACE', 'DEPLOYMENT', 'SERVICE', 'PROMETHEUS_URL', 'IDLE_MINUTES',
                    'WAKE_HITS', 'MAX_REPLICAS', 'EXCLUDE_PATHS', 'THRESHOLD', 'APPLY',
                    'YES', 'FORCE', 'REPLACE_HPA', 'DRY_RUN', 'INGRESS_NAMESPACE',
                    'PROMETHEUS_SERVICE', 'PROMETHEUS_NAMESPACE', 'BACKUP_DIR', 'TEST_URL',
                    'KEDA_CHART_VERSION'):
            self.env.pop(key, None)
        self.env.update(PATH=f'{self.bin}:{self.env["PATH"]}', MOCK_STATE=str(self.state_file),
                        MOCK_TRACE=str(self.trace_file), NO_COLOR='1', KUBECONFIG='/nonexistent')

    def write(self, value):
        self.state_file.write_text(json.dumps(value))

    def state(self):
        return json.loads(self.state_file.read_text())

    def command(self, subcommand='enable', *flags):
        return [str(SCRIPT), subcommand, '-n', 'dev', '-d', 'orders-api',
                '--prometheus-url', 'http://prometheus.monitoring:9090',
                '--backup-dir', str(self.work / 'backups'), *flags]

    def call(self, *flags, subcommand='enable', success=True):
        result = subprocess.run(self.command(subcommand, *flags), env=self.env,
                                input='yes\n', text=True, capture_output=True, timeout=25)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stderr)
        return result

    def trace(self):
        return [json.loads(line) for line in self.trace_file.read_text().splitlines()]

    def mutations(self):
        return [line for line in self.trace() if any(arg in MUTATIONS for arg in line[1:])]

    def enable(self, *flags):
        return self.call('--apply', '--yes', *flags)

    def test_dry_run_emits_valid_yaml_and_changes_nothing(self):
        result = self.call()
        manifest = yaml.safe_load(result.stdout)
        self.assertEqual(manifest['spec']['cooldownPeriod'], 1800)
        self.assertEqual(manifest['spec']['minReplicaCount'], 0)
        self.assertEqual(manifest['spec']['maxReplicaCount'], 2)
        self.assertEqual(manifest['spec']['triggers'][0]['metadata']['activationThreshold'], '2')
        self.assertIn('exported_namespace="dev"', manifest['spec']['triggers'][0]['metadata']['query'])
        self.assertEqual(self.state(), self.initial)
        self.assertEqual(self.mutations(), [])
        self.assertFalse((self.work / 'backups').exists())

    def test_missing_crd_only_plans_install_in_dry_run(self):
        state = self.state(); state['crd'] = False; self.write(state)
        result = self.call()
        self.assertIn('PLAN: install KEDA', result.stderr)
        self.assertFalse(self.state()['crd'])
        self.assertEqual(self.mutations(), [])

    def test_missing_crd_installs_keda_on_apply(self):
        state = self.state(); state['crd'] = False; self.write(state)
        self.enable()
        self.assertTrue(self.state()['crd'])
        self.assertTrue(any(line[0] == 'helm' and 'upgrade' in line for line in self.trace()))

    def test_existing_crd_never_installs_or_upgrades_keda(self):
        self.enable()
        self.assertFalse(any(line[0] == 'helm' and 'upgrade' in line for line in self.trace()))

    def test_enable_is_idempotent_and_keeps_original_replicas(self):
        self.enable()
        state = self.state(); state['deployment']['spec']['replicas'] = 0; self.write(state)
        self.enable()
        state = self.state()
        self.assertEqual(state['deployment']['metadata']['annotations']['sleepmode/original-replicas'], '2')
        self.assertEqual(state['scaledobject']['spec']['maxReplicaCount'], 2)

    def test_hpa_conflict_fails_before_any_mutation(self):
        state = self.state(); state['hpas']['old-hpa'] = copy.deepcopy(HPA); self.write(state)
        self.call('--apply', '--yes', success=False)
        self.assertEqual(self.mutations(), [])

    def test_hpa_round_trip_and_second_disable(self):
        state = self.state(); state['hpas']['old-hpa'] = copy.deepcopy(HPA); self.write(state)
        self.enable('--replace-hpa')
        self.assertNotIn('old-hpa', self.state()['hpas'])
        self.assertTrue(list((self.work / 'backups').glob('*-hpas.json')))
        self.call('--apply', '--yes', subcommand='disable')
        state = self.state()
        self.assertEqual(state['hpas']['old-hpa']['spec'], HPA['spec'])
        self.assertEqual(state['deployment']['spec']['replicas'], 2)
        self.assertNotIn('sleepmode/original-replicas', state['deployment']['metadata']['annotations'])
        self.assertNotIn('configmap', state)
        before = len(self.mutations())
        self.call('--apply', '--yes', subcommand='disable')
        self.assertEqual(len(self.mutations()), before)

    def test_partial_enable_keeps_recovery_for_disable(self):
        state = self.state(); state['hpas']['old-hpa'] = copy.deepcopy(HPA)
        state['fail_apply'] = True; self.write(state)
        self.call('--apply', '--yes', '--replace-hpa', success=False)
        self.assertNotIn('old-hpa', self.state()['hpas'])
        self.assertIn('hpas.json', self.state()['configmap']['data'])
        self.call('--apply', '--yes', subcommand='disable')
        self.assertEqual(self.state()['hpas']['old-hpa']['spec'], HPA['spec'])

    def test_disable_cleans_owned_hpa_if_scaledobject_is_already_gone(self):
        self.enable()
        state = self.state(); state.pop('scaledobject'); self.write(state)
        self.call('--apply', '--yes', subcommand='disable')
        self.assertEqual(self.state()['hpas'], {})

    def test_disagreeing_replica_snapshots_are_refused(self):
        self.enable()
        state = self.state()
        state['deployment']['metadata']['annotations']['sleepmode/original-replicas'] = '99'
        self.write(state)
        result = self.call('--apply', '--yes', subcommand='disable', success=False)
        self.assertIn('disagrees with recovery state', result.stderr)
        self.assertIn('configmap', self.state())

    def test_recreated_deployment_cannot_inherit_old_recovery_state(self):
        self.enable()
        state = self.state(); state['deployment']['metadata']['uid'] = 'new-deployment'; self.write(state)
        result = self.call('--apply', '--yes', subcommand='disable', success=False)
        self.assertIn('another owner or Deployment UID', result.stderr)
        self.assertIn('configmap', self.state())

    def test_prod_context_is_refused(self):
        state = self.state(); state['context'] = 'corp-PRD'; self.write(state)
        self.call('--apply', '--yes', success=False)
        self.assertEqual(self.mutations(), [])

    def test_force_cannot_allow_prod_test(self):
        self.enable()
        state = self.state(); state['context'] = 'corp-live'; self.write(state)
        result = self.call('--apply', '--yes', '--force', subcommand='test', success=False)
        self.assertIn('even with --force', result.stderr)

    def test_protected_ingress_namespace(self):
        command = self.command('enable', '--apply', '--yes')
        command[command.index('dev')] = 'ingress-space'
        result = subprocess.run(command, env=self.env, text=True, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Protected ingress namespace', result.stderr)

    def test_path_label_is_required_when_excluding_paths(self):
        state = self.state(); state['no_path'] = True; self.write(state)
        self.call('--apply', '--yes', success=False)
        self.assertEqual(self.mutations(), [])
        result = self.call('--exclude-paths', '')
        self.assertNotIn('path!~', result.stdout)

    def test_native_namespace_and_exported_service_are_detected(self):
        state = self.state(); state['labels_native'] = True; state['exported_service'] = True; self.write(state)
        manifest = yaml.safe_load(self.call().stdout)
        query = manifest['spec']['triggers'][0]['metadata']['query']
        self.assertIn('namespace="dev"', query)
        self.assertIn('exported_service="orders-api"', query)

    def test_missing_metrics_or_ksm_fail_before_writes(self):
        for key in ('missing_metrics', 'missing_ksm', 'empty_increase'):
            with self.subTest(key=key):
                state = copy.deepcopy(self.initial); state[key] = True; self.write(state)
                self.call('--apply', '--yes', success=False)
                self.assertEqual(self.mutations(), [])

    def test_status_uses_stored_queries_and_never_mutates(self):
        self.enable()
        before = len(self.mutations())
        result = self.call('--apply', '--yes', subcommand='status')
        self.assertIn('Ready=True', result.stdout)
        self.assertIn('Estimated eligible requests', result.stdout)
        self.assertEqual(len(self.mutations()), before)

    def test_test_dry_run_sends_no_requests_and_patches_nothing(self):
        self.enable()
        before = len(self.mutations())
        result = self.call(subcommand='test')
        self.assertIn('cooldownPeriod: 60', result.stdout)
        self.assertEqual(self.state().get('hits', 0), 0)
        self.assertEqual(len(self.mutations()), before)

    def test_test_wakes_and_restores_real_cooldown(self):
        self.enable()
        result = self.call('--apply', '--yes', subcommand='test')
        state = self.state()
        self.assertEqual(state['hits'], 3)
        self.assertEqual(state['scaledobject']['spec']['cooldownPeriod'], 1800)
        self.assertEqual(state['scaledobject']['spec']['initialCooldownPeriod'], 1800)
        self.assertNotIn('test-restore.json', state['configmap']['data'])
        self.assertEqual(result.stderr.count('HTTP 503'), 3)
        self.assertIn('TEST PASSED', result.stderr)

    def test_signal_restores_cooldown_and_exits_nonzero(self):
        self.enable()
        state = self.state(); state['test_wait'] = True; self.write(state)
        with subprocess.Popen(self.command('test', '--apply', '--yes'), env=self.env,
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as proc:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if self.state().get('test_started'):
                    break
                time.sleep(0.05)
            else:
                proc.kill(); self.fail('Test never patched its cooldown')
            proc.send_signal(signal.SIGTERM)
            _, stderr = proc.communicate(timeout=10)
            self.assertNotEqual(proc.returncode, 0, stderr)
        self.assertEqual(self.state()['scaledobject']['spec']['cooldownPeriod'], 1800)
        self.assertNotIn('test-restore.json', self.state()['configmap']['data'])

    def test_env_fallbacks_and_quoted_regex(self):
        self.env.update(NAMESPACE='dev', DEPLOYMENT='orders-api',
                        PROMETHEUS_URL='http://prometheus.monitoring:9090',
                        IDLE_MINUTES='45', WAKE_HITS='4', MAX_REPLICAS='6',
                        EXCLUDE_PATHS='/a\\.b|/a"b')
        result = subprocess.run([str(SCRIPT), 'enable'], env=self.env, input='yes\n',
                                text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = yaml.safe_load(result.stdout)
        self.assertEqual(manifest['spec']['cooldownPeriod'], 2700)
        self.assertEqual(manifest['spec']['triggers'][0]['metadata']['activationThreshold'], '3')
        self.assertIn('path!~"/a\\\\.b|/a\\"b"', manifest['spec']['triggers'][0]['metadata']['query'])

    def test_invalid_inputs(self):
        for flag, value in (('--wake-hits', '0'), ('--idle-minutes', '-1'),
                            ('--max-replicas', 'nan'), ('--threshold', '1.5')):
            with self.subTest(flag=flag):
                self.call(flag, value, success=False)


if __name__ == '__main__':
    unittest.main(verbosity=2)
