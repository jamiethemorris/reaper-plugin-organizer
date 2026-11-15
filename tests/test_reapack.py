"""Check the generated ReaPack package without touching REAPER user data."""
from pathlib import Path
import hashlib
import re
import subprocess
import unittest
from urllib.parse import unquote, urlparse
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
MAIN = 'REAPER Plugin Organizer.lua'


class ReaPackPackageTest(unittest.TestCase):
    def test_index_installs_complete_macos_package(self):
        index = ROOT / 'index.xml'
        self.assertTrue(index.is_file(), 'Generate index.xml with reapack-index first')
        # Parse only our generated repository index; ElementTree does not resolve external entities.
        tree = ET.parse(index).getroot()
        self.assertEqual(tree.attrib['version'], '1')
        self.assertEqual(tree.attrib['name'], 'REAPER Plugin Organizer')
        packages = tree.findall('./category/reapack')
        self.assertEqual(len(packages), 1, 'Only the organizer should be a package')
        package = packages[0]
        self.assertEqual(package.attrib['name'], MAIN)
        self.assertEqual(package.attrib['type'], 'script')
        match = re.search(r'@version (\S+)', (ROOT / 'reaper' / MAIN).read_text())
        assert match is not None
        version = match[1]
        release = package.find(f"./version[@name='{version}']")
        self.assertIsNotNone(release, 'Current version must be indexed')
        assert release is not None
        sources = release.findall('source')
        expected = {MAIN} | {f'lib/{p.name}' for p in (ROOT / 'reaper/lib').glob('*.lua')}
        self.assertEqual({s.get('file', MAIN) for s in sources}, expected)
        self.assertEqual(len(sources), len(expected))
        for source in sources:
            target = source.get('file', MAIN)
            self.assertEqual(source.get('platform'), 'darwin')
            if target == MAIN:
                self.assertIn(source.get('main'), ('main', 'true'))
            else:
                self.assertIsNone(source.get('main'), 'Libraries must not become actions')
            assert source.text is not None
            url = urlparse(source.text.strip())
            self.assertEqual(url.scheme, 'https')
            self.assertEqual(url.netloc, 'raw.githubusercontent.com')
            owner, repo, commit, path = unquote(url.path).lstrip('/').split('/', 3)
            self.assertEqual((owner, repo), ('jamiethemorris', 'reaper-plugin-organizer'))
            self.assertRegex(commit, r'^[0-9a-f]{40}$')
            self.assertEqual(path, f'reaper/{target}')
            data = subprocess.check_output(['git', 'show', f'{commit}:{path}'], cwd=ROOT)
            self.assertEqual(data, (ROOT / path).read_bytes(), 'Bump @version after runtime changes')
            self.assertEqual(source.get('hash'), '1220' + hashlib.sha256(data).hexdigest())


if __name__ == '__main__':
    unittest.main()
