"""Bounded ephemeral live observations. Never a substitute for retained evidence."""
from __future__ import annotations
from collections import OrderedDict
import json
import re
import time
import uuid
import ride_diagnostics as v1
from .bundle import EvidenceError, integer


class LiveInbox:
    def __init__(self):
        self.streams: OrderedDict[tuple[str, str], dict] = OrderedDict()

    def accept(self, value: dict) -> None:
        expected = {'schema','source','device','streamId','events','oldestAvailableSequence',
                    'latestAvailableSequence','nextSequence','gap','durability'}
        if not isinstance(value,dict) or set(value)!=expected or value['schema']!=2 or value['source'] not in ('ios','firmware') or value['durability']!='observed_not_durable' or type(value['gap']) is not bool:
            raise EvidenceError('invalid live envelope')
        if len(json.dumps(value).encode())>48*1024 or not isinstance(value['events'],list) or len(value['events'])>16:
            raise EvidenceError('live envelope exceeds budget')
        if not all(integer(value[key],0,2**63-1) for key in ('oldestAvailableSequence','latestAvailableSequence','nextSequence')):
            raise EvidenceError('invalid live sequence')
        if value['oldestAvailableSequence']>value['latestAvailableSequence'] or value['nextSequence']>value['latestAvailableSequence']:
            raise EvidenceError('invalid live range')
        if value['source']=='ios':
            if value['device']!='iphone' or str(uuid.UUID(value['streamId']))!=value['streamId']:
                raise EvidenceError('invalid phone live stream')
            path=f"app/{value['streamId']}/events-000001.jsonl"
        else:
            if not isinstance(value['device'],str) or not re.fullmatch('[0-9a-f]{16}',value['device']) or not isinstance(value['streamId'],str) or not re.fullmatch(r'boot:[1-9][0-9]{0,9}',value['streamId']):
                raise EvidenceError('invalid device live stream')
            path=f"device/{value['device']}/{value['streamId'][5:]}/events-000001-aaaaaaaaaaaaaaaa.jsonl"
        records=[]
        if value['events']:
            raw=b''.join(json.dumps(event,sort_keys=True,separators=(',',':')).encode()+b'\n' for event in value['events'])
            stream=v1.validate_jsonl(raw,path,value['source'])
            records=list(stream.events)
            if records[0]['sequence']<value['oldestAvailableSequence'] or records[-1]['sequence']!=value['nextSequence']:
                raise EvidenceError('live event range mismatch')
            for event in records:
                if value['source']=='ios' and event.get('processId')!=value['streamId']:
                    raise EvidenceError('live process identity mismatch')
                if value['source']=='firmware' and str(event['fields']['bootSequence'])!=value['streamId'][5:]:
                    raise EvidenceError('live boot identity mismatch')
        key=(value['device'],value['streamId'])
        previous=self.streams.get(key)
        events=dict(previous['events']) if previous else {}
        for event in records:
            sequence=event['sequence']
            if sequence in events and events[sequence]!=event:
                raise EvidenceError('live sequence reused with different bytes')
            events[sequence]=event
        events=dict(sorted(events.items()))
        # Bound both count AND bytes, so pathological large fields do not turn
        # the observation cache into an unbounded parallel logging system.
        while len(events)>128 or len(json.dumps(events).encode())>64*1024:
            del events[next(iter(events))]
        self.streams[key]={'events':events,'receivedAt':time.time(),
                          'source':value['source'],'sourceGap':value['gap'] or bool(previous and previous['sourceGap'])}
        self.streams.move_to_end(key)
        while len(self.streams)>4:self.streams.popitem(last=False)

    def query(self, device: str, cursor: dict | None = None, limit: int = 25) -> dict:
        if device!='iphone' and (not isinstance(device,str) or not re.fullmatch('[0-9a-f]{16}',device)):
            raise EvidenceError('explicit live device identity required')
        if not integer(limit,1,50):raise EvidenceError('invalid live page size')
        if cursor is not None:
            if not isinstance(cursor,dict) or set(cursor)!={'device','streamId','after'} or cursor['device']!=device or not isinstance(cursor['streamId'],str) or len(cursor['streamId'])>40 or not integer(cursor['after'],0,2**63-1):
                raise EvidenceError('invalid live cursor')
        choices=[(key,state) for key,state in self.streams.items() if key[0]==device]
        if not choices:
            return {'schema':2,'device':device,'events':[],'state':'no_live_observation',
                    'nextCursor':None,'gap':False,'durability':'observed_not_durable'}
        key,state=choices[-1]
        same=cursor is not None and cursor['streamId']==key[1]
        after=cursor['after'] if same else -1
        all_events=list(state['events'].values())
        gap=bool(cursor and (not same or (all_events and (after+1<all_events[0]['sequence'] or after>all_events[-1]['sequence']))))
        events=[]
        for event in all_events:
            if event['sequence']<=after:continue
            if len(events)>=limit or len(json.dumps(events+[event]).encode())>48*1024:break
            events.append(event)
        if same and events and events[0]['sequence'] > after + 1:
            gap = True
        last=events[-1]['sequence'] if events else max(after,0)
        for left,right in zip(events,events[1:]):
            gap=gap or right['sequence']>left['sequence']+1
        return {'schema':2,'device':device,'streamId':key[1],'events':events,
                'nextCursor':{'device':device,'streamId':key[1],'after':last},
                'gap':gap or state['sourceGap'],'receivedAt':state['receivedAt'],
                'ageSeconds':max(0,int(time.time()-state['receivedAt'])),
                'state':'stale_snapshot' if time.time()-state['receivedAt']>20 else 'live_snapshot','durability':'observed_not_durable',
                'needsRetainedBundle':True}
