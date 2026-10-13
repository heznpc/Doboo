#!/usr/bin/env python3
"""Compare decoded RGBA pixels if the Pets service losslessly re-encodes an upload."""
import hashlib
import json
from pathlib import Path
import sys
from PIL import Image

images = []
for name in sys.argv[1:]:
    path = Path(name)
    if path.stat().st_size > 20 * 1024 * 1024:
        raise ValueError('Pet file exceeds the Pets size limit')
    with Image.open(path) as image:
        if image.size != (1536, 2288) or getattr(image, 'n_frames', 1) != 1:
            raise ValueError('Stored Pet is not a v2 atlas')
        images.append(hashlib.sha256(image.convert('RGBA').tobytes()).hexdigest())
if len(images) != 2 or images[0] != images[1]:
    raise ValueError('Stored Pet pixels differ from the validated atlas')
print(json.dumps({'samePixels': True, 'pixelSHA256': images[0]}))
