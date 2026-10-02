import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]


class EvidenceModeTests(unittest.TestCase):
    def invoke(self, *, evidence=False, required=False, dirty=False, build_exit=0, collect_exit=0):
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        scripts = root / 'ios-app/scripts'; scripts.mkdir(parents=True)
        shutil.copyfile(SCRIPTS/'xcodebuild-cli.sh',scripts/'xcodebuild-cli.sh')
        clang = scripts/'xcode-clang-wrapper.sh'; clang.write_text('#!/bin/sh\nexit 0\n');clang.chmod(0o755)
        tools=root/'tools';tools.mkdir()
        (tools/'build_evidence.py').write_text(
            'import json,os,sys\nfrom pathlib import Path\n'
            'if sys.argv[1]=="source": print(json.dumps({"dirty":os.environ["TEST_DIRTY"]=="1"}))\n'
            'else:\n Path(os.environ["TEST_COLLECTED"]).touch()\n raise SystemExit(int(os.environ["TEST_COLLECT_EXIT"]))\n')
        builder=root/'builder';builder.write_text('#!/bin/sh\npython3 -c \'import json,os,sys;open(os.environ["TEST_ARGS"],"w").write(json.dumps(sys.argv[1:]))\' "$@"\nexit "$TEST_BUILD_EXIT"\n');builder.chmod(0o755)
        arguments=root/'arguments.json';collected=root/'collected'
        environment={**os.environ,'XCODEBUILD_PATH':str(builder),'TEST_ARGS':str(arguments),
            'TEST_COLLECTED':str(collected),'TEST_DIRTY':str(int(dirty)),
            'TEST_BUILD_EXIT':str(build_exit),'TEST_COLLECT_EXIT':str(collect_exit),
            'BICINO_COLLECT_BUILD_EVIDENCE':str(int(evidence)), 'BICINO_REQUIRE_BUILD_EVIDENCE':str(int(required))}
        result=subprocess.run(['bash',str(scripts/'xcodebuild-cli.sh'),'-scheme','BikeComputer',
            '-derivedDataPath',str(root/'derived'),'-configuration','Debug','build'],
            env=environment,capture_output=True,text=True)
        return result, json.loads(arguments.read_text()) if arguments.exists() else None, collected.exists()

    def test_ordinary_dirty_build_has_no_symbol_generation_or_collection(self):
        result,args,collected=self.invoke(dirty=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(any(arg.startswith('DEBUG_INFORMATION_FORMAT=') for arg in args))
        self.assertFalse(collected)

    def test_evidence_is_explicit_and_requires_clean_source_before_build(self):
        result,args,collected=self.invoke(evidence=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('DEBUG_INFORMATION_FORMAT=dwarf-with-dsym',args);self.assertTrue(collected)
        result,args,collected=self.invoke(evidence=True,dirty=True)
        self.assertNotEqual(result.returncode,0);self.assertIsNone(args);self.assertFalse(collected)

    def test_ci_collection_and_build_failures_remain_fatal(self):
        result,_,collected=self.invoke(required=True,collect_exit=1)
        self.assertNotEqual(result.returncode,0);self.assertTrue(collected)
        result,_,collected=self.invoke(required=True,build_exit=7)
        self.assertEqual(result.returncode,7);self.assertFalse(collected)


if __name__=='__main__': unittest.main()
