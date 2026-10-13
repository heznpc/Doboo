"""Fit existing reference pixels into one host attachment; never generate artwork."""
import argparse
import math
from PIL import Image, ImageDraw

parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True)
parser.add_argument('--image', action='append', required=True)
parser.add_argument('--role', action='append', required=True)
args = parser.parse_args()
if len(args.image) != len(args.role) or not 1 <= len(args.image) <= 7:
    raise ValueError('Mismatched source reference board')
cols = min(3, len(args.image)); side = 768; label = 32
board = Image.new('RGB', (cols * side, math.ceil(len(args.image)/cols) * (side+label)), '#eeeeee')
draw = ImageDraw.Draw(board)
for i, (path, role) in enumerate(zip(args.image, args.role)):
    x = (i % cols) * side; y = (i // cols) * (side+label)
    with Image.open(path) as source:
        art = source.convert('RGBA'); art.thumbnail((side-16, side-16), Image.Resampling.LANCZOS)
        board.paste(art, (x+(side-art.width)//2, y+label+(side-art.height)//2), art)
    draw.text((x+8,y+8), f'{i+1}: {role}', fill='#111111')
board.save(args.output)
