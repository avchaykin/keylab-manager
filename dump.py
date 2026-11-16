import mido, time, json
HDR=[0x00,0x20,0x6B,0x7F,0x42]
P='KeyLab mkII 88 MIDI'
res={}
with mido.open_input(P) as i, mido.open_output(P) as o:
    for ctrl in range(0x80):
        for param in range(0x01,0x11):
            while i.poll(): pass
            o.send(mido.Message('sysex', data=HDR+[0x01,0x00,param,ctrl]))
            t=time.time(); v=None
            while time.time()-t<0.08:
                m=i.poll()
                if m and m.type=='sysex' and list(m.data[:9])==HDR+[0x02,0x00,param,ctrl]:
                    v=list(m.data[9:]); break
                if not m: time.sleep(0.002)
            if v is not None: res.setdefault(ctrl,{})[param]=v
json.dump(res,open('dump.json','w'))
params=sorted({p for c in res.values() for p in c})
print('ctrl | '+' '.join(f'p{p:02X}' for p in params))
for c in sorted(res):
    print(f' {c:02X}  | '+' '.join((' '.join(f'{x:02X}' for x in res[c][p]) if p in res[c] else '--').rjust(3) for p in params))
