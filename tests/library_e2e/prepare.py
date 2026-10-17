"""Create an isolated SDL end-to-end runtime with copyright-free media."""
import argparse
import configparser
import json
from pathlib import Path
import shutil
import subprocess
import sys
import struct
import zlib

parser = argparse.ArgumentParser()
parser.add_argument('--repo', type=Path, required=True)
parser.add_argument('--runtime', type=Path, required=True)
parser.add_argument('--ffmpeg', required=True)
parser.add_argument('--no-fade', action='store_true')
parser.add_argument('--wide-window', action='store_true')
parser.add_argument('--rap', action='store_true')
args = parser.parse_args()
runtime = args.runtime.resolve()
for dll in (args.repo / 'game').glob('*.dll'):
    shutil.copy2(dll, runtime / dll.name)
for directory in ('songs/LocalFixture', 'songs/LocalFixtureDuplicate', 'screenshots'):
    (runtime / directory).mkdir(parents=True, exist_ok=True)
shutil.copy2(Path(__file__).with_name('fixture_adapter.py'), runtime / 'fixture_adapter.py')
(runtime / 'fixture-credentials.json').write_text(json.dumps({'user':'offline-fixture','pass':'offline-fixture'}))
chart = '#TITLE:Remote Fixture\n#ARTIST:E2E\n#MP3:media.mp4\n#VIDEO:media.mp4\n#BPM:120\n#GAP:0\n#ENCODING:UTF8\n: 0 8 9 la\n- 8\n: 10 8 11 la\nE\n'
if args.rap:
    chart = chart.replace(': 0 8 9 la', 'R 0 8 9 la').replace(': 10 8 11 la', 'R 10 8 11 la')
(runtime / 'fixture.txt').write_text(chart, encoding='utf-8')
settings = configparser.ConfigParser()
settings.optionxform = str
settings['Game'] = dict(Players='1', Language='English', Tabs='Off', Sorting='Artist', SongMenu='Chessboard')
settings['Graphics'] = dict(FullScreen='Off', Resolution='800x600', Screens='1', Split='Off', MaxFramerate='60')
settings['Graphics']['ScreenFade'] = 'Off' if args.no_fade else 'On'
if args.wide_window:
    settings['Graphics']['Resolution'] = '1280x720'
settings['Catalog'] = dict(Python=sys.executable, Adapter=str(runtime/'fixture_adapter.py'), Credentials=str(runtime/'fixture-credentials.json'))
settings['Directories'] = dict(SongDir1=str(runtime/'songs'))
settings['Record'] = {'DeviceName[1]':'System audio capture device','Input[1]':'0','Channel1[1]':'1','Channel2[1]':'0','Latency[1]':'0'}
with (runtime/'config.ini').open('w', encoding='utf-8') as handle:
    settings.write(handle)
subprocess.run([args.ffmpeg, '-hide_banner','-loglevel','error','-y',
    '-f','lavfi','-i','color=c=black:s=320x240:r=15',
    '-f','lavfi','-i','sine=frequency=440:sample_rate=44100',
    '-t','20','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac',str(runtime/'fixture.mp4')], check=True)
shutil.copy2(runtime/'fixture.mp4', runtime/'songs/LocalFixture/media.mp4')
(runtime/'songs/LocalFixture/song.txt').write_text(chart.replace('Remote Fixture','Local Fixture'), encoding='utf-8')
shutil.copy2(runtime/'fixture.mp4', runtime/'songs/LocalFixtureDuplicate/media.mp4')
(runtime/'songs/LocalFixtureDuplicate/song.txt').write_text(chart.replace('Remote Fixture','Local Fixture'), encoding='utf-8')

# Original abstract test covers include portrait and landscape art to catch crop
# distortion and light backgrounds that could make card captions unreadable.
def cover_png(path, width, height, palette):
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
    pixels = bytearray()
    for y in range(height):
        pixels.append(0)
        for x in range(width):
            t = (x / width + y / height) / 2
            bright = ((x / width - .65) ** 2 + (y / height - .30) ** 2) < .065
            pixels.extend(min(255, int(a * (1-t) + b * t) + (65 if bright else 0)) for a,b in zip(*palette))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b''))

for index, title in enumerate(('Local Fixture', 'Fixture Sunrise', 'Fixture Night Drive', 'Fixture Live Session', 'Fixture Skyline', 'Fixture Acoustic')):
    folder = runtime/'songs'/('VisualFixture'+str(index))
    if index == 0:
        folder = runtime/'songs/LocalFixture'
    folder.mkdir(exist_ok=True)
    shutil.copy2(runtime/'fixture.mp4', folder/'media.mp4')
    width, height = ((320,320),(480,240),(240,480))[index % 3]
    palette = (((130,40,100),(20,50,110)), ((240,170,80),(150,55,70)), ((30,160,180),(25,40,110)), ((230,200,150),(80,70,100)), ((90,150,220),(50,35,100)), ((60,170,130),(20,70,100)))[index]
    cover_png(folder/'cover.png', width, height, palette)
    (folder/'song.txt').write_text(chart.replace('Remote Fixture',title).replace('#ARTIST:E2E', '#COVER:cover.png\n#ARTIST:E2E'), encoding='utf-8')
shutil.copy2(runtime/'songs/LocalFixture/cover.png', runtime/'songs/LocalFixtureDuplicate/cover.png')
shutil.copy2(runtime/'songs/LocalFixture/song.txt', runtime/'songs/LocalFixtureDuplicate/song.txt')
