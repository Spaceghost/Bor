"""Tests for measurement summaries and correctness identity."""
import unittest
from matrix import stats, signature, OPT

class MatrixTests(unittest.TestCase):
    def test_summary_preserves_raw_samples(self):
        values = [5.0, 1.0, 3.0, 2.0, 4.0]
        result = stats(values)
        self.assertEqual(result['samples'], values)
        self.assertEqual(result['p50'], 3)
        self.assertEqual(result['p95'], 5)
        self.assertEqual(result['mad'], 1)

    def test_elapsed_time_is_not_correctness_identity(self):
        a = dict(rounds=12,input_bytes=32,output_bytes=56,checksum=7,output_hash=9,elapsed_ns=111)
        b = dict(a,elapsed_ns=222)
        self.assertEqual(signature(a),signature(b))
        self.assertNotEqual(signature(a),signature(dict(b,output_hash=8)))
        self.assertNotEqual(signature(a),signature(dict(b,rounds=13)))

    def test_baseline_has_no_native_or_lto_advantage(self):
        self.assertIn('-march=x86-64', OPT)
        self.assertIn('-fno-lto', OPT)
        self.assertNotIn('-march=native', OPT)

if __name__ == '__main__': unittest.main()
