import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "portable"))
from encoder import Cancelled, EncodeError, Job, PRESETS, encode, executable, latest_video, metadata


class EncoderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="encoder-tests-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.folder = Path(cls.temp.name)
        cls.fixture = cls.folder / "Sample Screen Recording.mov"
        cls.ffmpeg = executable("ffmpeg")
        cls.ffprobe = executable("ffprobe")
        subprocess.run([
            cls.ffmpeg, "-hide_banner", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=720x1280:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "2",
            "-c:v", "prores_ks", "-profile:v", "2", "-threads:v", "2", "-c:a", "pcm_s16le", str(cls.fixture),
        ], check=True)

    def test_latest_and_empty_transfer(self):
        downloads = self.folder / "Downloads"
        downloads.mkdir()
        complete = downloads / self.fixture.name
        complete.write_bytes(b"used for filename selection only")
        empty = downloads / "Unfinished.MP4"
        empty.touch()
        os.utime(empty, (2_000_000_000, 2_000_000_000))
        self.assertEqual(latest_video(downloads), complete)

    def test_all_presets_preserve_audio_duration_and_original(self):
        outputs = self.folder / "Encoded"
        original = self.fixture.stat().st_size
        for name, preset in PRESETS.items():
            with self.subTest(preset=name):
                stages = []
                output, description = encode(
                    self.fixture, outputs, preset, True, Job(), lambda stage, _: stages.append(stage),
                )
                self.assertIn("Original kept", description)
                self.assertEqual(self.fixture.stat().st_size, original)
                self.assertLess(output.stat().st_size, original)
                duration, video, audio = metadata(output, self.ffprobe, Job())
                self.assertAlmostEqual(duration, 2, delta=0.1)
                self.assertEqual(audio, 1)
                self.assertEqual(video["codec_name"], "h264")
                self.assertIn("Verifying", stages)
        with self.assertRaises(EncodeError):
            encode(self.fixture, outputs, PRESETS["Fastest"], True, Job(), lambda *_: None)

    def test_cancel_removes_staging_and_keeps_original(self):
        folder = self.folder / "Canceled"
        job = Job()

        def update(stage, percent):
            if stage == "Encoding" and percent > 0:
                job.cancel()

        with patch("encoder.send2trash") as trash:
            with self.assertRaises(Cancelled):
                encode(self.fixture, folder, PRESETS["Highest Quality"], False, job, update)
            trash.assert_not_called()
        self.assertTrue(self.fixture.is_file())
        self.assertEqual(list(folder.iterdir()), [])

    def test_cleanup_runs_after_verified_output(self):
        folder = self.folder / "Cleanup"
        with patch("encoder.send2trash") as trash:
            output, _ = encode(self.fixture, folder, PRESETS["Fastest"], False, Job(), lambda *_: None)
            trash.assert_called_once_with(str(self.fixture))
        self.assertTrue(output.is_file())

    def test_invalid_input_is_not_trashed(self):
        bad_input = self.folder / "Corrupt.mp4"
        bad_input.write_bytes(b"invalid media")
        with patch("encoder.send2trash") as trash:
            with self.assertRaises(EncodeError):
                encode(bad_input, self.folder / "Invalid", PRESETS["Fastest"], False, Job(), lambda *_: None)
            trash.assert_not_called()
        self.assertTrue(bad_input.is_file())


if __name__ == "__main__":
    unittest.main()
