#!/usr/bin/env python3
"""Build both CLI modes and check local inventory/rejection without a socket."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
with tempfile.TemporaryDirectory(prefix='rewinddv-cli-regression-') as tmp:
    catalog = {}
    for name, flag, expected in [('full', [], 66), ('offline', ['-D', 'REWINDDV_OFFLINE_DISTRIBUTION'], 57)]:
        exe = str(Path(tmp) / name)
        subprocess.run(['xcrun','swiftc','-parse-as-library','-O',*flag,
                        str(root/'Foundation/Tools/RewindDVCommandCLI/main.swift'),'-o',exe], env=env,check=True)
        response = subprocess.run([exe,'mcp'], input=json.dumps({'jsonrpc':'2.0','id':1,'method':'tools/list'})+'\n',
                                  text=True,capture_output=True,check=True)
        tools = json.loads(response.stdout)['result']['tools']
        assert len(tools) == expected and len({t['name'] for t in tools}) == expected
        catalog[name] = {t['name'] for t in tools}
    excluded = catalog['full'] - catalog['offline']
    assert len(excluded) == 9 and catalog['offline'] < catalog['full']
    for name in sorted(excluded):
        response = subprocess.run([str(Path(tmp)/'offline'),'mcp'], input=json.dumps({
            'jsonrpc':'2.0','id':2,'method':'tools/call','params':{'name':name,'arguments':{}}})+'\n',
            text=True,capture_output=True,check=True)
        assert json.loads(response.stdout)['error']['code'] == -32602
    print('PASS: normal66/offline57 inventories; all9hardware calls reject locally; no socket or hardware calls')
