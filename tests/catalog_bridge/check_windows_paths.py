#!/usr/bin/env python3
"""Static check of the Windows-only Pascal absolute-path character literals."""
from pathlib import Path

source = Path(__file__).resolve().parents[2] / 'src/base/USongCatalogBridge.pas'
text = source.read_text(encoding='utf-8')
windows = text.split('{$IFDEF MSWINDOWS}', 1)[1].split('{$ELSE}', 1)[0]
assert "Value[3] in ['\\', '/']" in windows
assert "Value[1] = '\\'" in windows and "Value[2] = '\\'" in windows
assert "Value[3] in ['\\\\', '/']" not in windows
assert ('if (Err = ERROR_NO_DATA) or (Err = ERROR_IO_PENDING) or\n'
        '       (Err = ERROR_PIPE_LISTENING) then Exit;') in text
assert 'Err in [ERROR_NO_DATA, ERROR_IO_PENDING, ERROR_PIPE_LISTENING]' not in text
print('PASS: Windows paths and pipe-error branch use portable Pascal expressions')
