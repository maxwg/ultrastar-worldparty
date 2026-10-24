import os
import sys
from song_catalog import detect_preview

def get_txt_files(root_dir, max_depth=3):
    if not os.path.exists(root_dir):
        return []
    txt_files = []
    root_dir = os.path.abspath(root_dir)
    root_depth = root_dir.count(os.sep)
    for root, dirs, files in os.walk(root_dir):
        # Don't recurse into .git, node_modules, AppData, etc.
        dirs[:] = [d for d in dirs if not d.startswith('.') and d.lower() not in ('node_modules', 'appdata', 'site-packages', 'windows', 'system32')]
        depth = root.count(os.sep) - root_depth
        if depth > max_depth:
            dirs.clear()
            continue
        for f in files:
            if f.lower().endswith('.txt'):
                txt_files.append(os.path.join(root, f))
    return txt_files

def main():
    search_dirs = [
        (r'D:\ultrastar\game\songs', 3),
        (r'C:\Program Files (x86)\UltraStar WorldParty\songs', 3),
        (r'C:\Users\maxwg\Downloads', 3),
        (r'C:\Users\maxwg\Music', 3)
    ]

    total_checked = 0
    updated = 0
    already_has = 0
    skipped = 0

    seen = set()

    for d, max_depth in search_dirs:
        print(f"Searching {d} (max depth {max_depth})...", flush=True)
        txts = get_txt_files(d, max_depth)
        print(f"  Found {len(txts)} txt files.", flush=True)
        for fp in txts:
            if fp in seen:
                continue
            seen.add(fp)

            try:
                with open(fp, 'r', encoding='utf-8', errors='ignore') as f:
                    lines = f.readlines()
            except Exception:
                continue

            headers = {}
            for line in lines:
                s = line.strip()
                if s.startswith('#'):
                    k, _, v = s[1:].partition(':')
                    headers[k.strip().upper()] = v.strip()

            if 'TITLE' not in headers or 'BPM' not in headers:
                continue

            total_checked += 1
            has_previewstart = 'PREVIEWSTART' in headers or 'PREVIEW' in headers

            if has_previewstart:
                already_has += 1
                continue

            preview = detect_preview(lines)
            if not preview:
                print(f"  [NO PREVIEW DETECTED] {headers.get('ARTIST', '')} - {headers.get('TITLE', '')} ({fp})", flush=True)
                skipped += 1
                continue

            extra = []
            if 'preview_start' in preview and 'PREVIEWSTART' not in headers and 'PREVIEW' not in headers:
                extra.append(f"#PREVIEWSTART:{preview['preview_start']}")
            if 'medley_start' in preview and 'MEDLEYSTARTBEAT' not in headers:
                extra.append(f"#MEDLEYSTARTBEAT:{preview['medley_start']}")
            if 'medley_end' in preview and 'MEDLEYENDBEAT' not in headers:
                extra.append(f"#MEDLEYENDBEAT:{preview['medley_end']}")

            if not extra:
                already_has += 1
                continue

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

            try:
                with open(fp, 'w', encoding='utf-8', newline='\n') as f:
                    f.writelines(new_lines)
                print(f"  [UPDATED] {headers.get('ARTIST', '')} - {headers.get('TITLE', '')} with {extra}", flush=True)
                updated += 1
            except Exception as ex:
                print(f"  [ERROR] Writing {fp}: {ex}", flush=True)

    print(f"\nCompleted!\nTotal songs: {total_checked}\nAlready had previewstart: {already_has}\nUpdated: {updated}\nSkipped: {skipped}", flush=True)

if __name__ == '__main__':
    main()
