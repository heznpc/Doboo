"""Validate user source art; this is not Pets atlas validation or image generation."""
import io
import sys
import warnings
from PIL import Image

warnings.simplefilter('error', Image.DecompressionBombWarning)
raw = sys.stdin.buffer.read(20 * 1024 * 1024 + 1)
if not 0 < len(raw) <= 20 * 1024 * 1024:
    raise ValueError('Source image exceeds 20 MiB')
with Image.open(io.BytesIO(raw)) as image:
    if image.format not in ('PNG', 'JPEG', 'WEBP') or image.width * image.height > 25_000_000:
        raise ValueError('Unsupported format or more than 25 megapixels')
    image.verify()
with Image.open(io.BytesIO(raw)) as image:
    image.load()
