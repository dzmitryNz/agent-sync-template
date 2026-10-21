import json, os, pathlib, sys, tempfile, unittest, datetime, io, contextlib

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import mine


class SinceLastRetro(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.proj = self.tmp / 'proj'
        self.proj.mkdir()
        self.stamp = self.tmp / 'last-run'
        for name, day in (('old', 10), ('mid', 16), ('new', 20)):
            p = self.proj / f'{name}.jsonl'
            p.write_text('')
            t = datetime.datetime(2026, 9, day).timestamp()
            os.utime(p, (t, t))

    def names(self, files):
        return [f.stem for f in files]

    def test_takes_sessions_newer_than_stamp(self):
        self.stamp.write_text('2026-09-15T16:26\n')
        files, since = mine.select_files(self.proj, self.stamp, None)
        self.assertEqual(self.names(files), ['mid', 'new'])
        self.assertEqual(since, '2026-09-15T16:26')

    def test_explicit_n_overrides_stamp(self):
        self.stamp.write_text('2026-09-15T16:26\n')
        files, since = mine.select_files(self.proj, self.stamp, 1)
        self.assertEqual(self.names(files), ['new'])
        self.assertIsNone(since)

    def test_without_stamp_falls_back_to_default_window(self):
        files, since = mine.select_files(self.proj, self.stamp, None, default_n=2)
        self.assertEqual(self.names(files), ['mid', 'new'])
        self.assertIsNone(since)

    def test_mark_writes_now(self):
        mine.mark(self.stamp, datetime.datetime(2026, 9, 23, 19, 30))
        self.assertEqual(self.stamp.read_text().strip(), '2026-09-23T19:30')


class Shape(unittest.TestCase):
    def test_git_c_after_cd(self):
        self.assertEqual(mine.shape('cd X && git -C /r diff --stat'), 'git diff')

    def test_echo_skipped_sed_basename(self):
        self.assertEqual(mine.shape("echo '== a =='; sed -n 1,5p f"), 'sed')

    def test_herdr_chain(self):
        self.assertEqual(
            mine.shape('herdr workspace get w1; herdr workspace list'),
            'herdr workspace ; herdr workspace',
        )

    def test_env_prefix(self):
        self.assertEqual(mine.shape('FOO=1 BAR=2 git status'), 'git status')

    def test_pipe_split(self):
        self.assertEqual(mine.shape('git status | wc -l'), 'git status ; wc')


class ToolOutputSizes(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())

    def _write(self, name, records):
        p = self.tmp / name
        with p.open('w') as f:
            for r in records:
                f.write(json.dumps(r) + '\n')
        return p

    def test_string_and_list_results(self):
        p = self._write('abcd1234.jsonl', [
            {'message': {'content': [
                {'type': 'tool_use', 'id': '1', 'name': 'Bash',
                 'input': {'command': 'git status'}},
                {'type': 'tool_use', 'id': '2', 'name': 'Read',
                 'input': {'file_path': '/a'}},
            ]}},
            {'message': {'content': [
                {'type': 'tool_result', 'tool_use_id': '1', 'content': 'abc'},
                {'type': 'tool_result', 'tool_use_id': '2',
                 'content': [{'type': 'text', 'text': 'xy'}]},
            ]}},
        ])
        tools, shapes = mine.tool_output_sizes(p)
        self.assertEqual(tools['Bash']['n'], 1)
        self.assertEqual(tools['Bash']['chars'], 3)
        self.assertEqual(tools['Read']['n'], 1)
        self.assertEqual(tools['Read']['chars'], 2)
        self.assertEqual(shapes['git status']['n'], 1)
        self.assertEqual(shapes['git status']['chars'], 3)

    def test_excludes_mine_self(self):
        p = self._write('mine0001.jsonl', [
            {'message': {'content': [
                {'type': 'tool_use', 'id': '1', 'name': 'Bash',
                 'input': {'command': 'python3 skills/retro/scripts/mine.py -n 5'}},
            ]}},
            {'message': {'content': [
                {'type': 'tool_result', 'tool_use_id': '1', 'content': 'x' * 100},
            ]}},
        ])
        tools, shapes = mine.tool_output_sizes(p)
        self.assertEqual(tools, {})
        self.assertEqual(shapes, {})


class CostlyBlockPrint(unittest.TestCase):
    def test_main_prints_third_block(self):
        tmp = pathlib.Path(tempfile.mkdtemp())
        proj = tmp / 'proj'
        proj.mkdir()
        f = proj / 'sess0001.jsonl'
        f.write_text(json.dumps({
            'message': {'content': [
                {'type': 'tool_use', 'id': '1', 'name': 'Bash',
                 'input': {'command': 'git status'}},
            ]}
        }) + '\n' + json.dumps({
            'message': {'content': [
                {'type': 'tool_result', 'tool_use_id': '1', 'content': 'ok'},
            ]}
        }) + '\n')
        stamp = tmp / 'last-run'
        buf = io.StringIO()
        old_proj, old_last, old_hist = mine.PROJ, mine.LAST_RUN, mine.HISTORY
        try:
            mine.PROJ = proj
            mine.LAST_RUN = stamp
            mine.HISTORY = tmp / 'no-history.jsonl'
            with contextlib.redirect_stdout(buf):
                sys.argv = ['mine.py', '-n', '1', '--min-sessions', '1', '--no-history']
                mine.main()
        finally:
            mine.PROJ, mine.LAST_RUN, mine.HISTORY = old_proj, old_last, old_hist
        out = buf.getvalue()
        self.assertIn('## Expensive commands', out)


if __name__ == '__main__':
    unittest.main()
