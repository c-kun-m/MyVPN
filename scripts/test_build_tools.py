import json
from pathlib import Path
import tempfile
import unittest
from prepare_go_runtime import prepare, SITES

class RuntimePreparationTests(unittest.TestCase):
    def fixture(self, root):
        source = root / "installed-go"
        for relative, (old, _) in SITES.items():
            path = source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"// source context\n"+old+b"\n")
        (source / "VERSION").write_text("go1.26.1\n")
        return source

    def test_preparation_keeps_installed_runtime_unchanged(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source = self.fixture(root); dest = root / "private-go"
            info = prepare(source, dest)
            for relative, (old, new) in SITES.items():
                self.assertIn(old, (source / relative).read_bytes())
                self.assertIn(new, (dest / relative).read_bytes())
                self.assertNotIn(old, (dest / relative).read_bytes())
            self.assertTrue((dest / ".prepared").exists())
            self.assertEqual(prepare(source, dest), info)

    def test_unknown_layout_fails_before_copying(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source = self.fixture(root); dest = root / "private-go"
            (source / next(iter(SITES))).write_text("unknown implementation")
            with self.assertRaises(ValueError): prepare(source, dest)
            self.assertFalse(dest.exists())

    def test_same_or_nested_root_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source = self.fixture(root)
            for dest in [source, source / "nested", root]:
                with self.assertRaises(ValueError): prepare(source, dest)

    def test_tampered_cached_runtime_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source = self.fixture(root); dest = root / "private-go"
            prepare(source, dest)
            (dest / next(iter(SITES))).write_text("modified")
            with self.assertRaises(ValueError): prepare(source, dest)

    def test_partial_cache_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source = self.fixture(root); dest = root / "private-go"
            dest.mkdir(); (dest / "keep.txt").write_text("keep")
            with self.assertRaises(ValueError): prepare(source, dest)
            self.assertEqual((dest / "keep.txt").read_text(), "keep")

    def test_already_continuous_clock_is_accepted(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source = self.fixture(root); dest = root / "private-go"
            for relative, (_, new) in SITES.items(): (source / relative).write_bytes(new)
            prepare(source, dest)
            for relative in SITES: self.assertEqual((source / relative).read_bytes(), (dest / relative).read_bytes())

if __name__ == "__main__": unittest.main()
