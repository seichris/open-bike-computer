from pathlib import Path
import json
import re
import subprocess
import unittest


PAGE = (
    Path(__file__).parents[2]
    / "lib"
    / "device_debug"
    / "device_debug_page.hpp"
).read_text(encoding="utf-8")


class DeviceDebugPageTests(unittest.TestCase):
    def test_page_is_offline_and_secret_free(self):
        self.assertNotRegex(PAGE, r"https?://")
        self.assertNotIn("localStorage", PAGE)
        self.assertNotIn("document.cookie", PAGE)
        self.assertNotIn("console.", PAGE)
        self.assertIn("location.hash.slice(1)", PAGE)
        self.assertIn("history.replaceState", PAGE)
        self.assertIn("location.pathname);", PAGE)
        self.assertIn("X-BikeComputer-Transfer-Token", PAGE)
        self.assertIn("Synthetic pointer:", PAGE)
        self.assertNotIn("Touch test", PAGE)

    def test_page_has_frame_and_input_validation(self):
        for text in (
            "BCF1",
            "crc32(payload)",
            "setPointerCapture",
            "pointercancel",
            "visibilitychange",
            "event.key==='Escape'",
            "requestAnimationFrame",
            "AbortController",
            "pointerChain",
            "frameAbortController",
            "pointerInteractionActive",
            "beginPointerInteraction",
            "finishPointerInteraction",
            "canvas.toBlob",
            "capturedAtMs",
            "lastRequestLatencyMs",
            "firmware.gitSha",
            "data.buildProfile",
            "data.viewRotation",
            "shortGitSha",
            "Stale · retry",
            "/device-debug/v1/info",
            "/device-debug/v1/frame?after=",
            "/device-debug/v1/button/boot",
            "BOOT (short press)",
            "displayPoint",
            "panelPoint",
            "pointerLastSequence",
            "pointerSequenceInitialized",
            "eventSequenceInitialized",
            "code==='pointer_sequence'",
            "loadInfo(true)",
        ):
            self.assertIn(text, PAGE)

    def test_no_script_or_style_dependencies(self):
        self.assertIsNone(re.search(r"<(?:script|link)[^>]+src=", PAGE))
        self.assertNotIn("@import", PAGE)

    def test_rotation_and_pointer_inverse_execute_on_asymmetric_geometry(self):
        definitions = []
        for name in ("displayPoint", "panelPoint"):
            match = re.search(rf"const {name}=.*?;", PAGE)
            self.assertIsNotNone(match)
            definitions.append(match.group(0))
        script = "".join(definitions) + """
const fixtures=[];
for(const rotation of [0,1,2,3]) {
  for(const point of [[0,0],[409,0],[0,501],[137,281]]) {
    const displayed=displayPoint(point[0],point[1],410,502,rotation);
    fixtures.push([rotation,point,displayed,panelPoint(displayed[0],displayed[1],410,502,rotation)]);
  }
}
process.stdout.write(JSON.stringify(fixtures));
"""
        completed = subprocess.run(
            ["node", "-e", script],
            check=True,
            capture_output=True,
            text=True,
        )
        fixtures = json.loads(completed.stdout)
        for rotation, source, _displayed, restored in fixtures:
            self.assertEqual(restored, source, f"rotation {rotation} round trips")
        self.assertEqual(fixtures[4][2], [0, 409], "rotation 1 is 90 degrees left")

    def test_pointer_sequence_conflict_resyncs_and_retries_once(self):
        definition = re.search(r"^async function sendPointerNow.*$", PAGE, re.MULTILINE)
        self.assertIsNotNone(definition)
        script = """
let eventSequence=1,lastPointer=null;
const bodies=[],resyncs=[];
const auth=()=>({});
async function timedFetch(_path,options){
  bodies.push(JSON.parse(options.body));
  if(bodies.length===1)return{ok:false,status:409,json:async()=>({error:{code:'pointer_sequence'}})};
  return{ok:true,status:202,json:async()=>({ok:true})};
}
async function loadInfo(force){resyncs.push(force);eventSequence=41}
function requestPoll(){}
""" + definition.group(0) + """
sendPointerNow('down',{x:7,y:9}).then(()=>process.stdout.write(JSON.stringify({bodies,resyncs})));
"""
        completed = subprocess.run(
            ["node", "-e", script],
            check=True,
            capture_output=True,
            text=True,
        )
        result = json.loads(completed.stdout)
        self.assertEqual(
            [body["eventSequence"] for body in result["bodies"]],
            [2, 42],
        )
        self.assertEqual(result["resyncs"], [True])

    def test_pointer_interaction_pauses_and_resumes_frame_polling(self):
        definitions = []
        for name in (
            "requestPoll",
            "beginPointerInteraction",
            "finishPointerInteraction",
        ):
            match = re.search(rf"^.*function {name}.*$", PAGE, re.MULTILINE)
            self.assertIsNotNone(match)
            definitions.append(match.group(0))
        script = """
let running=true,pointerInteractionActive=false,pollRequested=false,polling=false;
let pollTimer=17,pointerDown=false,pointerChain=Promise.resolve();
let aborts=0,scheduled=0;
let frameAbortController={abort(){aborts++}};
const clearTimeout=()=>{};
const setTimeout=()=>{scheduled++;return 18};
function poll(){}
""" + "".join(definitions) + """
beginPointerInteraction();
const during={pointerInteractionActive,pollRequested,aborts,scheduled};
requestPoll();
finishPointerInteraction().then(()=>process.stdout.write(JSON.stringify({
  during,
  after:{pointerInteractionActive,pollRequested,aborts,scheduled}
})));
"""
        completed = subprocess.run(
            ["node", "-e", script],
            check=True,
            capture_output=True,
            text=True,
        )
        result = json.loads(completed.stdout)
        self.assertEqual(
            result["during"],
            {
                "pointerInteractionActive": True,
                "pollRequested": False,
                "aborts": 1,
                "scheduled": 0,
            },
        )
        self.assertEqual(
            result["after"],
            {
                "pointerInteractionActive": False,
                "pollRequested": True,
                "aborts": 1,
                "scheduled": 1,
            },
        )

    def test_pointer_handlers_bracket_input_with_poll_coordination(self):
        self.assertRegex(
            PAGE,
            r"pointerdown'.*?beginPointerInteraction\(\).*?enqueuePointer\('down'",
        )
        self.assertRegex(
            PAGE,
            r"function release.*?enqueuePointer\(phase,p\).*?finishPointerInteraction",
        )
        self.assertRegex(
            PAGE,
            r"function requestPoll\(\)\{if\(!running\|\|pointerInteractionActive\)return",
        )
        self.assertIn("timedFetch(`/device-debug/v1/frame?after=${sequence}`", PAGE)
        self.assertIn("frameController", PAGE)
        self.assertIn("frameAbortController===frameController", PAGE)


if __name__ == "__main__":
    unittest.main()
