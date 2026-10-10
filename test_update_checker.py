import unittest

from update_checker import check_latest_release, is_newer_version, parse_version


class VersionTests(unittest.TestCase):
    def test_parse(self):
        self.assertEqual((2, 0, 1), parse_version("v2.0.1"))
        self.assertEqual((10, 2, 0), parse_version("10.2.0"))
        self.assertIsNone(parse_version("v2.0"))
        self.assertIsNone(parse_version("v02.0.0"))
        self.assertIsNone(parse_version("v2.0.0-beta"))

    def test_comparison_is_numeric(self):
        self.assertTrue(is_newer_version("v2.10.0", "2.9.9"))
        self.assertFalse(is_newer_version("v2.0.0", "2.0.0"))
        self.assertFalse(is_newer_version("v1.9.9", "2.0.0"))

    def test_release_filtering(self):
        base = {
            "tag_name": "v2.0.1",
            "html_url": "https://github.com/Coruge-to/DenGo-Controller-Converter/releases/tag/v2.0.1",
            "draft": False,
            "prerelease": False,
        }
        self.assertIsNotNone(check_latest_release(lambda: dict(base), "2.0.0"))
        self.assertIsNone(check_latest_release(lambda: dict(base), "2.0.1"))
        self.assertIsNone(check_latest_release(lambda: {**base, "prerelease": True}, "2.0.0"))
        self.assertIsNone(check_latest_release(lambda: {**base, "draft": True}, "2.0.0"))
        self.assertIsNone(check_latest_release(lambda: {**base, "html_url": "https://example.com/x"}, "2.0.0"))
        self.assertIsNone(check_latest_release(lambda: (_ for _ in ()).throw(OSError("offline")), "2.0.0"))


if __name__ == "__main__":
    unittest.main()
