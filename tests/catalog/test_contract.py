"""Offline parser/current-protocol fixtures; never calls a catalog endpoint."""
import argparse
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

parser = argparse.ArgumentParser()
parser.add_argument('--backend', type=Path, required=True)
args = parser.parse_args()
spec = importlib.util.spec_from_file_location('fixture_catalog', args.backend / 'song_catalog.py')
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)

def deny_network(event, arguments):
    if event in ('socket.connect', 'socket.connect_ex', 'socket.getaddrinfo'):
        raise AssertionError('Network is forbidden in offline parser fixtures')
sys.addaudithook(deny_network)

CHART = '#TITLE:Example: Part 2\n#ARTIST:Fixture\n#BPM:120\n#GAP:15\n: 0 4 60 la\n- 4\nE\n'

class ParserAndProtocolTests(unittest.TestCase):
    def test_search_html_unicode_and_entities(self):
        row = '<tr class="list_tr1"><td><a onclick="show_detail(42)">Beyonc&eacute;</a></td><td>A &amp; B: Mix</td><td></td><td></td><td></td><td></td><td>Fran&ccedil;ais</td></tr>'
        self.assertEqual(catalog.parse_search(row), [{'id':42,'artist':'Beyonc\u00e9','title':'A & B: Mix','language':'Fran\u00e7ais'}])

    def test_malformed_and_empty_search(self):
        for html in ('', '<tr><td>broken', '<tr class="list_tr1"><td>missing id</td></tr>'):
            self.assertEqual(catalog.parse_search(html), [])

    def test_login_page_rejected(self):
        with self.assertRaisesRegex(ValueError, 'sign-in'):
            catalog.parse_search('You are not logged in')

    def test_chart_decodes_html_and_normalizes_newlines(self):
        encoded = CHART.replace('Example: Part 2', 'A &amp; B').replace('\n', '\r\n')
        decoded = catalog.parse_chart('<textarea>' + encoded + '</textarea>')
        self.assertIn('#TITLE:A & B\n', decoded)
        self.assertNotIn('\r', decoded)

    def test_chart_requires_playable_structure(self):
        for value in ('<p>no chart</p>', CHART.replace(': 0 4 60 la\n',''), CHART.replace('- 4\n',''), CHART.replace('E\n','')):
            with self.subTest(chart=value):
                with self.assertRaises(ValueError):
                    catalog.parse_chart('<textarea>'+value+'</textarea>')

    def test_chart_requires_finite_positive_tempo(self):
        for bpm in ('0','-1','nan','inf','bad'):
            with self.subTest(bpm=bpm):
                with self.assertRaises(ValueError):
                    catalog.parse_chart('<textarea>'+CHART.replace('#BPM:120','#BPM:'+bpm)+'</textarea>')

    def test_chart_requires_title_and_artist(self):
        for header in ('#TITLE:Example: Part 2\n', '#ARTIST:Fixture\n'):
            with self.assertRaises(ValueError):
                catalog.parse_chart('<textarea>'+CHART.replace(header,'')+'</textarea>')

    def test_prepare_chart_preserves_colons_and_metadata(self):
        prepared = catalog.prepare_chart(CHART+'#COMMENT:one:two:three\n')
        self.assertIn('#TITLE:Example: Part 2\n', prepared)
        self.assertIn('#COMMENT:one:two:three\n', prepared)
        self.assertIn('#GAP:15\n', prepared)

    def test_prepare_chart_replaces_all_external_media_headers(self):
        external = ['MP3','AUDIO','VIDEO','COVER','BACKGROUND','INSTRUMENTAL','VOCALS','ENCODING']
        prepared = catalog.prepare_chart(CHART+''.join('#'+key+':../../outside\n' for key in external))
        self.assertNotIn('../../outside', prepared)
        self.assertTrue(prepared.startswith('#MP3:media.mp4\n#VIDEO:media.mp4\n#ENCODING:UTF8\n'))

    def test_source_media_ids_deduplicated_and_bounded(self):
        text = 'https://youtu.be/ABCDEFGHIJK https://www.youtube.com/watch?v=ABCDEFGHIJK https://www.youtube.com/embed/12345678901'
        self.assertEqual(catalog.media_links(text), ['https://www.youtube.com/watch?v=ABCDEFGHIJK','https://www.youtube.com/watch?v=12345678901'])
        self.assertEqual(catalog.media_links('https://youtu.be/ABCDEFGHIJKextra'), [])

    def test_missing_signin_rejected_before_request(self):
        instance = catalog.Catalog()
        with patch.object(instance, 'request', side_effect=AssertionError('No request allowed')) as request:
            with self.assertRaises(ValueError):
                instance.login('', '')
            request.assert_not_called()

    def test_current_cli_malformed_requests_do_not_echo_content(self):
        output = io.StringIO()
        payload = 'synthetic-marker-not-a-secret'
        requests = payload+'\n[]\n'+json.dumps({'op':'quit'})+'\n'
        with patch.object(sys, 'stdin', io.StringIO(requests)), contextlib.redirect_stdout(output):
            catalog.main()
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(events, [{'type':'error','message':'Invalid request.'}]*2)
        self.assertNotIn(payload, output.getvalue())

    def test_current_cli_rejects_completed_oversized_line(self):
        # This verifies the existing post-read check, not bounded stream framing.
        output = io.StringIO()
        with patch.object(sys, 'stdin', io.StringIO('x'*16385+'\n{"op":"quit"}\n')), contextlib.redirect_stdout(output):
            catalog.main()
        self.assertEqual(json.loads(output.getvalue()), {'type':'error','message':'Request too large.'})

if __name__ == '__main__':
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ParserAndProtocolTests))
    raise SystemExit(0 if result.wasSuccessful() else 1)
