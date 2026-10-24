import os
from song_catalog import detect_preview

targets = [
    r"C:\Users\maxwg\Downloads\Billie Eilish - idontwannabeyouanymore\Billie Eilish - idontwannabeyouanymore.txt",
    r"C:\Users\maxwg\Downloads\Imagine Dragons - Believer\Imagine Dragons - Believer.txt"
]

for fp in targets:
    if not os.path.exists(fp):
        continue
    with open(fp, 'r', encoding='utf-8', errors='ignore') as f:
        lines = f.readlines()

    headers = {}
    for line in lines:
        s = line.strip()
        if s.startswith('#'):
            k, _, v = s[1:].partition(':')
            headers[k.strip().upper()] = v.strip()

    preview = detect_preview(lines)
    extra = []
    if 'TITLE' not in headers:
        # Determine title from folder name
        parent = os.path.basename(os.path.dirname(fp))
        if ' - ' in parent:
            title = parent.split(' - ', 1)[1]
        else:
            title = parent
        extra.append(f"#TITLE:{title}")

    if preview and 'preview_start' in preview and 'PREVIEWSTART' not in headers and 'PREVIEW' not in headers:
        extra.append(f"#PREVIEWSTART:{preview['preview_start']}")
    if preview and 'medley_start' in preview and 'MEDLEYSTARTBEAT' not in headers:
        extra.append(f"#MEDLEYSTARTBEAT:{preview['medley_start']}")
    if preview and 'medley_end' in preview and 'MEDLEYENDBEAT' not in headers:
        extra.append(f"#MEDLEYENDBEAT:{preview['medley_end']}")

    if extra:
        new_lines = []
        inserted = False
        for line in lines:
            s = line.strip()
            if not inserted and (s.startswith(':') or s.startswith('*') or s.startswith('F') or s.startswith('-') or s.startswith('R') or s.startswith('G')):
                for h in extra:
                    new_lines.append(h + '\n')
                inserted = True
            new_lines.append(line)
        if not inserted:
            for h in extra:
                new_lines.append(h + '\n')
        with open(fp, 'w', encoding='utf-8', newline='\n') as f:
            f.writelines(new_lines)
        print(f"Updated {fp} with {extra}")
