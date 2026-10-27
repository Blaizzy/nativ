#!/usr/bin/env python3
"""Build an instrumented browser executable; restore every source file in finally.
Run only when no other build/edit is using this checkout. Reuses an existing complete
Debug Python resource. The bridge is never added to the app's normal build inputs.
"""
import argparse
import os
from pathlib import Path
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--output', required=True, type=Path)
p.add_argument('--baseline-ref')
a = p.parse_args()
root = Path(__file__).resolve().parents[3]
paths = [root / f for f in ['Sources/Nativ/Main.swift', 'Sources/Nativ/Features/Chat/ChatViewModel.swift',
                            'Sources/Nativ/Features/Chat/ChatWorkBrowser.swift',
                            'Sources/Nativ/Features/Chat/Tools/ChatWorkTool.swift']]
originals = {path: path.read_bytes() for path in paths}
a.output.mkdir(parents=True, exist_ok=True)
try:
    if a.baseline_ref:
        for path in paths:
            path.write_bytes(subprocess.check_output(['git', 'show', a.baseline_ref + ':' + str(path.relative_to(root))], cwd=root))
    main = paths[0]
    source = main.read_text().replace('static func main() {', 'static func main() {\n        if CommandLine.arguments.contains("--chat-work-benchmark") { ChatWorkBenchmarkBridge.run(); return }', 1)
    main.write_text(source + '\n' + Path(__file__).with_name('bridge.swift').read_text())
    with (a.output/'build.log').open('w') as log:
        subprocess.run(['xcodebuild','-project','Nativ.xcodeproj','-scheme','Nativ','-configuration','Debug',
                        '-derivedDataPath','build/ReportDerivedData','CODE_SIGNING_ALLOWED=NO','build'],
                       cwd=root, env={**os.environ, 'DEVELOPER_DIR':'/Applications/Xcode.app/Contents/Developer',
                                     'NATIV_SKIP_PYTHON_RESOURCE_BUILD':'YES'}, stdout=log, stderr=log, check=True)
    subprocess.run(['rsync','-a','--exclude','mlx-vlm-server','--exclude','_CodeSignature',
                    str(root/'build/ReportDerivedData/Build/Products/Debug/Nativ.app'),str(a.output)+'/'], check=True)
finally:
    for path, data in originals.items():
        path.write_bytes(data)
