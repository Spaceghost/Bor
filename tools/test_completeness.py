"""Tests for the evidence harness, independent of the compiler under test."""
import sys
import tempfile
import unittest
from pathlib import Path
from completeness import process, fingerprint, classifications, BYTES_PER_SEED
from completeness_cases import CASES


class CompletenessHarnessTests(unittest.TestCase):
    def test_names_are_unique_and_breadth_is_retained(self):
        self.assertEqual(len(CASES), len({c['name'] for c in CASES}))
        self.assertTrue({'scalars','procedures','control','cleanup','aggregates','containers','runtime','packages','metaprogramming'} <= {c['category'] for c in CASES})
        self.assertTrue(any(c['validity']=='invalid' for c in CASES))
        self.assertEqual(BYTES_PER_SEED, 4608)

    def test_fingerprint_detects_source_and_validity_changes(self):
        a=CASES[0]
        self.assertEqual(fingerprint(a),fingerprint(dict(a)))
        self.assertNotEqual(fingerprint(a),fingerprint(dict(a,source=a['source']+'\n')))
        self.assertNotEqual(fingerprint(a),fingerprint(dict(a,validity='invalid')))

    def test_nonzero_exit_is_not_a_pass(self):
        with tempfile.TemporaryDirectory() as d:
            r=process(Path(d),'reject',[sys.executable,'-c','import sys;sys.stderr.write("diagnosis");sys.exit(2)'])
            self.assertEqual(r['state'],'failed')
            self.assertEqual(r['exit'],2)
            self.assertEqual(r['diagnostic'],'diagnosis')

    def test_timeout_is_not_rejection(self):
        with tempfile.TemporaryDirectory() as d:
            r=process(Path(d),'timeout',[sys.executable,'-c','import time;time.sleep(10)'],timeout=0.1)
            self.assertEqual(r['state'],'timeout')
            self.assertNotEqual(r['exit'],0)

    def test_missing_compiler_is_not_rejection(self):
        with tempfile.TemporaryDirectory() as d:
            r=process(Path(d),'missing',[str(Path(d)/'not-a-compiler')])
            self.assertEqual(r['state'],'unavailable')

    def test_classification_keeps_compile_errors_distinct(self):
        r={'paths':{'direct':{'emit':'emitted','cells':{'gcc/O3':{'state':'c-compile-error'}}}}}
        self.assertEqual(classifications(r)['direct']['gcc/O3'],'c-compile-error')


if __name__=='__main__':unittest.main()
