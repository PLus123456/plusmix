#!/usr/bin/env python3
"""scripts/soak/leaks_report.py 的用例：xctrace export 的 id / ref 去重、按列名归类（W4-A，S2 的 Leaks 证据）。"""
import os
import sys
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import leaks_report as lr  # noqa: E402

SAMPLE = b"""<?xml version="1.0"?>
<trace-query-result>
<node xpath='//trace-toc[1]/run[1]/data[1]/table[5]'>
<schema name="leaks"><col><mnemonic>address</mnemonic><name>Address</name></col><col><mnemonic>size</mnemonic><name>Size</name></col>
<col><mnemonic>responsible-library</mnemonic><name>Responsible Library</name></col><col><mnemonic>responsible-frame</mnemonic><name>Responsible Frame</name></col></schema>
<row><address id="1" fmt="0x600001234000">105553116479488</address><size id="2" fmt="64 Bytes">64</size>
  <responsible-library id="3" fmt="SwitcherOutputs">SwitcherOutputs</responsible-library><responsible-frame id="4" fmt="Recorder.start(at:)">Recorder.start(at:)</responsible-frame></row>
<row><address id="5" fmt="0x600001235000">105553116483584</address><size ref="2"/><responsible-library ref="3"/><responsible-frame ref="4"/></row>
<row><address id="6" fmt="0x600001236000">105553116487680</address><size id="7" fmt="1.50 KiB">1536</size>
  <responsible-library id="8" fmt="VideoToolbox">VideoToolbox</responsible-library><responsible-frame id="9" fmt="VTCompressionSessionCreate">VTCompressionSessionCreate</responsible-frame></row>
</node></trace-query-result>"""


class LeaksParseTests(unittest.TestCase):
    def test_S2_leaksExportRefsResolveAndGroupByResponsible(self):
        cols, rows = lr.parse_rows(SAMPLE)
        self.assertEqual(cols, ["address", "size", "responsible-library", "responsible-frame"])
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[1]["size"], ("64", "64 Bytes"), "ref 要解回第一次出现的值")
        s = lr.summarize(cols, rows)
        self.assertEqual(s["rows"], 3)
        self.assertEqual(s["unique_addresses"], 3)
        self.assertEqual(s["total_bytes"], 64 + 64 + 1536)
        top = {t["key"]: t for t in s["top"]}
        self.assertEqual(top["SwitcherOutputs · Recorder.start(at:)"]["count"], 2)
        self.assertEqual(top["SwitcherOutputs · Recorder.start(at:)"]["owner"], "W1-E（SwitcherOutputs）")
        self.assertIn("系统库", top["VideoToolbox · VTCompressionSessionCreate"]["owner"])

    def test_S2_sizeParsingUnits(self):
        self.assertEqual(lr.to_bytes("", "1.50 KiB"), 1536)
        self.assertEqual(lr.to_bytes("64", ""), 64)
        self.assertEqual(lr.to_bytes("", "2 MB"), 2 * 1024 * 1024)
        self.assertIsNone(lr.to_bytes("abc", "n/a"))


if __name__ == "__main__":
    unittest.main()
