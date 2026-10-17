"""Offline parser/current-protocol fixtures; never calls a catalog endpoint."""
import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
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
        self.assertEqual(events, [{'type':'error','code':'invalid_request','message':'Invalid request.'}]*2)
        self.assertNotIn(payload, output.getvalue())

    def test_current_cli_rejects_completed_oversized_line(self):
        # This verifies the existing post-read check, not bounded stream framing.
        output = io.StringIO()
        with patch.object(sys, 'stdin', io.StringIO('x'*16385+'\n{"op":"quit"}\n')), contextlib.redirect_stdout(output):
            catalog.main()
        self.assertEqual(json.loads(output.getvalue()), {'type':'error','code':'request_too_large','message':'Request too large.'})

    def run_cli(self, requests, *, downloads_enabled=False):
        output = io.StringIO()
        with patch.object(sys, 'stdin', io.StringIO(requests)), contextlib.redirect_stdout(output):
            catalog.main(downloads_enabled=downloads_enabled)
        return [json.loads(line) for line in output.getvalue().splitlines()]

    def test_v1_status_is_offline_process_scoped_and_download_disabled(self):
        events = self.run_cli(
            json.dumps({'protocol_version':1,'request_id':'status-1','op':'status'})+'\n'+
            json.dumps({'op':'quit'})+'\n')
        self.assertEqual(events, [{
            'type':'status', 'protocol_version':1, 'request_id':'status-1',
            'auth_state':'signed_out', 'setup_state':'login_required',
            'session_scope':'process_memory_only', 'busy':False,
            'capabilities':{'login':True,'search':True,'details':True,'download':False}}])

    def test_v1_status_advertises_only_explicitly_enabled_download(self):
        events = self.run_cli(
            json.dumps({'protocol_version':1,'request_id':'status-enabled','op':'status'})+'\n'+
            json.dumps({'op':'quit'})+'\n', downloads_enabled=True)
        self.assertTrue(events[0]['capabilities']['download'])

    def test_v1_search_correlates_result_and_idle_and_keeps_revision_alias(self):
        rows = [{'id':42,'artist':'Fixture','title':'Song','language':'en'}]
        with patch.object(catalog.Catalog, 'search', return_value=rows):
            events = self.run_cli(
                json.dumps({'protocol_version':1,'request_id':'search:one','revision':17,
                            'op':'search','artist':'Fixture','title':'Song'})+'\n'+
                json.dumps({'op':'quit'})+'\n')
        self.assertEqual(events, [
            {'type':'results','protocol_version':1,'request_id':'search:one','revision':17,'songs':rows},
            {'type':'idle','protocol_version':1,'request_id':'search:one','revision':17}])

    def test_v1_login_establishes_only_same_process_auth_state(self):
        login_finished = threading.Event()
        real_login = catalog.Catalog.login
        real_emit = catalog.emit

        def offline_login(instance, user, password):
            # Exercise the real login verification logic with fixture pages, not HTTP.
            with patch.object(instance, 'request', side_effect=['', '<form name="interpret"></form><input name="title">']):
                real_login(instance, user, password)

        def observe_emit(kind, **data):
            real_emit(kind, **data)
            if kind=='idle' and data.get('request_id')=='login-1':
                login_finished.set()

        def requests_after_login():
            yield json.dumps({'protocol_version':1,'request_id':'login-1','op':'login',
                              'user':'fixture-user','password':'fixture-password'})+'\n'
            self.assertTrue(login_finished.wait(2), 'offline login handler did not finish')
            yield json.dumps({'protocol_version':1,'request_id':'status-after-login','op':'status'})+'\n'
            yield json.dumps({'op':'quit'})+'\n'

        output = io.StringIO()
        with patch.object(catalog.Catalog, 'login', offline_login), \
                patch.object(catalog, 'emit', observe_emit), \
                patch.object(sys, 'stdin', requests_after_login()), contextlib.redirect_stdout(output):
            catalog.main()
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        login = next(event for event in events if event['type']=='login')
        status = next(event for event in events if event['type']=='status')
        self.assertEqual(login, {'type':'login','protocol_version':1,'request_id':'login-1',
                                 'ok':True,'auth_state':'signed_in'})
        self.assertEqual(status['auth_state'], 'signed_in')
        self.assertEqual(status['setup_state'], 'ready')
        self.assertNotIn('fixture-password', output.getvalue())

    def test_v1_login_resolves_credentials_file_without_echoing_secrets(self):
        seen = {}
        real_login = catalog.Catalog.login
        real_emit = catalog.emit

        def offline_login(instance, user, password):
            seen[user] = password
            with patch.object(instance, 'request', side_effect=['', '<form name="interpret"></form><input name="title">']):
                real_login(instance, user, password)

        request_ids = {}
        for name in ('login-file', 'login-fallback', 'login-typed', 'login-badfile'):
            request_ids[name] = threading.Event()

        def observe_emit(kind, **data):
            real_emit(kind, **data)
            request_id = data.get('request_id')
            if kind=='idle' and request_id in request_ids:
                request_ids[request_id].set()

        with tempfile.TemporaryDirectory() as scratch:
            store = Path(scratch) / 'credentials.json'
            store.write_text(json.dumps({'user': 'cred-user', 'pass': 'cred-pass'}), encoding='utf-8')
            bogus = Path(scratch) / 'bogus.json'
            bogus.write_text('not json at all', encoding='utf-8')

            def requests():
                yield json.dumps({'protocol_version':1,'request_id':'login-file','op':'login',
                                  'credentials_file':str(store)})+'\n'
                self.assertTrue(request_ids['login-file'].wait(2), 'credentials-file login did not finish')
                yield json.dumps({'protocol_version':1,'request_id':'login-typed','op':'login',
                                  'user':'typed-user','password':'typed-pass',
                                  'credentials_file':str(store)})+'\n'
                self.assertTrue(request_ids['login-typed'].wait(2), 'typed login did not finish')
                # With --credentials configured, a bare login uses the startup file.
                yield json.dumps({'protocol_version':1,'request_id':'login-fallback','op':'login'})+'\n'
                self.assertTrue(request_ids['login-fallback'].wait(2), 'fallback login did not finish')
                yield json.dumps({'protocol_version':1,'request_id':'login-badfile','op':'login',
                                  'credentials_file':str(bogus)})+'\n'
                self.assertTrue(request_ids['login-badfile'].wait(2), 'badfile login did not finish')
                yield json.dumps({'op':'quit'})+'\n'

            output = io.StringIO()
            with patch.object(catalog.Catalog, 'login', offline_login), \
                    patch.object(catalog, 'emit', observe_emit), \
                    patch.object(sys, 'stdin', requests()), contextlib.redirect_stdout(output):
                catalog.main(credentials_path=str(store))
            events = [json.loads(line) for line in output.getvalue().splitlines()]
            login_file = next(e for e in events if e.get('request_id')=='login-file')
            login_typed = next(e for e in events if e.get('request_id')=='login-typed')
            login_fallback = next(e for e in events if e.get('request_id')=='login-fallback')
            self.assertEqual(login_file, {'type':'login','protocol_version':1,'request_id':'login-file',
                                          'ok':True,'auth_state':'signed_in'})
            self.assertEqual(login_typed, {'type':'login','protocol_version':1,'request_id':'login-typed',
                                           'ok':True,'auth_state':'signed_in'})
            self.assertEqual(login_fallback, {'type':'login','protocol_version':1,'request_id':'login-fallback',
                                              'ok':True,'auth_state':'signed_in'})
            self.assertEqual(seen.get('cred-user'), 'cred-pass')
            self.assertEqual(seen.get('typed-user'), 'typed-pass')
            self.assertNotIn('cred-pass', output.getvalue())
            self.assertNotIn('typed-pass', output.getvalue())
            error_bad = next(e for e in events if e.get('request_id')=='login-badfile' and e['type']=='error')
            self.assertEqual(error_bad['code'], 'credentials_file_invalid')

    def test_v1_login_credentials_file_error_codes(self):
        real_emit = catalog.emit
        done = {name: threading.Event() for name in
                ('login-nopath', 'login-badpath', 'login-badjson', 'login-baduser', 'login-badpass')}

        def observe_all(kind, **data):
            real_emit(kind, **data)
            request_id = data.get('request_id')
            if kind=='idle' and request_id in done:
                done[request_id].set()

        with tempfile.TemporaryDirectory() as scratch:
            badjson = Path(scratch) / 'bad.json'
            badjson.write_text('[]', encoding='utf-8')
            baduser = Path(scratch) / 'baduser.json'
            baduser.write_text(json.dumps({'user': '', 'pass': 'cred-pass'}), encoding='utf-8')
            badpass = Path(scratch) / 'badpass.json'
            badpass.write_text(json.dumps({'user': 'cred-user', 'pass': 3}), encoding='utf-8')
            missing_file = Path(scratch) / 'gone.json'

            cases = [
                ('login-nopath', {'op':'login'}, 'missing_credentials'),
                ('login-badpath', {'op':'login','credentials_file':str(missing_file)}, 'credentials_file_unreadable'),
                ('login-badjson', {'op':'login','credentials_file':str(badjson)}, 'credentials_file_invalid'),
                ('login-baduser', {'op':'login','credentials_file':str(baduser)}, 'credentials_file_invalid'),
                ('login-badpass', {'op':'login','credentials_file':str(badpass)}, 'credentials_file_invalid'),
            ]

            def requests():
                for request_id, body, _ in cases:
                    yield json.dumps({'protocol_version':1,'request_id':request_id, **body})+'\n'
                    self.assertTrue(done[request_id].wait(2), request_id + ' did not finish')
                yield json.dumps({'op':'quit'})+'\n'

            output = io.StringIO()
            with patch.object(catalog, 'emit', observe_all), \
                    patch.object(sys, 'stdin', requests()), contextlib.redirect_stdout(output):
                catalog.main()
            events = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertNotIn('cred-pass', output.getvalue())
            for request_id, _, expected_code in cases:
                with self.subTest(request_id=request_id):
                    error = next((e for e in events if e.get('request_id')==request_id and e['type']=='error'), None)
                    self.assertIsNotNone(error, 'no error event for ' + request_id)
                    self.assertEqual(error['code'], expected_code)

    def test_failed_offline_login_clears_process_auth_state(self):
        instance = catalog.Catalog()
        instance.authenticated = True
        with patch.object(instance, 'request', return_value='Please login'):
            with self.assertRaisesRegex(ValueError, 'could not be verified'):
                instance.login('fixture-user', 'fixture-password')
        self.assertFalse(instance.authenticated)
        self.assertEqual(len(instance.jar), 0)

    def test_expired_search_html_invalidates_auth_instead_of_empty_results(self):
        instance = catalog.Catalog()
        instance.authenticated = True
        with patch.object(instance, 'request', return_value='<html>You are not logged in</html>'):
            with self.assertRaisesRegex(ValueError, 'sign-in is required'):
                instance.search('Fixture', 'Song')
        self.assertFalse(instance.authenticated)
        self.assertEqual(len(instance.jar), 0)

    def test_expired_details_html_invalidates_auth(self):
        instance = catalog.Catalog()
        instance.authenticated = True
        with patch.object(instance, 'request', return_value='<html>Please login</html>') as request:
            with self.assertRaisesRegex(ValueError, 'sign-in is required'):
                instance.details(42)
        request.assert_called_once()
        self.assertFalse(instance.authenticated)
        self.assertEqual(len(instance.jar), 0)

    def test_v1_expired_session_error_updates_status_without_empty_results(self):
        search_finished = threading.Event()
        real_init = catalog.Catalog.__init__
        real_emit = catalog.emit
        login_page = '<html><body>You are not logged in</body></html>'

        def previously_signed_in(instance):
            real_init(instance)
            instance.authenticated = True

        def observe_emit(kind, **data):
            real_emit(kind, **data)
            if kind=='idle' and data.get('request_id')=='expired-search':
                search_finished.set()

        def requests_after_search():
            yield json.dumps({'protocol_version':1,'request_id':'expired-search','op':'search',
                              'artist':'Fixture','title':'Missing'})+'\n'
            self.assertTrue(search_finished.wait(2), 'expired-session search did not finish')
            yield json.dumps({'protocol_version':1,'request_id':'status-expired','op':'status'})+'\n'
            yield json.dumps({'op':'quit'})+'\n'

        output = io.StringIO()
        with patch.object(catalog.Catalog, '__init__', previously_signed_in), \
                patch.object(catalog.Catalog, 'request', return_value=login_page), \
                patch.object(catalog, 'emit', observe_emit), \
                patch.object(sys, 'stdin', requests_after_search()), contextlib.redirect_stdout(output):
            catalog.main()
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        error = next(event for event in events if event.get('request_id')=='expired-search' and event['type']=='error')
        status = next(event for event in events if event.get('request_id')=='status-expired')
        self.assertEqual(error['code'], 'authentication_required')
        self.assertEqual(status['auth_state'], 'signed_out')
        self.assertEqual(status['setup_state'], 'login_required')
        self.assertFalse(any(event.get('type')=='results' and event.get('request_id')=='expired-search'
                             for event in events))

    def test_status_does_not_say_ready_while_reauthentication_is_active(self):
        started = threading.Event()
        release = threading.Event()
        real_init = catalog.Catalog.__init__

        def previously_signed_in(instance):
            real_init(instance)
            instance.authenticated = True

        def slow_offline_login(instance, user, password):
            started.set()
            self.assertTrue(release.wait(2), 'test did not release login')
            instance.authenticated = True

        def requests_during_login():
            yield json.dumps({'protocol_version':1,'request_id':'relogin-1','op':'login',
                              'user':'fixture-user','password':'fixture-password'})+'\n'
            self.assertTrue(started.wait(2), 'offline re-login did not start')
            yield json.dumps({'protocol_version':1,'request_id':'status-during-login','op':'status'})+'\n'
            release.set()
            yield json.dumps({'op':'quit'})+'\n'

        output = io.StringIO()
        with patch.object(catalog.Catalog, '__init__', previously_signed_in), \
                patch.object(catalog.Catalog, 'login', slow_offline_login), \
                patch.object(sys, 'stdin', requests_during_login()), contextlib.redirect_stdout(output):
            catalog.main()
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        status = next(event for event in events if event.get('request_id')=='status-during-login')
        self.assertEqual(status['auth_state'], 'signing_in')
        self.assertEqual(status['setup_state'], 'signing_in')
        self.assertTrue(status['busy'])

    def test_v1_errors_are_stable_and_correlated(self):
        protocol_cases = [
            ({'protocol_version':2,'request_id':'old-client','op':'status'},
            {'type':'error','code':'unsupported_protocol_version','message':'This catalog adapter supports protocol version 1.',
             'request_id':'old-client','supported_protocol_version':1}),
            ({'protocol_version':1,'op':'status'},
             {'type':'error','code':'request_id_required','message':'Protocol version 1 requests require a request ID.'}),
            ({'protocol_version':1,'request_id':'request with space','op':'status'},
             {'type':'error','code':'invalid_request_id','message':'Request ID must be 1-64 ASCII letters, digits, or . _ : - characters.'}),
        ]
        for request, expected in protocol_cases:
            with self.subTest(code=expected['code']):
                events = self.run_cli(json.dumps(request)+'\n'+json.dumps({'op':'quit'})+'\n')
                self.assertEqual(events, [expected])
        for request, expected_error in [
            ({'protocol_version':1,'request_id':'unknown-1','op':'frobnicate'},
             {'type':'error','protocol_version':1,'request_id':'unknown-1','code':'unknown_operation','message':'Unknown operation.'}),
            ({'protocol_version':1,'request_id':'bad-id','op':'details','id':'42'},
             {'type':'error','protocol_version':1,'request_id':'bad-id','code':'invalid_request','message':'Song ID must be a positive integer.'}),
        ]:
            with self.subTest(code=expected_error['code']):
                events = self.run_cli(json.dumps(request)+'\n'+json.dumps({'op':'quit'})+'\n')
                self.assertEqual(events[0], expected_error)
                self.assertEqual(events[1], {'type':'idle','protocol_version':1,
                                              'request_id':request['request_id']})

    def test_disabled_download_is_rejected_before_backend_or_installer(self):
        request = {'protocol_version':1,'request_id':'download-denied','op':'download',
                   'id':42,'url':'https://www.youtube.com/watch?v=ABCDEFGHIJK','root':'/never-created'}
        with patch.object(catalog.Catalog, 'details', side_effect=AssertionError('catalog access forbidden')), \
                patch.object(catalog, 'install_song', side_effect=AssertionError('installer invocation forbidden')):
            events = self.run_cli(json.dumps(request)+'\n'+json.dumps({'op':'quit'})+'\n')
        self.assertEqual(events, [{'type':'error','protocol_version':1,'request_id':'download-denied',
                                   'code':'download_disabled','message':'Downloads are disabled for this adapter session.'},
                                  {'type':'idle','protocol_version':1,'request_id':'download-denied'}])

    def test_legacy_search_preserves_revision_without_v1_marker(self):
        with patch.object(catalog.Catalog, 'search', return_value=[]):
            events = self.run_cli(json.dumps({'op':'search','artist':'A','title':'B','revision':3})+'\n'+
                                  json.dumps({'op':'quit'})+'\n')
        self.assertEqual(events[0]['revision'], 3)
        self.assertNotIn('protocol_version', events[0])
        self.assertEqual(events[1], {'type':'idle','revision':3})

    def test_v1_busy_error_correlates_to_rejected_request(self):
        started = threading.Event()
        release = threading.Event()

        def slow_search(instance, artist, title, offset=0):
            started.set()
            self.assertTrue(release.wait(2), 'test did not release offline search')
            return []

        def requests():
            yield json.dumps({'protocol_version':1,'request_id':'active-1','op':'search',
                              'artist':'A','title':'B'})+'\n'
            self.assertTrue(started.wait(2), 'offline search did not start')
            yield json.dumps({'protocol_version':1,'request_id':'rejected-2','op':'search',
                              'artist':'C','title':'D'})+'\n'
            release.set()
            yield json.dumps({'op':'quit'})+'\n'

        output = io.StringIO()
        with patch.object(catalog.Catalog, 'search', slow_search), \
                patch.object(sys, 'stdin', requests()), contextlib.redirect_stdout(output):
            catalog.main()
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        busy = next(event for event in events if event.get('request_id')=='rejected-2')
        self.assertEqual(busy, {'type':'error','protocol_version':1,'request_id':'rejected-2',
                                'code':'busy','message':'An operation is already running.',
                                'retryable':True})
        self.assertTrue(any(event.get('type')=='results' and event.get('request_id')=='active-1'
                            for event in events))

    def test_v1_progress_and_install_result_keep_request_correlation(self):
        media_url = 'https://www.youtube.com/watch?v=ABCDEFGHIJK'

        def fake_install(root, song_id, chart, url, cancelled, notify):
            self.assertEqual((root, song_id, url), ('/fixture/library', 42, media_url))
            self.assertEqual(chart, CHART)
            notify('progress', percent=25.0)
            return '/fixture/library/USDB-42'

        request = {'protocol_version':1,'request_id':'download-fixture','op':'download',
                   'id':42,'url':media_url,'root':'/fixture/library'}
        with patch.object(catalog.Catalog, 'details', return_value=(CHART, [media_url])), \
                patch.object(catalog, 'install_song', fake_install):
            events = self.run_cli(json.dumps(request)+'\n'+json.dumps({'op':'quit'})+'\n',
                                  downloads_enabled=True)
        self.assertEqual(events, [
            {'type':'progress','protocol_version':1,'request_id':'download-fixture','percent':25.0},
            {'type':'installed','protocol_version':1,'request_id':'download-fixture',
             'folder':'/fixture/library/USDB-42','id':42},
            {'type':'idle','protocol_version':1,'request_id':'download-fixture'},
        ])

    def test_v1_controls_acknowledge_with_request_id_and_legacy_stays_silent(self):
        events = self.run_cli(
            json.dumps({'protocol_version':1,'request_id':'cancel-idle','op':'cancel'})+'\n'+
            json.dumps({'protocol_version':1,'request_id':'quit-idle','op':'quit'})+'\n')
        self.assertEqual(events, [
            {'type':'control_ack','protocol_version':1,'request_id':'cancel-idle',
             'command':'cancel','accepted':False,'target_request_id':None,
             'code':'no_active_operation','semantics':'cancel_before_publication'},
            {'type':'control_ack','protocol_version':1,'request_id':'quit-idle',
             'command':'quit','accepted':True,'target_request_id':None,
             'code':'process_exit_requested','semantics':'exit_after_bounded_worker_join'},
        ])
        self.assertEqual(self.run_cli(json.dumps({'op':'cancel'})+'\n'+
                                      json.dumps({'op':'quit'})+'\n'), [])

    def test_download_control_linearizes_cancellation_at_publication(self):
        control = catalog.DownloadControl()
        self.assertTrue(control.request_cancel())
        self.assertTrue(control.is_set())
        self.assertFalse(control.begin_publication())

        control.clear()
        self.assertTrue(control.begin_publication())
        self.assertFalse(control.request_cancel())
        self.assertFalse(control.is_set())

    def test_legacy_event_argument_remains_compatible_with_publication_check(self):
        cancelled = threading.Event()
        self.assertTrue(catalog.begin_publication(cancelled))
        cancelled.set()
        self.assertFalse(catalog.begin_publication(cancelled))

    @unittest.skipIf(os.name == 'nt', 'native Windows installer suite covers direct Event callers')
    def test_install_song_accepts_legacy_threading_event_offline(self):
        media_url = 'https://www.youtube.com/watch?v=ABCDEFGHIJK'
        cancelled = threading.Event()

        class FakeDownloader:
            def __init__(self, command, **kwargs):
                output = Path(command[command.index('-o') + 1])
                output.write_bytes(b'fixture-media-' * 4)
                self.stdout = io.StringIO()
                self.pid = 2147483647
                self.returncode = 0

            def poll(self):
                return 0

            def wait(self, timeout=None):
                return 0

        verified_audio = type('Completed', (), {
            'returncode':0,
            'stdout':b'{"streams":[{"codec_type":"audio"}]}'})()
        with tempfile.TemporaryDirectory(prefix='catalog-legacy-event-') as temporary:
            root = Path(temporary) / 'songs'
            with patch.object(catalog.shutil, 'which', side_effect=lambda name: '/fixture/' + name), \
                    patch.object(catalog.subprocess, 'Popen', FakeDownloader), \
                    patch.object(catalog.subprocess, 'run', return_value=verified_audio), \
                    patch.object(catalog.os, 'killpg', return_value=None, create=True):
                installed = catalog.install_song(root, 42, CHART, media_url, cancelled)
            target = Path(installed)
            self.assertEqual(target.name, 'USDB-42')
            self.assertEqual(sorted(path.name for path in target.iterdir()),
                             ['media.mp4', 'song.txt', 'source.json'])

    def test_v1_cancel_ack_targets_active_download(self):
        started = threading.Event()
        media_url = 'https://www.youtube.com/watch?v=ABCDEFGHIJK'

        def blocked_install(root, song_id, chart, url, cancelled, notify):
            started.set()
            self.assertTrue(cancelled.wait(2), 'cancel request did not reach download')
            raise ValueError('Download cancelled.')

        def requests():
            yield json.dumps({'protocol_version':1,'request_id':'download-target','op':'download',
                              'id':42,'url':media_url,'root':'/fixture/library'})+'\n'
            self.assertTrue(started.wait(2), 'offline installer did not start')
            yield json.dumps({'protocol_version':1,'request_id':'cancel-target','op':'cancel'})+'\n'
            yield json.dumps({'op':'quit'})+'\n'

        output = io.StringIO()
        with patch.object(catalog.Catalog, 'details', return_value=(CHART, [media_url])), \
                patch.object(catalog, 'install_song', blocked_install), \
                patch.object(sys, 'stdin', requests()), contextlib.redirect_stdout(output):
            catalog.main(downloads_enabled=True)
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        acknowledgement = next(event for event in events if event.get('request_id')=='cancel-target')
        self.assertEqual(acknowledgement, {
            'type':'control_ack','protocol_version':1,'request_id':'cancel-target',
            'command':'cancel','accepted':True,'target_request_id':'download-target',
            'code':'cancel_requested','semantics':'cancel_before_publication'})
        self.assertTrue(any(event.get('type')=='error' and event.get('request_id')=='download-target' and
                            event.get('code')=='operation_cancelled' for event in events))

    def test_v1_cancel_after_publication_boundary_reports_too_late(self):
        publication_started = threading.Event()
        release_publication = threading.Event()
        media_url = 'https://www.youtube.com/watch?v=ABCDEFGHIJK'

        def publishing_install(root, song_id, chart, url, control, notify):
            self.assertTrue(control.begin_publication())
            publication_started.set()
            self.assertTrue(release_publication.wait(2), 'test did not release publication')
            return '/fixture/library/USDB-42'

        def requests():
            yield json.dumps({'protocol_version':1,'request_id':'publish-target','op':'download',
                              'id':42,'url':media_url,'root':'/fixture/library'})+'\n'
            self.assertTrue(publication_started.wait(2), 'publication boundary was not reached')
            yield json.dumps({'protocol_version':1,'request_id':'cancel-too-late','op':'cancel'})+'\n'
            release_publication.set()
            yield json.dumps({'op':'quit'})+'\n'

        output = io.StringIO()
        with patch.object(catalog.Catalog, 'details', return_value=(CHART, [media_url])), \
                patch.object(catalog, 'install_song', publishing_install), \
                patch.object(sys, 'stdin', requests()), contextlib.redirect_stdout(output):
            catalog.main(downloads_enabled=True)
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        acknowledgement = next(event for event in events if event.get('request_id')=='cancel-too-late')
        self.assertEqual(acknowledgement, {
            'type':'control_ack','protocol_version':1,'request_id':'cancel-too-late',
            'command':'cancel','accepted':False,'target_request_id':'publish-target',
            'code':'too_late_publication_started','semantics':'cancel_before_publication'})
        self.assertTrue(any(event.get('type')=='installed' and event.get('request_id')=='publish-target'
                            for event in events))

    def test_v1_cancel_reports_non_cancellable_active_search(self):
        started = threading.Event()
        release = threading.Event()

        def slow_search(instance, artist, title, offset=0):
            started.set()
            self.assertTrue(release.wait(2), 'test did not release search')
            return []

        def requests():
            yield json.dumps({'protocol_version':1,'request_id':'search-target','op':'search',
                              'artist':'A','title':'B'})+'\n'
            self.assertTrue(started.wait(2), 'offline search did not start')
            yield json.dumps({'protocol_version':1,'request_id':'cancel-search','op':'cancel'})+'\n'
            release.set()
            yield json.dumps({'op':'quit'})+'\n'

        output = io.StringIO()
        with patch.object(catalog.Catalog, 'search', slow_search), \
                patch.object(sys, 'stdin', requests()), contextlib.redirect_stdout(output):
            catalog.main()
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        acknowledgement = next(event for event in events if event.get('request_id')=='cancel-search')
        self.assertEqual(acknowledgement, {
            'type':'control_ack','protocol_version':1,'request_id':'cancel-search',
            'command':'cancel','accepted':False,'target_request_id':'search-target',
            'code':'operation_not_cancellable','semantics':'cancel_before_publication'})
        self.assertTrue(any(event.get('type')=='results' and event.get('request_id')=='search-target'
                            for event in events))

    def test_v1_quit_ack_targets_active_operation(self):
        started = threading.Event()
        media_url = 'https://www.youtube.com/watch?v=ABCDEFGHIJK'

        def blocked_install(root, song_id, chart, url, cancelled, notify):
            started.set()
            self.assertTrue(cancelled.wait(2), 'quit request did not signal active operation')
            raise ValueError('Download cancelled.')

        def requests():
            yield json.dumps({'protocol_version':1,'request_id':'download-before-quit','op':'download',
                              'id':42,'url':media_url,'root':'/fixture/library'})+'\n'
            self.assertTrue(started.wait(2), 'offline installer did not start')
            yield json.dumps({'protocol_version':1,'request_id':'quit-active','op':'quit'})+'\n'

        output = io.StringIO()
        with patch.object(catalog.Catalog, 'details', return_value=(CHART, [media_url])), \
                patch.object(catalog, 'install_song', blocked_install), \
                patch.object(sys, 'stdin', requests()), contextlib.redirect_stdout(output):
            catalog.main(downloads_enabled=True)
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        acknowledgement = next(event for event in events if event.get('request_id')=='quit-active')
        self.assertEqual(acknowledgement, {
            'type':'control_ack','protocol_version':1,'request_id':'quit-active',
            'command':'quit','accepted':True,'target_request_id':'download-before-quit',
            'code':'process_exit_requested','semantics':'exit_after_bounded_worker_join'})

    def test_v1_download_cancellation_has_stable_error_code(self):
        media_url = 'https://www.youtube.com/watch?v=ABCDEFGHIJK'

        def fake_cancelled_install(root, song_id, chart, url, cancelled, notify):
            cancelled.set()
            raise ValueError('Download cancelled.')

        request = {'protocol_version':1,'request_id':'download-cancelled','op':'download',
                   'id':42,'url':media_url,'root':'/fixture/library'}
        with patch.object(catalog.Catalog, 'details', return_value=(CHART, [media_url])), \
                patch.object(catalog, 'install_song', fake_cancelled_install):
            events = self.run_cli(json.dumps(request)+'\n'+json.dumps({'op':'quit'})+'\n',
                                  downloads_enabled=True)
        self.assertEqual(events, [
            {'type':'error','protocol_version':1,'request_id':'download-cancelled',
             'code':'operation_cancelled','message':'Download cancelled.'},
            {'type':'idle','protocol_version':1,'request_id':'download-cancelled'},
        ])

    def test_unified_query_matches_artist_or_title_and_deduplicates_ids(self):
        first = {'id':42,'artist':'Adele','title':'Hello','language':'en'}
        second = {'id':43,'artist':'Someone','title':'Adele tribute','language':'en'}
        with patch.object(catalog.Catalog, 'search', side_effect=[[first], [first, second]]) as search:
            events = self.run_cli(json.dumps({'protocol_version':1,'request_id':'combined',
                'op':'search','query':'Adele'})+'\n'+json.dumps({'op':'quit'})+'\n')
        self.assertEqual(search.call_args_list, [unittest.mock.call('Adele', '', 0), unittest.mock.call('', 'Adele', 0)])
        self.assertEqual(events[0]['songs'], [first, second])

    def test_search_cache_uses_query_and_returns_independent_rows(self):
        instance = catalog.Catalog(); instance.authenticated = True
        row = '<tr class="list_tr1"><td><a onclick="show_detail(42)">Adele</a></td><td>Hello</td><td></td><td></td><td></td><td></td><td>English</td></tr>'
        with patch.object(instance, 'request', return_value=row) as request:
            first = instance.search('Adele', '')
            first[0]['title'] = 'changed locally'
            second = instance.search('ADELE', '')
            self.assertEqual(second[0]['title'], 'Hello')
            self.assertEqual(request.call_count, 1)

    def test_search_trims_values_before_request_and_cache_key(self):
        instance = catalog.Catalog(); instance.authenticated = True
        with patch.object(instance, 'request', return_value='') as request:
            instance.search('  Adele  ', '\tHello ')
            instance.search('Adele', 'Hello')
            self.assertEqual(request.call_count, 1)
            sent = request.call_args[0][1]
            self.assertEqual(sent['interpret'], 'Adele')
            self.assertEqual(sent['title'], 'Hello')

    def test_search_cache_expires(self):
        instance = catalog.Catalog(); instance.authenticated = True
        with patch.object(instance, 'request', return_value='') as request:
            with patch.object(catalog.time, 'monotonic', return_value=100): instance.search('Adele', '')
            with patch.object(catalog.time, 'monotonic', return_value=401): instance.search('Adele', '')
            self.assertEqual(request.call_count, 2)

    def test_signed_out_session_does_not_reuse_authenticated_cache(self):
        instance = catalog.Catalog(); instance.authenticated = True
        with patch.object(instance, 'request', return_value='') as request:
            instance.search('Adele', '')
            instance.authenticated = False
            instance.search('Adele', '')
            self.assertEqual(request.call_count, 2)

if __name__ == '__main__':
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ParserAndProtocolTests))
    raise SystemExit(0 if result.wasSuccessful() else 1)
