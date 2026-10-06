#!/usr/bin/env python3
"""Host-only D4 acceptance oracle. No hardware, signing, activation or network.
Usage: verify-d4-acceptance.py pinned-googletest-checkout new-output-directory
The historical program is immutable evidence, never the repaired contract oracle.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
HISTORICAL_SHA = 'fbc9b58efd78c891c7bd0a82617e1dce7e880641f97e47457619ab70feb118a8'
REQUIRED_CASE = 'ExhaustSpaceARBeforeATThenReuseAndDeliverOldCompletion'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    gtest, output = map(lambda p: Path(p).resolve(), sys.argv[1:])
    if output == ROOT or ROOT in output.parents:
        raise SystemExit('Output must be a fresh directory outside the checkout')
    output.mkdir(parents=True, exist_ok=False)
    receipt = {'result': 'FAIL', 'historical_classification': 'NOT_RUN', 'runs': []}
    env = os.environ.copy()
    env.update(DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',
               CLANG_MODULE_CACHE_PATH=str(output/'module-cache'),
               ASAN_OPTIONS='abort_on_error=1:halt_on_error=1:detect_stack_use_after_return=1',
               UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
    # An inherited filter or repetition count must not turn acceptance into an empty run.
    for name in list(env):
        if name.startswith('GTEST_'):
            del env[name]
    def run(name, argv):
        with (output/(name+'.log')).open('w') as log:
            result = subprocess.run(argv, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
        receipt['runs'].append({'name': name, 'argv': argv, 'exit': result.returncode})
        return result.returncode
    try:
        pin = subprocess.check_output(['git', '-C', str(gtest), 'rev-parse', 'HEAD'], text=True).strip()
        if pin != '6910c9d9165801d8827d628cb72eb7ea9dd538c5':
            raise RuntimeError('Unapproved googletest revision')
        fixture = ROOT/'tests/async/fixtures/D4HistoricalOracle.cpp'
        if digest(fixture) != HISTORICAL_SHA:
            raise RuntimeError('Historical fixture changed')
        receipt['historical_sha256'] = HISTORICAL_SHA
        receipt['source_commit'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        receipt['source_overlay'] = subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True)
        # Hash production inputs, including header-only Tracking/completion behavior.
        inputs = [*ROOT.glob('ASFWDriver/Async/**/*.hpp'), *ROOT.glob('ASFWDriver/Async/**/*.cpp'),
                  ROOT/'tests/async/OperationLifetimeTests.cpp', fixture, Path(__file__).resolve()]
        receipt['input_sha256'] = {str(p.relative_to(ROOT)): digest(p) for p in inputs}
        flags = ['xcrun', 'clang++', '-std=c++23', '-DASFW_HOST_TEST', '-g',
                 '-fsanitize=address,undefined', '-fno-sanitize-recover=all', '-fno-omit-frame-pointer',
                 '-Wno-character-conversion', '-Wno-deprecated-copy']
        for inc in ['tests/mocks', 'tests/support', '.', 'ASFWDriver', 'ASFWDriver/Async',
                    'ASFWDriver/Core', 'ASFWDriver/Bus', 'ASFWDriver/Logging',
                    'ASFWDriver/Hardware', 'ASFWDriver/Testing', 'ASFWDriver/Discovery',
                    'docs', 'AppleHeaders', str(gtest/'googletest/include'), str(gtest/'googletest')]:
            flags.append('-I'+inc)
        common = ['ASFWDriver/Async/Core/Transaction.cpp', 'ASFWDriver/Async/Core/TransactionManager.cpp',
                  'ASFWDriver/Async/Track/LabelAllocator.cpp', 'ASFWDriver/Async/Track/PayloadRegistry.cpp',
                  'ASFWDriver/Shared/Memory/PayloadHandle.cpp', 'tests/support/SanitizerDefaults.cpp',
                  'tests/support/LoggingStubs.cpp', 'ASFWDriver/Logging/LogRing.cpp', '-pthread']
        if run('historical-build', flags+[str(fixture)]+common+['-o', str(output/'historical')]):
            raise RuntimeError('Historical compilation failed')
        historical_exit = run('historical', [str(output/'historical')])
        if historical_exit != 4:
            raise RuntimeError('Historical oracle mismatch changed; requires review, never auto-accept')
        receipt['historical_classification'] = 'EXPECTED_HISTORICAL_ORACLE_MISMATCH'
        if run('strengthened-build', flags+['tests/async/OperationLifetimeTests.cpp']+common+
               [str(gtest/'googletest/src/gtest-all.cc'), str(gtest/'googletest/src/gtest_main.cc'),
                '-o', str(output/'strengthened')]):
            raise RuntimeError('Strengthened compilation failed')
        xml = output/'strengthened.xml'
        code = run('strengthened', [str(output/'strengthened'), '--gtest_filter=*', '--gtest_repeat=1',
                                   '--gtest_output=xml:'+str(xml)])
        if code:
            raise RuntimeError('Production identity/retirement contract failed')
        cases = ET.parse(xml).getroot().findall('.//testcase')
        if len(cases) < 17 or any(c.get('status') != 'run' or c.get('result') != 'completed' or
                                  c.find('failure') is not None or c.find('skipped') is not None for c in cases):
            raise RuntimeError('Missing, skipped or failing strengthened coverage')
        if not any(c.get('classname') == 'Lifetime' and c.get('name') == REQUIRED_CASE for c in cases):
            raise RuntimeError('Six-step stale-completion oracle did not execute')
        if any(digest(ROOT/p) != h for p, h in receipt['input_sha256'].items()):
            raise RuntimeError('Inputs changed while acceptance ran')
        receipt.update(result='PASS', strengthened_cases=len(cases),
                       authoritative_oracle='Lifetime.'+REQUIRED_CASE,
                       production_contract='No premature label reuse; distinct host identity; stale completion harmless; valid new completion succeeds')
    except Exception as error:
        receipt['error'] = str(error)
    finally:
        (output/'acceptance.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print(json.dumps({k: receipt[k] for k in ['result', 'historical_classification']}))
    return 0 if receipt['result'] == 'PASS' else 1

if __name__ == '__main__':
    sys.exit(main())
