#!/usr/bin/env python3
"""Compare native helper scheduling with one binary/model at real-time pace.

Only the two/three-line CPU configuration differs. CPU energy is per-task
kernel attribution, not whole-machine battery consumption. Keep raw reports
and audio local. No parallel inference or builds during measurement.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import statistics
import subprocess


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--model', type=Path, required=True)
    p.add_argument('--terms', type=Path, required=True)
    p.add_argument('--input', type=Path, required=True)
    p.add_argument('--reference', type=Path)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--profiles', nargs='+', choices=['helpersBackground', 'helpersUtility', 'helpersDefault'],
                   default=['helpersBackground', 'helpersDefault', 'helpersBackground', 'helpersDefault'])
    args = p.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    modes = {}
    sleep = 'SessionConfig.session.intra_op.allow_spinning=0\nSessionConfig.session.inter_op.allow_spinning=0\n'
    for name, extra in [('helpersDefault', ''), ('helpersBackground', 'LectureLensWorkerQoS=background\n'), ('helpersUtility', 'LectureLensWorkerQoS=utility\n')]:
        model = args.out / name
        model.mkdir()
        for source in args.model.iterdir():
            if source.name != 'cpu-runtime.conf': (model / source.name).symlink_to(source.resolve())
        (model / 'cpu-runtime.conf').write_text(sleep + extra)
        modes[name] = model
    spec = importlib.util.spec_from_file_location('metrics', Path(__file__).with_name('vocabulary-metrics.py'))
    metrics = importlib.util.module_from_spec(spec); spec.loader.exec_module(metrics)
    reference = args.reference.read_text() if args.reference else None
    runs, transcripts, counts = [], [], {}
    for mode in args.profiles:
        counts[mode] = counts.get(mode, 0) + 1
        name = f'{mode}-{counts[mode]}'
        report = args.out / f'{name}.json'
        command = [str(args.binary.resolve()), '--benchmark', '--input', str(args.input.resolve()),
                   '--report', str(report.resolve()), '--model', str(modes[mode].resolve()),
                   '--terms', str(args.terms.resolve()), '--enhance', '--paths', '2', '--score', '0.5',
                   '--threads', '2', '--qos', 'background', '--provider', 'cpu']
        with (args.out / f'{name}.log').open('w') as log:
            completed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=1200)
        data = json.loads(report.read_text())
        if not data['enhancementActive'] or data.get('cpuWaitingMode') != 'sleep':
            raise RuntimeError(f'{name}: incorrect native configuration')
        accuracy = metrics.metrics(reference, data) if reference is not None else None
        runtime_ok = not data['errors'] and (completed.returncode == 0 or (reference is None and not data['sampleCount'] and completed.returncode == 1))
        run = {'name':name, 'profile':mode, 'accepted': runtime_ok and data['overThreeSeconds'] == 0 and (accuracy or {}).get('correctSpellingOverThree', 0) == 0,
               'runtimeErrors':data['errors'], 'sampleCount':data['sampleCount'],
               'cpuSeconds':data['activeCPUSeconds'], 'wallSeconds':data['activeWallSeconds'],
               'cpuEnergyNanojoules':data.get('activeCPUEnergyNanojoules'),
               'performanceCoreFraction':data.get('activePerformanceCoreFraction'),
               'interruptWakeups':data.get('activeInterruptWakeups'),
               'maximumSeconds':data['maximumSeconds'], 'overThree':data['overThreeSeconds'],
               'maximumQueueSeconds':data['maximumQueueWaitSeconds'], 'maximumProcessingSeconds':data['maximumProcessingSeconds']}
        if accuracy is not None: run['accuracy'] = accuracy
        transcripts.append(data['transcript']); runs.append(run)
        print(json.dumps(run, sort_keys=True), flush=True)
    means = {mode:{key:statistics.mean(r[key] for r in runs if r['profile'] == mode and r['accepted'])
                         for key in ['cpuSeconds', 'cpuEnergyNanojoules', 'performanceCoreFraction']}
             for mode in modes if any(r['profile'] == mode and r['accepted'] for r in runs)}
    same = all(text == transcripts[0] for text in transcripts)
    valid = same and all(r['accepted'] for r in runs)
    result = {'method':__doc__, 'order':args.profiles, 'runs':runs, 'means':means,
              'allFinalTranscriptsIdentical':same, 'validComparison':valid}
    # A stopped decoder consumes less energy simply because it misses audio.
    # Retain its raw measurements, but never report that as an improvement.
    if valid and 'helpersDefault' in means:
        result['cpuEnergyReductionFraction'] = {mode:1 - values['cpuEnergyNanojoules'] / means['helpersDefault']['cpuEnergyNanojoules'] for mode,values in means.items() if mode != 'helpersDefault'}
    (args.out / 'summary.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    return 0 if valid else 1


if __name__ == '__main__':
    raise SystemExit(main())
