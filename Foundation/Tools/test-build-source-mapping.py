#!/usr/bin/env python3
"""Verify real compiler debug paths, Swift #fileID and C __FILE__ privacy."""
from pathlib import Path
import importlib.util
import os
import shlex
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('app_only_build', Path(__file__).with_name('build-app-only.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SourceMappingTests(unittest.TestCase):
    def test_compilers_emit_neutral_source_paths(self):
        with tempfile.TemporaryDirectory(prefix='source mapping private ') as tmp:
            root = Path(tmp) / 'source with spaces'
            output = Path(tmp) / 'build with spaces'
            root.mkdir(); output.mkdir()
            settings = dict(item.split('=', 1) for item in module.mapped_compiler_flags(root, output))
            swift = root / 'Location.swift'; swift.write_text('print(#fileID)\n')
            c = root / 'location.c'; c.write_text('#include <stdio.h>\nint main(void) { puts(__FILE__); return 0; }\n')
            env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
            for compiler, source, setting, expected in [
                ('swiftc', swift, 'OTHER_SWIFT_FLAGS', 'swiftc/Location.swift'),
                ('clang', c, 'OTHER_CFLAGS', '/rewindDV/source/location.c')]:
                flags = shlex.split(settings[setting].replace('$(inherited)', '', 1))
                binary = output / compiler
                subprocess.run(['xcrun', compiler, '-g', *flags, str(source), '-o', str(binary)], cwd=root, env=env, check=True, capture_output=True)
                actual = subprocess.check_output([str(binary)], text=True).strip()
                self.assertEqual(actual, expected)
                self.assertNotIn(str(root).encode(), binary.read_bytes())
                self.assertNotIn(str(output).encode(), binary.read_bytes())
                obj = output / (compiler + '.o')
                subprocess.run(['xcrun', compiler, '-g', *flags, '-c', str(source), '-o', str(obj)], cwd=root, env=env, check=True, capture_output=True)
                debug = subprocess.check_output(['xcrun', 'dwarfdump', str(obj)], text=True, env=env).split('.debug_info contents:', 1)[1]
                self.assertIn('/rewindDV/source', debug)
                self.assertNotIn(str(root), debug)
                self.assertNotIn(str(output), debug)
                self.assertNotIn(str(root).encode(), obj.read_bytes())


if __name__ == '__main__':
    unittest.main()
