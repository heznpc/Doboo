#!/usr/bin/env python3
"""Run the installed OpenAI work-pets production tools, never a substitute compositor.

Artwork and visual verdicts come from the host's imagegen/review workflow.
This adapter assembles only supplied pixels and fails closed on missing reports.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import shutil
from PIL import Image



def register_standard_frames(run):
    """One shared fit, then one translation per row. Preserve jump displacement.

    The bundled extractor centers each row's complete vertical envelope, which
    otherwise gives idle and jumping different ground contact. Never fit poses
    independently or synthesize artwork.
    """
    groups = {}
    max_extent = max_width = 1
    for folder in sorted((run / 'qa/frames').iterdir()):
        if not folder.is_dir():
            continue
        files = sorted(folder.glob('*.png'))
        frames = [Image.open(path).convert('RGBA') for path in files]
        boxes = [frame.getbbox() for frame in frames]
        if not boxes or any(box is None for box in boxes):
            raise RuntimeError('Missing standard frame during registration')
        ground = max(box[3] for box in boxes)
        max_extent = max(max_extent, ground - min(box[1] for box in boxes))
        max_width = max(max_width, max(box[2] - box[0] for box in boxes))
        groups[folder.name] = (files, frames, ground)
    scale = min(1.0, 192 / max_extent, 184 / max_width)
    size = (round(192 * scale), round(208 * scale))
    report = {'scale': scale, 'baseline': 200, 'rows': {}}
    for name, (files, frames, ground) in groups.items():
        fitted = [frame.resize(size, Image.Resampling.LANCZOS) for frame in frames]
        dy = 200 - max(frame.getbbox()[3] for frame in fitted)
        dx = (192 - size[0]) // 2
        for path, frame in zip(files, fitted):
            box = frame.getbbox()
            if box[0]+dx < 0 or box[1]+dy < 0 or box[2]+dx > 192 or box[3]+dy > 208:
                raise RuntimeError('Standard registration would clip artwork')
            cell = Image.new('RGBA', (192, 208)); cell.alpha_composite(frame, (dx, dy)); cell.save(path)
        report['rows'][name] = {'translation': [dx, dy], 'originalGround': ground}
    (run / 'qa/standard-registration.json').write_text(json.dumps(report, indent=2))


def execute(skill, run, stage):
    def invoke(name, *args):
        result = subprocess.run([sys.executable, str(skill / 'scripts' / name), *map(str, args)],
                                cwd=run, text=True, capture_output=True)
        (run / 'qa' / (name + '.log')).write_text(result.stdout + result.stderr, encoding='utf-8')
        if result.returncode:
            raise RuntimeError(name + ': ' + (result.stderr or result.stdout)[-5000:])
    request = json.loads((run / 'pet_request.json').read_text(encoding='utf-8'))
    key = request['chroma_key']['hex']
    d = lambda path: str(run / path)
    if stage == 'standard-rows':
        invoke('extract_strip_frames.py', '--decoded-dir', d('decoded'), '--output-dir', d('qa/frames'), '--states', 'all', '--method', 'auto', '--chroma-key', key)
        register_standard_frames(run)
        invoke('inspect_frames.py', '--frames-root', d('qa/frames'), '--json-out', d('qa/review.json'), '--require-components')
        invoke('compose_atlas.py', '--frames-root', d('qa/frames'), '--output', d('final/spritesheet.png'))
        invoke('make_contact_sheet.py', d('final/spritesheet.png'), '--output', d('qa/contact-sheet.png'))
        invoke('render_animation_previews.py', '--frames-root', d('qa/frames'), '--output-dir', d('qa/previews'))
    elif stage == 'cardinals':
        invoke('extract_cardinal_anchors.py', '--strip', d('decoded/look-cardinals.png'), '--output-dir', d('decoded/look-anchors'), '--json-out', d('qa/cardinals.json'), '--chroma-key', key)
        invoke('compose_cardinal_anchor_strip.py', '--anchors-dir', d('decoded/look-anchors'), '--output', d('decoded/look-anchors-approved.png'))
    elif stage == 'look-row-9':
        invoke('assemble_extended_atlas.py', '--base-atlas', d('final/spritesheet.png'), '--look-row-9', d('decoded/look-row-9.png'), '--registered-row-output', d('qa/registered-row-9.png'), '--registration-manifest-output', d('qa/row-9-registration.json'), '--chroma-key', key)
    elif stage == 'assemble-v2':
        ffmpeg = shutil.which('ffmpeg')
        if not ffmpeg:
            raise RuntimeError('Final motion previews require an installed ffmpeg. No preview or publication success is recorded.')
        invoke('assemble_extended_atlas.py', '--base-atlas', d('final/spritesheet.png'), '--registered-row-9', d('qa/registered-row-9.png'), '--row-9-registration', d('qa/row-9-registration.json'), '--look-row-10', d('decoded/look-row-10.png'), '--output', d('final/spritesheet-raw.png'), '--chroma-key', key)
        # Always starts from the raw assembly: a retry does not despill twice.
        invoke('despill_chroma_edges.py', d('final/spritesheet-raw.png'), '--output', d('final/spritesheet-extended.png'), '--json-out', d('qa/chroma-despill-extended.json'), '--chroma-key', key)
        invoke('make_contact_sheet.py', d('final/spritesheet-extended.png'), '--output', d('qa/contact-sheet-extended.png'))
        invoke('make_direction_qa_sheet.py', d('final/spritesheet-extended.png'), '--output', d('qa/look-directions.png'))
        # Deterministic extraction from the FINAL encoded atlas, not source strips.
        with Image.open(run / 'final/spritesheet-extended.png') as encoded:
            atlas = encoded.convert('RGBA')
            states = [('idle',6),('running-right',8),('running-left',8),('waving',4),('jumping',5),('failed',8),('waiting',6),('running',6),('review',6)]
            for row,(state,count) in enumerate(states):
                folder = run / 'qa/final-frames' / state
                folder.mkdir(parents=True, exist_ok=True)
                for column in range(count):
                    atlas.crop((column*192,row*208,(column+1)*192,(row+1)*208)).save(folder / f'{column:02d}.png')
        invoke('render_animation_previews.py', '--frames-root', d('qa/final-frames'), '--output-dir', d('qa/final-previews'))
        frames = [Image.open(run / 'qa/final-frames' / state / f'{frame:02d}.png').convert('RGBA') for state,frame in [('idle',0),('jumping',0),('jumping',1),('jumping',2),('jumping',3),('jumping',4),('idle',0)]]
        frames[0].save(d('qa/final-previews/idle-jump-idle.gif'),save_all=True,append_images=frames[1:],duration=[400,140,140,140,140,280,400],loop=0,disposal=2)
        # Reuse the installed tool's state timing; these previews only crop
        # pixels from the encoded atlas and never synthesize character artwork.
        sys.path.insert(0, str(skill / 'scripts'))
        from render_animation_previews import ROW_DURATIONS, save_preview
        all_frames, all_durations = [], []
        for row, (state, count) in enumerate(states):
            all_frames.extend(atlas.crop((column*192,row*208,(column+1)*192,(row+1)*208)) for column in range(count))
            all_durations.extend(ROW_DURATIONS[state])
        preview_dir = run / 'qa/final-previews'
        save_preview(all_frames, all_durations, preview_dir / 'all-states.gif')
        look_frames = [atlas.crop((column*192,row*208,(column+1)*192,(row+1)*208)) for row in (9,10) for column in range(8)]
        save_preview(look_frames, [180]*16, preview_dir / 'look-loop.gif')
        for state, frame in [('idle',0),('jumping',2),('waiting',0),('review',0)]:
            shutil.copyfile(run / 'qa/final-frames' / state / f'{frame:02d}.png', preview_dir / f'still-{state}.png')
        video = subprocess.run([ffmpeg, '-y', '-i', str(preview_dir / 'all-states.gif'),
                                '-vf', 'fps=12,format=yuv420p', '-movflags', '+faststart', '-an',
                                str(preview_dir / 'all-states.mp4')], text=True, capture_output=True)
        (run / 'qa/preview-video.log').write_text(video.stdout + video.stderr, encoding='utf-8')
        if video.returncode:
            raise RuntimeError('Final MP4 preview encoding failed: ' + video.stderr[-2000:])
    elif stage == 'validate-v2':
        invoke('validate_atlas.py', d('final/spritesheet-extended.png'), '--require-v2', '--chroma-key', key, '--json-out', d('final/validation-extended.json'))
        invoke('measure_direction_continuity.py', d('final/spritesheet-extended.png'), '--json-out', d('qa/look-continuity.json'))
        invoke('validate_pet_quality.py', d('final/spritesheet-extended.png'), '--atlas-validation', d('final/validation-extended.json'), '--chroma-report', d('qa/chroma-despill-extended.json'), '--frame-review', d('qa/review.json'), '--direction-semantics', d('qa/direction-semantics.json'), '--continuity', d('qa/look-continuity.json'), '--json-out', d('qa/pet-quality.json'))
    else:
        raise ValueError('Unknown production stage')
    return {'ok': True, 'stage': stage}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--skill-dir', required=True)
    parser.add_argument('--run-dir', required=True)
    parser.add_argument('--stage', required=True, choices=['standard-rows', 'cardinals', 'look-row-9', 'assemble-v2', 'validate-v2'])
    args = parser.parse_args()
    try:
        print(json.dumps(execute(Path(args.skill_dir).resolve(), Path(args.run_dir).resolve(), args.stage)))
    except Exception as error:
        print(json.dumps({'ok': False, 'error': str(error)}))
        sys.exit(1)
