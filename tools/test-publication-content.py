#!/usr/bin/env python3
"""Synthetic disclosure checker tests; no actual developer identity is a fixture."""
import importlib.util, io, json, plistlib, tempfile, unittest, zipfile
from pathlib import Path
s=importlib.util.spec_from_file_location('checker',Path(__file__).with_name('check-publication-content.py'));m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
class Checks(unittest.TestCase):
 def setUp(self):
  self.t=tempfile.TemporaryDirectory();self.root=Path(self.t.name);self.c={'terms':['Example Person'],'private_values':['device-example-001']}
 def tearDown(self):self.t.cleanup()
 def run_data(self,name,data):
  p=self.root/name;p.write_bytes(data);return m.inspect(p,self.c)
 def test_clean(self):self.assertEqual(self.run_data('a.txt',b'rewindDV maintainers; Test system A')['status'],'PASS')
 def test_gitignore_is_scanned_as_text(self):
  self.assertEqual(self.run_data('.gitignore',b'.build/\n')['status'],'PASS')
  self.assertEqual(self.run_data('.gitignore',b'Example Person')['status'],'BLOCKED')
 def test_directory(self):
  (self.root/'a.txt').write_text('clean content');r=m.inspect(self.root,self.c);self.assertEqual(len(r['files']),1);self.assertTrue(all(x['category'] in {'extended_attribute_requires_review','extended_attributes_uninspected'} for x in r['findings']))
 def test_variants(self):
  for text in ['EXAMPLE PERSON', 'example%20person', 'Example.Person', 'Example%2520Person']:
   for enc in ['utf-8','utf-16-le','utf-16-be','utf-32-le','utf-32-be']:
    self.assertEqual(self.run_data('a.txt',text.encode(enc))['status'],'BLOCKED')
 def test_plist(self):self.assertEqual(self.run_data('a.plist',plistlib.dumps({'who':'device-example-001'},fmt=plistlib.FMT_BINARY))['status'],'BLOCKED')
 def test_zip_comment_and_nested(self):
  b=io.BytesIO()
  with zipfile.ZipFile(b,'w') as z:z.comment=b'Example Person';z.writestr('a.txt','clean')
  r=self.run_data('a.zip',b.getvalue());self.assertEqual(r['status'],'BLOCKED');self.assertNotIn('Example Person',json.dumps(r))
 def test_zip_root_named_text(self):
  b=io.BytesIO()
  with zipfile.ZipFile(b,'w') as z:
   for name in ['LICENSE','NOTICE','.gitignore']:z.writestr(name,'clean text')
  self.assertEqual(self.run_data('a.zip',b.getvalue())['status'],'PASS')
  b=io.BytesIO()
  with zipfile.ZipFile(b,'w') as z:z.writestr('LICENSE','Example Person')
  self.assertEqual(self.run_data('a.zip',b.getvalue())['status'],'BLOCKED')
 def test_unsafe_zip(self):
  b=io.BytesIO()
  with zipfile.ZipFile(b,'w') as z:z.writestr('../outside.txt','clean')
  self.assertEqual(self.run_data('a.zip',b.getvalue())['status'],'BLOCKED')
 def test_image_gap(self):self.assertEqual(self.run_data('a.png',b'placeholder')['status'],'BLOCKED')
 def test_symlink(self):
  (self.root/'alias').symlink_to('/nonexistent/example');r=m.inspect(self.root,self.c);self.assertEqual(r['status'],'BLOCKED')
if __name__=='__main__':unittest.main()
