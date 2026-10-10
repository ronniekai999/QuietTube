#!/usr/bin/env python3
from pathlib import Path
from PIL import Image, ImageDraw

project = Path(__file__).resolve().parent.parent
assets = project / 'assets'
assets.mkdir(exist_ok=True)
canvas = Image.new('RGBA', (512, 512), (0, 0, 0, 0))
draw = ImageDraw.Draw(canvas)
draw.rounded_rectangle((8, 8, 504, 504), radius=118, fill='#151a19')
draw.polygon([(256, 78), (406, 132), (391, 282), (343, 369), (256, 429), (169, 369), (121, 282), (106, 132)], fill='#b8ed9c')
draw.rounded_rectangle((193, 165, 215, 328), radius=10, fill='#17301c')
draw.polygon([(234, 165), (334, 247), (234, 328)], fill='#17301c')
canvas.save(assets / 'quiettube.png')
canvas.save(assets / 'quiettube.ico', sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])
for size in [16, 32, 64, 128, 512]:
    icon = canvas.resize((size, size), Image.Resampling.LANCZOS)
    icon.save(assets / f'icon_{size}.png')
    for suffix in ['', '_off']:
        icon.save(project / 'extension/img' / f'icon_{size}{suffix}.png')
