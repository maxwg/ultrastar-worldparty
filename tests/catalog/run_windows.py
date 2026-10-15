"""Run the exact retained Windows suites in fresh scratch, with no real downloader.

Requires a configured MSVC x64 developer environment and explicit existing native
FFmpeg/ffprobe paths. No package installation, network lookup, or game launch.
"""
import argparse
from dataclasses import asdict
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import wave

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent

def sha(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()

def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='Owned scratch parent outside this repository; results are retained.')
    parser.add_argument('--cl', type=Path, required=True, help='Existing MSVC cl.exe; run from its configured developer environment.')
    parser.add_argument('--ffmpeg', type=Path, required=True)
    parser.add_argument('--ffprobe', type=Path, required=True)
    parser.add_argument('--suite', action='append', choices=('contract','launch','ownership','install','capture','accounting','stage','final','native'), help='Select specific suites; omitted means all. Selection is recorded in the receipt.')
    args = parser.parse_args()
    selected = args.suite or ['contract','launch','ownership','install','capture','accounting','stage','final','native']
    if os.name != 'nt':
        parser.error('This native suite requires Windows 10 or newer.')
    output = args.output.resolve()
    if output == REPO or output.is_relative_to(REPO):
        parser.error('Choose an output directory outside the source repository.')
    tools = {name:getattr(args,name).resolve(strict=True) for name in ('cl','ffmpeg','ffprobe')}
    if not all(path.is_file() and path.suffix.lower()=='.exe' for path in tools.values()):
        parser.error('Tool arguments must name existing .exe files.')
    retained_manifest_path = HERE/'retained-manifest.json'
    retained_manifest = json.loads(retained_manifest_path.read_text(encoding='utf-8-sig'))
    candidate_manifest_path = HERE/'current-candidate-manifest.json'
    candidate_manifest = json.loads(candidate_manifest_path.read_text(encoding='utf-8-sig'))
    for name, expected in candidate_manifest['backend_sha256'].items():
        if sha(REPO/'tools'/name) != expected:
            raise RuntimeError('Candidate backend hash mismatch: '+name)
    if sha(HERE/'test_contract.py') != candidate_manifest['test_contract_sha256']:
        raise RuntimeError('Current protocol contract-test hash mismatch.')
    if sha(retained_manifest_path) != candidate_manifest['retained_manifest_sha256']:
        raise RuntimeError('Historical retained-manifest hash mismatch.')
    for entry in retained_manifest['retained_test_sources']:
        if sha(HERE/'retained'/entry['path']) != entry['sha256']:
            raise RuntimeError('Retained fixture hash mismatch: '+entry['path'])
    output.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='catalog-offline-', dir=output))
    for name in candidate_manifest['backend_sha256']:
        shutil.copyfile(REPO/'tools'/name, work/name)
    for entry in retained_manifest['retained_test_sources']:
        target = work/entry['path']
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(HERE/'retained'/entry['path'], target)
    shutil.copyfile(HERE/'test_contract.py', work/'test_contract.py')
    shutil.copyfile(HERE/'test_launch_accounting.py', work/'test_launch_accounting.py')
    for name in ('test_installer_watchdog.py', 'test_outer_boundary_worker.py'):
        shutil.copyfile(HERE/name, work/name)
    # Independent historical helper is test-only supervision, never shipped.
    watchdog = load_module('catalog_test_watchdog', work/'before-repair-20261014/owned_process.py')
    owner = load_module('catalog_test_subject', work/'owned_process.py')
    receipt = {'schema_version':1,'started_utc':datetime.now(timezone.utc).isoformat(),
               'scope':'Offline synthetic fixtures only; no downloader, network, account, game or capture device.',
               'workspace':str(work),'python':sys.version,'python_executable':sys.executable,
               'backend_sha256':candidate_manifest['backend_sha256'],
               'candidate_manifest_sha256':sha(candidate_manifest_path),
               'retained_manifest_sha256':sha(retained_manifest_path),
               'test_contract_sha256':candidate_manifest['test_contract_sha256'],
               'steps':[], 'status':'incomplete',
               'selected_suites':selected,'suite_failures':[],
               'tool_files':{name:{'path':str(path),'sha256':sha(path)} for name,path in tools.items()},
               'real_600_second_timeout_rerun':False}
    def run(argv, label, timeout=120):
        print('STEP '+label, flush=True)
        result = watchdog.run_owned([str(arg) for arg in argv], cwd=str(work), timeout=timeout, stdout='inherit', cleanup_timeout=3)
        receipt['steps'].append({'name':label,'argv':[str(arg) for arg in argv], 'timeout_seconds':timeout,'result':asdict(result)})
        if result.reason!='exited' or result.returncode:
            raise RuntimeError(label+' failed: '+repr(result))
    try:
        for relative in ('catalog-tests/native_fixture.c','catalog-tests/native_fixture_repair.c','capture-tests/accounting-tests/burst_fixture.c'):
            source = work/relative
            run([tools['cl'],'/nologo','/W4','/WX','/O2','/MT','/DUNICODE','/D_UNICODE', '/Fe:'+str(source.with_suffix('.exe')), '/Fo:'+str(source.with_suffix('.obj')),source,'/link','/SUBSYSTEM:CONSOLE'], 'compile '+relative, 60)
        suites = [('contract','test_contract.py',['--backend',str(work)]),
                  ('launch','test_launch_accounting.py',['--backend',str(work),'--fixture',str(work/'catalog-tests/native_fixture_repair.exe'),'--output',str(work/'launch-regression')]),
                  ('ownership','test_owned_process_repaired.py',[]),
                  ('install','test_installer_watchdog.py',[]),
                  ('capture','capture-tests/test_capture.py',[]),
                  ('accounting','capture-tests/accounting-tests/test_accounting.py',[]),
                  ('stage','stage-tests/test_remove_stage_windows.py',[]),
                  ('final','stage-tests/test_final_cancel_windows.py',[])]
        for key, relative, extra in suites:
            if key not in selected:
                continue
            try:
                run([sys.executable,'-I','-S','-B',work/relative,*extra], relative)
            except RuntimeError as error:
                receipt['suite_failures'].append({'suite':key,'error':str(error)})
        if 'native' in selected:
            audio = work/'synthetic-200ms.wav'
            def native(argv, label):
                result = owner.run_owned([str(arg) for arg in argv], cwd=str(work), timeout=15, stdout='capture', cleanup_timeout=3,max_output_bytes=65536)
                receipt['steps'].append({'name':label,'argv':[str(arg) for arg in argv], 'result':asdict(result)})
                if result.reason!='exited' or result.returncode:
                    raise RuntimeError(label+' failed')
                return result
            native([tools['ffmpeg'],'-nostdin','-hide_banner','-loglevel','error','-f','lavfi','-i','sine=frequency=440:sample_rate=8000:duration=0.2','-t','0.2','-ac','1','-c:a','pcm_s16le','-f','wav','-n',audio], 'generate synthetic WAV')
            with wave.open(str(audio),'rb') as wav:
                duration=wav.getnframes()/wav.getframerate()
                if not 0 < duration <= 0.3:
                    raise RuntimeError('Unexpected synthetic duration')
            probe = native([tools['ffprobe'],'-v','error','-show_entries','stream=codec_type','-of','json',audio], 'probe synthetic WAV')
            if not any(stream.get('codec_type')=='audio' for stream in json.loads(probe.stdout).get('streams',[])):
                raise RuntimeError('Native probe did not identify synthetic audio')
            receipt['synthetic_audio']={'path':str(audio),'sha256':sha(audio),'duration_seconds':duration}
        receipt['status']='failed' if receipt['suite_failures'] else 'passed'
    except Exception as error:
        receipt['status']='failed'
        receipt['error']=str(error)
    finally:
        receipt['backend_unchanged']=all(sha(REPO/'tools'/name)==expected and sha(work/name)==expected for name,expected in candidate_manifest['backend_sha256'].items())
        receipt['retained_fixtures_unchanged']=all(sha(HERE/'retained'/entry['path'])==entry['sha256'] and sha(work/entry['path'])==entry['sha256'] for entry in retained_manifest['retained_test_sources'])
        receipt['test_contract_unchanged']=sha(HERE/'test_contract.py')==candidate_manifest['test_contract_sha256']
        receipt['retained_manifest_unchanged']=sha(retained_manifest_path)==candidate_manifest['retained_manifest_sha256']
        receipt['candidate_manifest_unchanged']=sha(candidate_manifest_path)==receipt['candidate_manifest_sha256']
        if not receipt['backend_unchanged'] or not receipt['retained_fixtures_unchanged'] or not receipt['test_contract_unchanged'] or not receipt['retained_manifest_unchanged'] or not receipt['candidate_manifest_unchanged']:
            receipt['status']='failed'
        receipt['finished_utc']=datetime.now(timezone.utc).isoformat()
        path=work/'integration-tests-receipt.json'
        path.write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
        print(json.dumps({'status':receipt['status'],'receipt':str(path),'error':receipt.get('error')}),flush=True)
    return 0 if receipt['status']=='passed' else 1

if __name__ == '__main__':
    raise SystemExit(main())
