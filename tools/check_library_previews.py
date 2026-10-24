import os

dirs = [
    r'D:\ultrastar\game\songs',
    r'C:\Program Files (x86)\UltraStar WorldParty\songs'
]

has_preview = 0
has_medley_only = 0
not_a_song = 0
no_preview_at_all = []

for d in dirs:
    if not os.path.exists(d):
        continue
    for root, _, files in os.walk(d):
        for f in files:
            if f.lower().endswith('.txt'):
                fp = os.path.join(root, f)
                try:
                    with open(fp, 'r', encoding='utf-8', errors='ignore') as sfile:
                        txt = sfile.read()
                    if '#TITLE:' not in txt and '#BPM:' not in txt:
                        not_a_song += 1
                        continue
                    if '#PREVIEWSTART:' in txt or '#PREVIEW:' in txt:
                        has_preview += 1
                    elif '#MEDLEYSTARTBEAT:' in txt:
                        has_medley_only += 1
                    else:
                        no_preview_at_all.append(fp)
                except Exception as e:
                    pass

print(f"Has PREVIEWSTART/PREVIEW: {has_preview}")
print(f"Has MEDLEYSTARTBEAT only (missing PREVIEWSTART): {has_medley_only}")
print(f"Not a song: {not_a_song}")
print(f"Missing preview completely: {len(no_preview_at_all)}")
for m in no_preview_at_all[:10]:
    print('Missing preview completely:', m)
