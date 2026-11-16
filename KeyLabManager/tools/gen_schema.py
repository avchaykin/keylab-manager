#!/usr/bin/env python3
"""Static generator: Arturia KeyLab mkII parameter schema from sysex-controls GTK .ui files.

Usage: python3 -I gen_schema.py <sysex-controls/src dir> <out.json>

Pure XML parsing; nothing from the source tree is imported or executed.
Mirrors the id composition of ar-control.c:
  real_id = id + navpage_offset + nearest ScPreferencesPage offset + nearest ScPreferencesGroup offset
  then ar_control_normalize_id (byte[1] >= 0x80 -> byte[0]++, byte[1] -= 0x80; little-endian bytes)
Navigation offsets accumulate along sc_action_nav_push (page offset + row offset).
ScControlValueList items: value attr sets the counter, otherwise counter (starting at 0) ++ per item.
"""
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

SRC = sys.argv[1]
OUT = sys.argv[2]

# ---------------------------------------------------------------- templates
TEMPLATES = {}   # class -> (template element, parent class, file)
for d in (SRC, os.path.join(SRC, "keylab2")):
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".ui"):
            continue
        if d == SRC and not (fn.startswith(("sc-", "ar-", "ar2-"))):
            continue
        root = ET.parse(os.path.join(d, fn)).getroot()
        t = root.find("template")
        if t is not None:
            TEMPLATES[t.get("class")] = (t, t.get("parent"), fn)

SC_GROUP_CLASSES = {"ScPreferencesGroup"}
SC_PAGE_CLASSES = {"ScPreferencesPage"}
NAV_CLASSES = {"ScNavigationPage"}


def isa(cls, base):
    seen = 0
    while cls and seen < 20:
        if cls == base:
            return True
        cls = TEMPLATES[cls][1] if cls in TEMPLATES else None
        seen += 1
    return False


def num(s):
    return int(s.strip(), 0)


def props(el):
    """direct <property> children as dict name->element"""
    return {p.get("name"): p for p in el.findall("property")}


def prop_text(el, name, inherit=True):
    p = props(el).get(name)
    if p is not None and p.text is not None and p.text.strip():
        return p.text.strip()
    if inherit:
        cls = el.get("class")
        if cls in TEMPLATES:
            return prop_text(TEMPLATES[cls][0], name)
    return None


def find_model(el):
    p = props(el).get("model")
    if p is None:
        cls = el.get("class")
        if cls in TEMPLATES:
            return find_model(TEMPLATES[cls][0])
        return None
    lst = p.find("object")
    items = lst.find("items")
    out, v = [], 0
    for it in items.findall("item"):
        if it.get("value") is not None:
            v = num(it.get("value"))
        name = (it.text or "")
        if name:
            out.append({"value": v, "label": name.strip()})
            v += 1
    return out


def adjustment(el):
    p = props(el).get("adjustment")
    if p is None:
        return None, None
    a = props(p.find("object"))
    lo = float(a["lower"].text) if "lower" in a else 0.0
    hi = float(a["upper"].text) if "upper" in a else 0.0
    return int(lo), int(hi)


def normalize(i):
    b = list(i.to_bytes(4, "little"))
    if b[1] >= 0x80:
        b[0] = (b[0] + 1) & 0xFF
        b[1] -= 0x80
    return int.from_bytes(bytes(b), "little")


def addr(i):
    return {"bank": (i >> 24) & 0xFF, "param": (i >> 8) & 0xFF, "ctrl": i & 0xFF}, (i >> 16) & 0xFF


def camel(s):
    w = re.findall(r"[A-Za-z0-9]+", s)
    if not w:
        return "x"
    return w[0].lower() + "".join(x[:1].upper() + x[1:] for x in w[1:])


# ---------------------------------------------------------------- visibility parsing
def parse_visibility(el):
    """returns list of raw conds: (scope_obj_id, [values]) or 'hidden'"""
    conds = []
    for b in el.findall("binding"):
        if b.get("name") != "visible":
            continue
        cl = b.find("closure")
        if cl is not None:
            fn = cl.get("function")
            if fn != "cv_in":
                raise SystemExit("unsupported closure " + fn)
            lk = cl.find("lookup")
            const = cl.find("constant").text
            vals = [num(x) for x in re.findall(r"0x[0-9a-fA-F]+|\d+", const)]
            conds.append((lk.text.strip(), vals))
        else:
            lk = b.find("lookup")
            if lk.get("name") != "active":
                raise SystemExit("unsupported lookup " + str(lk.attrib))
            conds.append((lk.text.strip(), [1]))
    p = props(el).get("visible")
    if p is not None:
        if p.get("bind-source"):
            inv = "invert-boolean" in (p.get("bind-flags") or "")
            if p.get("bind-property") != "active":
                raise SystemExit("unsupported bind-property")
            conds.append((p.get("bind-source"), [0] if inv else [1]))
        elif (p.text or "").strip().lower() in ("no", "false", "0"):
            conds.append("hidden")
    return conds


# ---------------------------------------------------------------- walker
UNRESOLVED = []


class Ctx:
    def __init__(self, nav_off, page_off=0, group_off=0, scope=None, conds=(), item=None):
        self.nav_off, self.page_off, self.group_off = nav_off, page_off, group_off
        self.scope = scope            # dict obj-id -> param (per GtkBuilder template scope)
        self.conds = list(conds)      # inherited (scope, raw cond)
        self.item = item

    def copy(self, **kw):
        c = Ctx(self.nav_off, self.page_off, self.group_off, self.scope, self.conds, self.item)
        for k, v in kw.items():
            setattr(c, k, v)
        return c


ROW_KIND = {
    "ScCcRow": ("int", "cc"), "ScPcRow": ("int", "program"), "ScNoteRow": ("note", "note"),
    "ScChRow": ("channel", "channel"), "Ar2UserChRow": ("channel", "userChannel"),
    "ScComboRow": ("enum", "combo"), "AdwSwitchRow": ("bool", "switch"),
    "AdwSpinRow": ("int", "spin"), "AdwEntryRow": ("string", "entry"),
}


def make_param(row, ctl, ctx):
    cls = row.get("class")
    kind, widget = ROW_KIND[cls]
    cp = {k: (v.text or "").strip() for k, v in props(ctl).items()}
    off = ctx.nav_off + ctx.page_off + ctx.group_off
    rid = normalize(num(cp["id"]) + off)
    a, preset = addr(rid)
    a2 = addr(normalize(num(cp["id2"]) + off))[0] if cp.get("id2") else None
    a3 = addr(normalize(num(cp["id3"]) + off))[0] if cp.get("id3") else None
    title = prop_text(row, "title") or cls
    opts = find_model(row) or []
    lo, hi = 0, 127
    maxlen = None
    if kind == "bool":
        lo, hi = 0, 1
    elif cls == "AdwSpinRow":
        lo, hi = adjustment(row)
    elif kind == "string":
        maxlen = int(cp.get("maxlen", "16"), 0)
        lo = hi = None
    elif opts:
        vals = [o["value"] for o in opts]
        lo, hi = min(vals), max(vals)
    p = {
        "key": None, "title": title, "kind": kind, "widget": widget,
        "addr": a, "addr2": a2, "addr3": a3, "options": opts,
        "min": lo, "max": hi, "maxlen": maxlen,
        "multiply": float(cp.get("multiply", "1")),
        "inverted": cp.get("inverted", "false").lower() in ("true", "1", "yes"),
        "useCcOffset": cp.get("use-cc-offset", "false").lower() in ("true", "1", "yes"),
        "writeOnly": cp.get("write-only", "false").lower() in ("true", "1", "yes"),
        "_preset": preset, "_rid": rid,
    }
    if p["multiply"] == int(p["multiply"]):
        p["multiply"] = int(p["multiply"])
    if p["useCcOffset"]:
        UNRESOLVED.append("use-cc-offset at %s (cc offset not modelled)" % hex(rid))
    return p


def attach(param, row, ctx):
    raw = [(ctx.scope, c) for c in ctx.conds] + [(ctx.scope, c) for c in parse_visibility(row)]
    param["_raw"] = raw
    ctx.item["params"].append(param)
    rid = row.get("id")
    if rid:
        ctx.scope[rid] = param


def walk(el, ctx, sink):
    """el: <object> element (or template). sink: callbacks for nav pushes / new items"""
    cls = el.get("class")
    # template instance of a group (Kl2Knob etc.) -> new item, new scope, group offset
    if el.tag == "object" and cls in TEMPLATES and isa(cls, "ScPreferencesGroup") and cls != "ScPreferencesGroup":
        off = props(el).get("control-id-offset")
        title = prop_text(el, "title") or cls
        item = sink.new_item(title, cls)
        sub = ctx.copy(group_off=num(off.text) if off is not None else 0, scope={},
                       conds=[], item=item)
        # visibility on the instance itself (resolved in outer scope)
        outer = [(ctx.scope, c) for c in ctx.conds + parse_visibility(el)]
        sub.outer_conds = outer
        walk_children(TEMPLATES[cls][0], sub, sink)
        finish_scope(sub.scope)
        for p in item["params"]:
            p["_raw"] = outer + p["_raw"]
        return
    if cls == "ArFirmwareInfoGroup":
        return
    if cls == "AdwPreferencesGroup":
        title = prop_text(el, "title")
        item = sink.new_item(title, cls)
        sub = ctx.copy(item=item, conds=ctx.conds + parse_visibility(el))
        walk_children(el, sub, sink)
        return
    if cls == "ScActionRow":
        tgt = prop_text(el, "target-page")
        off = props(el).get("control-id-offset")
        sink.push(prop_text(el, "title"), tgt, ctx.nav_off + (num(off.text) if off is not None else 0))
        return
    if cls == "Ar2RgbColorRow":
        pr = props(el)
        comps = {c: ctx.scope.get(pr[c].text.strip()) for c in "rgb"}
        if any(v is None for v in comps.values()):
            UNRESOLVED.append("Ar2RgbColorRow refs unresolved in " + str(ctx.item["title"]))
            return
        r = comps["r"]
        p = dict(r)
        p.update({"title": prop_text(el, "title") or "Color", "kind": "color", "widget": "rgb",
                  "rgb": {k: v["addr"] for k, v in comps.items()}, "min": 0, "max": 127,
                  "options": []})
        for v in comps.values():
            v["_hidden"] = True
        raw = [(ctx.scope, c) for c in ctx.conds + parse_visibility(el)]
        p["_raw"] = raw
        ctx.item["params"].append(p)
        return
    if cls in ROW_KIND or (cls in TEMPLATES and any(isa(cls, k) for k in ("ScComboRow",))):
        ctl = None
        for ch in el.findall("child"):
            o = ch.find("object")
            if o is not None and o.get("class") == "ArControl":
                ctl = o
        if ctl is None:
            UNRESOLVED.append("row without ArControl: %s %s" % (cls, prop_text(el, "title")))
            return
        attach(make_param(el, ctl, ctx), el, ctx)
        return
    if cls in ("AdwToolbarView", "ScPreferencesPage", "AdwNavigationView", "AdwHeaderBar", None):
        walk_children(el, ctx, sink)
        return
    if cls in TEMPLATES and isa(cls, "ScNavigationPage"):
        # page directly embedded (book root): handled by caller
        sink.push(None, cls, ctx.nav_off)
        return
    UNRESOLVED.append("unhandled widget %s" % cls)


def walk_children(el, ctx, sink):
    for ch in el.findall("child"):
        o = ch.find("object")
        if o is not None:
            walk(o, ctx, sink)
    for p in el.findall("property"):
        o = p.find("object")
        if o is not None and p.get("name") in ("child", "content"):
            walk(o, ctx, sink)


def finish_scope(scope):
    pass


class PageSink:
    """collects items for one section, flattens nested navigation"""

    def __init__(self, section, prefix):
        self.section, self.prefix = section, prefix
        self.pushes = []

    def new_item(self, title, cls):
        it = {"key": None, "title": title, "_cls": cls, "_prefix": self.prefix, "params": []}
        self.section["items"].append(it)
        return it

    def push(self, title, tgt, off):
        self.pushes.append((title, tgt, off))


def walk_page(page_cls, nav_off, section, prefix):
    sink = PageSink(section, prefix)
    tmpl = TEMPLATES[page_cls][0]
    walk_children(tmpl, Ctx(nav_off, scope={}), sink)
    for title, tgt, off in sink.pushes:
        walk_page(tgt, off, section, prefix + [title])


# ---------------------------------------------------------------- top level
book = TEMPLATES["Kl2Book"][0]
nav = book.find("property").find("object")
top_pages = [ch.find("object").get("class") for ch in nav.findall("child")]

schema = {"presets": [], "presetName": None, "global": [], "preset": []}

SECTION_KEYS = {"Kl2ControllerPage": "controller", "Kl2VelocityPage": "velocity",
                "Kl2PedalCalibrationPage": "pedalCalibration"}

for pc in top_pages:
    if pc == "Kl2PresetsPage":
        continue
    t = TEMPLATES[pc][0]
    sec = {"key": SECTION_KEYS.get(pc, camel(pc)), "title": prop_text(t, "title"), "items": []}
    walk_page(pc, 0, sec, [])
    schema["global"].append(sec)

# presets list
pt = TEMPLATES["Kl2PresetsPage"][0]
preset_rows = [o for o in pt.iter("object") if o.get("class") == "ScActionRow"]
preset_target = None
for r in preset_rows:
    off = num(props(r)["control-id-offset"].text)
    entry = {"id": (off >> 16) & 0x7F, "name": prop_text(r, "title")}
    if prop_text(r, "target-page") != "Kl2PresetPage":
        entry["readonly"] = True
    schema["presets"].append(entry)
    preset_target = prop_text(r, "target-page")

# preset page: name entry + nav rows -> sections
pp = TEMPLATES["Kl2PresetPage"][0]
for o in pp.iter("object"):
    if o.get("class") == "AdwEntryRow":
        ctl = [c.find("object") for c in o.findall("child") if c.find("object") is not None][0]
        cp = {k: v.text.strip() for k, v in props(ctl).items()}
        a, _ = addr(normalize(num(cp["id"])))
        schema["presetName"] = {"param": a["param"], "ctrl": a["ctrl"], "maxlen": int(cp.get("maxlen", "16"), 0)}
for r in pp.iter("object"):
    if r.get("class") != "ScActionRow":
        continue
    title = prop_text(r, "title")
    off = props(r).get("control-id-offset")
    off = num(off.text) if off is not None else 0
    sec = {"key": camel(title), "title": title, "items": []}
    walk_page(prop_text(r, "target-page"), off, sec, [])
    schema["preset"].append(sec)


# ---------------------------------------------------------------- finalize keys / visibility
ITEM_NAME = {"Kl2Knob": "Encoder", "Kl2Fader": "Fader", "Kl2SelectButton": "Select"}


def finalize(sections, scope_label):
    counts = [0, 0, 0]
    for sec in sections:
        counts[0] += 1
        used_items = set()
        for n, it in enumerate(sec["items"]):
            prefix = [p for p in it["_prefix"] if p]
            col = None
            if prefix and re.match(r"Column (\d+)", prefix[-1]):
                col = int(re.match(r"Column (\d+)", prefix[-1]).group(1))
            base = it["title"]
            if not base:
                base = it["params"][0]["title"] if it["params"] else "group%d" % n
            if col is not None:
                name = ITEM_NAME.get(it["_cls"], base)
                it["title"] = "%s %d" % (name, col)
                key = "%s.col%d.%s" % (sec["key"], col, camel(name))
            else:
                it["title"] = base
                key = "%s.%s" % (sec["key"], camel(base))
            k, i = key, 2
            while k in used_items:
                k = "%s%d" % (key, i)
                i += 1
            used_items.add(k)
            it["key"] = k
            used = set()
            for p in it["params"]:
                pk = camel(p["title"])
                k2, i = pk, 2
                while k2 in used:
                    k2 = "%s%d" % (pk, i)
                    i += 1
                used.add(k2)
                p["key"] = k2
        # visibility resolution (needs all keys)
        owner = {}
        for it in sec["items"]:
            for p in it["params"]:
                owner[id(p)] = it
        for it in sec["items"]:
            for p in it["params"]:
                vis = []
                for scope, c in p.pop("_raw"):
                    if c == "hidden":
                        continue
                    ref = scope.get(c[0])
                    if ref is None:
                        UNRESOLVED.append("visibility ref %s unresolved in %s" % (c[0], it["key"]))
                        continue
                    cond = {"param": ref["key"], "in": c[1]}
                    if owner[id(ref)] is not it:
                        cond["item"] = owner[id(ref)]["key"]
                    if cond not in vis:
                        vis.append(cond)
                if vis:
                    p["visibleIf"] = vis
        for it in sec["items"]:
            it["params"] = [p for p in it["params"] if not p.get("_hidden")]
            for p in it["params"]:
                if p["_preset"] != 0:
                    UNRESOLVED.append("non-zero preset byte in %s" % p["key"])
                for k in [k for k in p if k.startswith("_")]:
                    del p[k]
                p.pop("visibleIf", None) if not p.get("visibleIf") else None
            del it["_cls"], it["_prefix"]
        sec["items"] = [it for it in sec["items"] if it["params"]]
        counts[1] += len(sec["items"])
        counts[2] += sum(len(it["params"]) for it in sec["items"])
    return counts


ORDER = ["key", "title", "kind", "widget", "addr", "addr2", "addr3", "rgb", "options", "min", "max",
         "maxlen", "multiply", "inverted", "useCcOffset", "writeOnly", "visibleIf"]
cg = finalize(schema["global"], "global")
cp_ = finalize(schema["preset"], "preset")
for sec in schema["global"] + schema["preset"]:
    for it in sec["items"]:
        it["params"] = [{k: p[k] for k in ORDER if k in p} for p in it["params"]]

with open(OUT, "w") as f:
    json.dump(schema, f, indent=1, ensure_ascii=False)
    f.write("\n")

print("global sections/items/params:", cg)
print("preset sections/items/params:", cp_)
for sec in schema["global"] + schema["preset"]:
    ctrls = sorted({(p["addr"]["bank"], p["addr"]["ctrl"]) for it in sec["items"] for p in it["params"]})
    banks = sorted({b for b, _ in ctrls})
    cs = sorted({c for _, c in ctrls})
    params = sorted({p["addr"]["param"] for it in sec["items"] for p in it["params"]})
    print("%-18s items=%3d params=%4d bank=%s ctrl=%s..%s (%d distinct) param=%s" % (
        sec["key"], len(sec["items"]), sum(len(i["params"]) for i in sec["items"]), banks,
        hex(cs[0]), hex(cs[-1]), len(cs), ",".join(hex(x) for x in params)))
print("UNRESOLVED:", UNRESOLVED)
