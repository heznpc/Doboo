#!/usr/bin/env python3
"""Exercise two native clients over HTTP, including a server restart and forgetting.

Default uses a deterministic app-server fixture. --live uses the installed Codex
login with synthetic inputs in a temporary project; no physical devices involved.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile


FAKE_CODEX = r'''#!/usr/bin/env node
const readline = require('node:readline');
const send = value => process.stdout.write(JSON.stringify(value) + '\n');
readline.createInterface({input:process.stdin}).on('line', line => {
  const m = JSON.parse(line);
  if (m.method === 'initialize') send({id:m.id,result:{}});
  if (m.method === 'account/read') send({id:m.id,result:{account:{type:'chatgpt'}}});
  if (m.method === 'thread/start') send({id:m.id,result:{thread:{id:'fixture-thread'}}});
  if (m.method === 'turn/start') {
    const data = JSON.parse(m.params.input[0].text.split('\n').slice(1).join('\n'));
    const current = m.params.input.at(-1).text;
    if (!data.character.identity.voice.includes('[ORB]')) throw Error('Missing native profile');
    const known = JSON.stringify(data.previousCompletedWork) + current;
    const result = '[ORB] ' + (known.includes('violet-lantern') ? 'violet-lantern' : 'UNKNOWN')
      + ' ' + (data.savedMemory.includes('MINT742') ? 'MINT742' : 'UNKNOWN');
    send({id:m.id,result:{turn:{id:'fixture-turn'}}});
    send({method:'item/completed',params:{threadId:'fixture-thread',item:{type:'agentMessage',text:result}}});
    send({method:'turn/completed',params:{threadId:'fixture-thread',turn:{status:'completed',error:null}}});
  }
});
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--live', action='store_true')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='doboo-continuity-') as temporary:
        root = Path(temporary)
        project = root / 'project'
        project.mkdir()
        subprocess.run(['git', 'init', '-q', str(project)], check=True)
        executable = root / 'flow'
        subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library',
                        'Sources/Core/CharacterPack.swift', 'Sources/Core/CompanionTask.swift',
                        'Sources/Core/TaskSubmission.swift', 'Sources/Core/CompanionStory.swift', 'Shared/TaskConnection.swift',
                        'IntegrationTests/ContinuityFlow.swift', '-o', str(executable)],
                       cwd=repo, check=True, timeout=90)
        env = os.environ.copy()
        if not args.live:
            fixture = root / 'fixture-codex'
            fixture.write_text(FAKE_CODEX)
            fixture.chmod(0o700)
            env['DOBOO_CODEX_BINARY'] = str(fixture)
        for phase in ['seed', 'continue']:
            bridge = subprocess.Popen(['node', 'task-bridge/server.mjs', str(project), str(root / 'bridge')],
                                      cwd=repo, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                # CLI emits readiness only after bind, also on the second launch.
                import selectors
                with selectors.DefaultSelector() as selector:
                    selector.register(bridge.stdout, selectors.EVENT_READ)
                    if not selector.select(timeout=15) or not bridge.stdout.readline():
                        raise RuntimeError('Bridge failed to start')
                subprocess.run([str(executable), str(root), phase], cwd=repo, check=True, timeout=600)
            finally:
                bridge.terminate()
                try:
                    bridge.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    bridge.kill()
                    bridge.wait()
                error = bridge.stderr.read()
                if error:
                    print(error)
        print('PASS native HTTP continuity flow' + (' with actual Codex responses' if args.live else ' with deterministic transport fixture'))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
