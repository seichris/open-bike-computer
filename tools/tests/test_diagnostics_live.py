from copy import deepcopy
import sys
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
from bicino_diagnostics.live import LiveInbox
from bicino_diagnostics.bundle import EvidenceError
from test_ride_diagnostics import event,APP_PROCESS_ID,firmware_event,DEVICE_DIGEST

class DiagnosticsLiveTests(unittest.TestCase):
    def batch(self,start=0,count=3):
        return {'schema':2,'source':'ios','device':'iphone','streamId':APP_PROCESS_ID,
            'events':[event(i) for i in range(start,start+count)],
            'oldestAvailableSequence':start,'latestAvailableSequence':start+count-1,
            'nextSequence':start+count-1,'gap':False,'durability':'observed_not_durable'}
    def test_cursor_replay_and_separate_durability(self):
        inbox=LiveInbox();batch=self.batch();inbox.accept(batch);inbox.accept(batch)
        page=inbox.query('iphone',limit=1)
        self.assertEqual(page['events'][0]['sequence'],0)
        self.assertEqual(page['durability'],'observed_not_durable')
        self.assertTrue(page['needsRetainedBundle'])
        next_page=inbox.query('iphone',page['nextCursor'],limit=1)
        self.assertEqual(next_page['events'][0]['sequence'],1)
        changed=deepcopy(batch);changed['events'][1]['event']='changed'
        with self.assertRaisesRegex(EvidenceError,'reused'):inbox.accept(changed)
    def test_gap_and_buffer_limit(self):
        inbox=LiveInbox();inbox.accept(self.batch(0));cursor=inbox.query('iphone')['nextCursor']
        for start in range(20,250,3):inbox.accept(self.batch(start))
        state=inbox.query('iphone',cursor)
        self.assertTrue(state['gap'])
        self.assertLessEqual(len(next(iter(inbox.streams.values()))['events']),128)
        self.assertLessEqual(len(state['events']),25)
    def test_uninstrumented_raw_data_rejected(self):
        batch=self.batch();batch['events'][0]['fields']['latitude']='22.11111'
        with self.assertRaises(Exception):LiveInbox().accept(batch)
    def test_cross_source_identity_rejected(self):
        batch=self.batch();batch['events'][0]['processId']='00000000-0000-0000-0000-000000000001'
        with self.assertRaisesRegex(EvidenceError,'identity mismatch'):LiveInbox().accept(batch)
        batch=self.batch();batch['source']='firmware';batch['device']=DEVICE_DIGEST;batch['streamId']='boot:8'
        batch['events']=[firmware_event(i) for i in range(3)]
        with self.assertRaises(Exception):LiveInbox().accept(batch)
    def test_cursor_for_another_device_rejected(self):
        inbox=LiveInbox();inbox.accept(self.batch());cursor=inbox.query('iphone')['nextCursor']
        with self.assertRaisesRegex(EvidenceError,'cursor'):inbox.query(DEVICE_DIGEST,cursor)
    def test_empty_inbox_is_not_successful_delivery(self):
        result=LiveInbox().query('iphone')
        self.assertEqual(result['state'],'no_live_observation')
        self.assertIsNone(result['nextCursor'])
if __name__=='__main__':unittest.main()
