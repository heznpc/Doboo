#!/usr/bin/env python3
"""Exercise native story clients with restart, sequel, relationship and forgetting."""
import argparse
import os
from pathlib import Path
import selectors
import subprocess
import tempfile


FAKE_CODEX = r'''#!/usr/bin/env node
const send = value => process.stdout.write(JSON.stringify(value) + '\n');
require('node:readline').createInterface({input:process.stdin}).on('line', line => {
  const m = JSON.parse(line);
  if (m.method === 'initialize') send({id:m.id,result:{}});
  if (m.method === 'account/read') send({id:m.id,result:{account:{type:'chatgpt'}}});
  if (m.method === 'thread/start') {
    if (m.params.sandbox !== 'read-only' || !m.params.ephemeral) throw Error('Scene host not isolated');
    send({id:m.id,result:{thread:{id:'story-fixture'}}});
  }
  if (m.method === 'turn/start') {
    const context = JSON.parse(m.params.input[0].text.split('\n').slice(1).join('\n'));
    const story = context.story || context;
    if (story.cast.length !== 2) throw Error('Missing cast');
    const supplied = JSON.stringify(story) + m.params.input.at(-1).text;
    const code = supplied.includes('AURORA913') ? 'AURORA913' : 'UNKNOWN';
    const result = {
      dialogue: [{speakerId:'ember',text:'[EMBER] ' + code}, {speakerId:'moss',text:'[MOSS] ' + code}],
      summary:'Both travelers discussed the observatory code ' + code,
      relationshipChanges: code === 'UNKNOWN' ? [] : [{fromCharacterId:'moss',toCharacterId:'ember',summary:'Moss trusts Ember with ' + code}]
    };
    send({id:m.id,result:{turn:{id:'story-turn'}}});
    send({method:'item/completed',params:{threadId:'story-fixture',item:{type:'agentMessage',text:JSON.stringify(result)}}});
    send({method:'turn/completed',params:{threadId:'story-fixture',turn:{status:'completed',error:null}}});
  }
});
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--live', action='store_true')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='doboo-story-flow-') as temporary:
        root = Path(temporary)
        project = root / 'project'
        project.mkdir()
        subprocess.run(['git', 'init', '-q', str(project)], check=True)
        executable = root / 'flow'
        subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library',
                        'Sources/Core/CharacterPack.swift', 'Sources/Core/CompanionTask.swift',
                        'Sources/Core/TaskSubmission.swift', 'Sources/Core/CompanionStory.swift',
                        'Shared/TaskConnection.swift', 'IntegrationTests/StoryFlow.swift', '-o', str(executable)],
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
                with selectors.DefaultSelector() as selector:
                    selector.register(bridge.stdout, selectors.EVENT_READ)
                    if not selector.select(timeout=15) or not bridge.stdout.readline():
                        raise RuntimeError('Bridge failed to start')
                subprocess.run([str(executable), str(root), phase], cwd=repo, check=True, timeout=1000)
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
        print('PASS native story flow' + (' with actual Codex responses' if args.live else ' with deterministic transport fixture'))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
