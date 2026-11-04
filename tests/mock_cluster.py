#!/usr/bin/env python3
"""Deterministic CLI doubles. Never contacts a cluster or network."""
import json
import os
from pathlib import Path
import signal
import sys
import yaml

state_path = Path(os.environ['MOCK_STATE'])
state = json.loads(state_path.read_text())
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with Path(os.environ['MOCK_TRACE']).open('a') as trace:
    trace.write(json.dumps([tool, *args]) + '\n')


def save():
    state_path.write_text(json.dumps(state))


def emit(obj):
    if obj is not None:
        print(json.dumps(obj))
    sys.exit(0)


def fail(message='mock operation failed'):
    print(message, file=sys.stderr)
    sys.exit(1)


def option(name, default=None):
    for index, arg in enumerate(args):
        if arg == name:
            return args[index + 1]
        if arg.startswith(name + '='):
            return arg.split('=', 1)[1]
    return default


def clean_argv():
    output = []
    skip = False
    for arg in args:
        if skip:
            skip = False
            continue
        if arg in ('--context', '--request-timeout', '-n', '--namespace', '-o', '-l'):
            skip = True
        elif arg.startswith(('--context=', '--request-timeout=', '--resource-version=')):
            continue
        elif arg == '-A':
            continue
        else:
            output.append(arg)
    return output


def read_manifest():
    return yaml.safe_load(Path(option('-f')).read_text())


def clean_hpa(hpa):
    return hpa


def merge(target, patch):
    for key, value in patch.items():
        if value is None:
            target.pop(key, None)
        elif isinstance(value, dict):
            merge(target.setdefault(key, {}), value)
        else:
            target[key] = value


def patch_json(target, patch):
    for op in patch:
        keys = [k.replace('~1', '/').replace('~0', '~') for k in op['path'].split('/')[1:]]
        parent = target
        for key in keys[:-1]:
            parent = parent[key]
        key = keys[-1]
        if op['op'] == 'test':
            if parent.get(key) != op['value']:
                fail('JSON Patch precondition failed')
        elif op['op'] in ('add', 'replace'):
            parent[key] = op['value']
        elif op['op'] == 'remove':
            if key not in parent:
                fail('missing JSON Patch path')
            del parent[key]


def sample(value, labels=None):
    return {'metric': labels or {}, 'value': [1793750400, str(value)]}


def response(samples):
    emit({'status': 'success', 'data': {'resultType': 'vector', 'result': samples}})


if tool == 'helm':
    if 'version' in args:
        print('v3.16.0')
    elif 'search' in args:
        print('[{"name":"kedacore/keda","version":"2.19.0","app_version":"2.19.0"}]')
    elif 'upgrade' in args:
        state['crd'] = True
        save()
    elif 'show' in args:
        print('appVersion: 2.19.0')
    sys.exit(0)

if tool == 'curl':
    query = option('--data-urlencode')
    if query:
        query = query.removeprefix('query=')
        if query == 'vector(1)':
            response([sample(1)])
        if query.startswith('nginx_ingress_controller_requests{'):
            labels = {'service': 'orders-api', 'exported_namespace': 'dev',
                      'namespace': 'ingress-space', 'path': '/', 'controller_namespace': 'ingress-space'}
            if state.get('labels_native'):
                labels['namespace'] = labels.pop('exported_namespace')
            if state.get('no_path'):
                labels.pop('path')
            if state.get('wrong_service'):
                labels['service'] = 'other'
            if state.get('exported_service'):
                labels['exported_service'] = labels['service']
                labels['service'] = 'controller-metrics'
            response([] if state.get('missing_metrics') else [sample(100, labels)])
        if query.startswith('kube_deployment_spec_replicas{'):
            response([] if state.get('missing_ksm') else [sample(state['deployment']['spec']['replicas'],
                     {'namespace': 'dev', 'deployment': 'orders-api'})])
        if query.startswith('max(kube_deployment_spec_replicas{'):
            response([sample(state['deployment']['spec']['replicas'])])
        if query.startswith('sum(increase('):
            if state.get('empty_increase'):
                response([])
            value = state.get('hits', 0)
            if ' * on() (' in query and state['deployment']['spec']['replicas'] == 0:
                value = 0
            response([sample(value)])
        fail('Unhandled PromQL: ' + query)
    state['hits'] = state.get('hits', 0) + 1
    if state['hits'] >= 3:
        state['deployment']['spec']['replicas'] = 1
        state['deployment']['status'].update(replicas=1, readyReplicas=1)
    save()
    print('503', end='')
    sys.exit(0)

if tool != 'kubectl':
    fail('Unexpected executable: ' + tool)
clean = clean_argv()
verb = clean[0]
if clean[:2] == ['config', 'current-context']:
    print(state.get('context', 'kind-dev'))
    sys.exit(0)
if verb == 'version':
    emit({'clientVersion': {'major': '1', 'minor': '27'}})
if verb == 'port-forward':
    print('Forwarding from 127.0.0.1:38765 -> 9090', flush=True)
    signal.pause()
    sys.exit(0)
if verb in ('wait', 'rollout'):
    if state.get('fail_wait'):
        fail('simulated readiness timeout')
    sys.exit(0)
if verb == 'get':
    resource = clean[1]
    name = clean[2] if len(clean) > 2 and not clean[2].startswith('-') else ''
    if resource == 'namespace':
        emit({'metadata': {'name': name, 'labels': state.get('namespace_labels', {})}})
    if resource == 'pods':
        emit({'items': [{'metadata': {'namespace': 'ingress-space'},
                       'spec': {'containers': [{'image': 'registry.k8s.io/ingress-nginx/controller:v1.12.0'}]}}]})
    if resource == 'deployment':
        emit(state['deployment'])
    if resource == 'deployments':
        emit({'items': [{'metadata': {'namespace': 'keda', 'name': 'custom-keda-operator'}}]})
    if resource == 'crd':
        emit({'spec': {'versions': [{'served': True, 'schema': {'openAPIV3Schema': {'properties':
            {'spec': {'properties': {'initialCooldownPeriod': {}}}}}}}]}} if state['crd'] else None)
    if resource == 'configmap':
        emit(state.get('configmap'))
    if resource == 'scaledobject':
        emit(state.get('scaledobject'))
    if resource == 'scaledobjects':
        emit({'items': [state['scaledobject']] if state.get('scaledobject') else []})
    if resource == 'hpa':
        emit(state['hpas'].get(name) if name else {'items': list(state['hpas'].values())})
    if resource == 'service':
        emit({'spec': {'selector': {'app': 'orders-api'}}})
    if resource == 'ingress':
        emit({'items': [{'metadata': {'name': 'orders'}, 'spec': {'ingressClassName': 'nginx',
            'rules': [{'host': 'orders.example.test', 'http': {'paths': [{'path': '/', 'pathType': 'Prefix',
                'backend': {'service': {'name': 'orders-api', 'port': {'number': 80}}}}]}}]}}]})
    if resource == 'ingressclass':
        emit({'items': [{'metadata': {'name': 'nginx'}, 'spec': {'controller': 'k8s.io/ingress-nginx'}}]})
    fail('Unhandled get: ' + str(clean))
if verb in ('create', 'replace', 'apply'):
    manifest = read_manifest()
    if state.get('fail_apply') and manifest['kind'] == 'ScaledObject':
        fail('simulated admission failure')
    if manifest['kind'] == 'ConfigMap':
        manifest['metadata']['resourceVersion'] = '1'
        state['configmap'] = manifest
    elif manifest['kind'] == 'ScaledObject':
        manifest['metadata'].update(uid='scaled-uid', creationTimestamp='2026-11-04T00:00:00Z')
        manifest['status'] = {'hpaName': 'keda-custom-hpa', 'lastActiveTime': '2026-11-04T00:00:00Z',
            'conditions': [{'type': 'Ready', 'status': 'True'}, {'type': 'Active', 'status': 'False'}]}
        state['scaledobject'] = manifest
        state['hpas']['keda-custom-hpa'] = {'metadata': {'name': 'keda-custom-hpa', 'uid': 'hpa-keda',
            'ownerReferences': [{'uid': 'scaled-uid'}]}, 'spec': {'scaleTargetRef':
                {'name': 'orders-api', 'kind': 'Deployment', 'apiVersion': 'apps/v1'}}}
    elif manifest['kind'] == 'HorizontalPodAutoscaler':
        manifest['metadata']['uid'] = 'restored-uid'
        state['hpas'][manifest['metadata']['name']] = manifest
    else:
        fail('Unhandled manifest: ' + str(manifest))
elif verb == 'annotate':
    annotation = clean[3]
    annotations = state['deployment']['metadata'].setdefault('annotations', {})
    if annotation.endswith('-'):
        annotations.pop(annotation[:-1], None)
    else:
        key, value = annotation.split('=', 1)
        annotations[key] = value
elif verb == 'label':
    key, value = clean[3].split('=', 1)
    state['hpas'][clean[2]]['metadata'].setdefault('labels', {})[key] = value
elif verb == 'delete':
    kind, name = clean[1:3]
    if kind == 'hpa':
        state['hpas'].pop(name, None)
    elif kind == 'configmap':
        state.pop('configmap', None)
    elif kind == 'scaledobject':
        state.pop('scaledobject', None)
        state['hpas'].pop('keda-custom-hpa', None)
    else:
        fail('Unhandled delete')
elif verb == 'scale':
    state['deployment']['spec']['replicas'] = int(option('--replicas'))
elif verb == 'patch':
    target = state['scaledobject' if clean[1] == 'scaledobject' else 'configmap']
    if option('--type') == 'json':
        patch_json(target, json.loads(Path(option('--patch-file')).read_text()))
        if target.get('spec', {}).get('cooldownPeriod') == 60:
            state['test_started'] = True
            if not state.get('test_wait'):
                state['deployment']['spec']['replicas'] = 0
                state['deployment']['status'].update(replicas=0, readyReplicas=0)
    else:
        merge(target, json.loads(option('-p')))
else:
    fail('Unhandled kubectl: ' + str(clean))
save()
