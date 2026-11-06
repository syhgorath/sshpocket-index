#!/usr/bin/env python3
"""index-publish.sh yardımcısı: şartname docs/package-index.md §3 (biçim) ve belirlenimli üretim.

Her zaman `python3 -I` ile çalıştırılır. Komutlar:
  validate <index.json> [önceki-seri]     biçim kurallarını denetler (önceki-seri verilirse serial == önceki+1)
  field <json> <id> <alan>                paket alanını yazdırır (yoksa boş)
  serial <json>                           serial yazdırır (dosya yoksa 0)
  newer <A> <B>                           A > B ise çıkış 0
  profiles                                stdin'deki component.json'dan supported profil kimlikleri (virgüllü)
  cjson                                   stdin'deki component.json'dan "id sürüm"
  pending-add <taslak> <id> <repo> <sürüm> <sha256> <requires> <platforms>
  merge <index.json> <taslak|-> <çıktı> <gün>   birleştirir, serial+1, issued_at/valid_until; değişen "id sürüm" satırlarını yazdırır
"""
import datetime
import json
import os
import re
import sys

ID_RE = re.compile(r"^[a-z][a-z0-9-]{0,63}$")
VER_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
REPO_RE = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
TS_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
MAX_INDEX = 1024 * 1024


class Bad(Exception):
    pass


def _pairs(pairs):
    d = {}
    for k, v in pairs:
        if k in d:
            raise Bad("yinelenen JSON anahtarı: %s" % k)
        d[k] = v
    return d


def _const(name):
    raise Bad("geçersiz JSON sabiti: %s" % name)


def load(path):
    try:
        with open(path, "rb") as f:
            raw = f.read()
        return json.loads(raw.decode("utf-8"), object_pairs_hook=_pairs, parse_constant=_const), raw
    except Bad:
        raise
    except Exception as e:
        raise Bad("%s okunamadı: %s" % (path, e))


def dump(obj):
    return json.dumps(obj, sort_keys=True, indent=2, ensure_ascii=True) + "\n"


def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    os.replace(tmp, path)


def vkey(v):
    if not isinstance(v, str) or not VER_RE.match(v):
        raise Bad("sürüm biçimi geçersiz: %r" % (v,))
    return tuple(int(x) for x in v.split("."))


def ts(s):
    if not isinstance(s, str) or not TS_RE.match(s):
        raise Bad("zaman damgası biçimi geçersiz: %r" % (s,))
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        raise Bad("zaman damgası geçersiz: %r" % (s,))


def fmt(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def check_package(pid, p):
    if not ID_RE.match(pid):
        raise Bad("paket kimliği geçersiz: %r" % (pid,))
    if not isinstance(p, dict):
        raise Bad("%s: paket nesne olmalı" % pid)
    repo = p.get("repo")
    if not isinstance(repo, str) or not REPO_RE.match(repo) or any(x in (".", "..") for x in repo.split("/")):
        raise Bad("%s: repo geçersiz" % pid)
    vkey(p.get("version"))
    if p.get("asset") != "%s-%s.tar.gz" % (pid, p["version"]):
        raise Bad("%s: asset adı <id>-<sürüm>.tar.gz olmalı" % pid)
    if not isinstance(p.get("sha256"), str) or not SHA_RE.match(p["sha256"]):
        raise Bad("%s: sha256 geçersiz" % pid)
    if "requires_sshpocket" in p:
        vkey(p["requires_sshpocket"])
    if "platforms" in p:
        pl = p["platforms"]
        if not isinstance(pl, list) or not all(isinstance(x, str) and x for x in pl):
            raise Bad("%s: platforms dize listesi olmalı" % pid)
    if "yanked" in p and not isinstance(p["yanked"], bool):
        raise Bad("%s: yanked bool olmalı" % pid)


def check_index(obj, raw_len, prev_serial=None):
    if raw_len > MAX_INDEX:
        raise Bad("index.json 1 MiB sınırını aşıyor")
    if not isinstance(obj, dict):
        raise Bad("üst düzey değer nesne olmalı")
    if obj.get("schema") != 1 or isinstance(obj.get("schema"), bool):
        raise Bad("schema tam 1 olmalı")
    s = obj.get("serial")
    if not isinstance(s, int) or isinstance(s, bool) or s < 1:
        raise Bad("serial >= 1 tam sayı olmalı")
    if prev_serial is not None and s != prev_serial + 1:
        raise Bad("serial %d, beklenen %d" % (s, prev_serial + 1))
    iss, val = ts(obj.get("issued_at")), ts(obj.get("valid_until"))
    if not iss < val <= iss + datetime.timedelta(days=90):
        raise Bad("valid_until, issued_at'tan sonra ve en çok 90 gün olmalı")
    pk = obj.get("packages")
    if not isinstance(pk, dict):
        raise Bad("packages nesne olmalı")
    for pid, p in pk.items():
        check_package(pid, p)


def cmd_validate(a):
    obj, raw = load(a[0])
    check_index(obj, len(raw), int(a[1]) if len(a) > 1 else None)


def cmd_field(a):
    obj, _ = load(a[0])
    v = obj.get("packages", {}).get(a[1], {}).get(a[2], "")
    print(v if isinstance(v, str) else json.dumps(v))


def cmd_serial(a):
    if not os.path.exists(a[0]):
        print(0)
        return
    obj, _ = load(a[0])
    s = obj.get("serial")
    if not isinstance(s, int) or isinstance(s, bool):
        raise Bad("serial okunamadı")
    print(s)


def cmd_newer(a):
    sys.exit(0 if vkey(a[0]) > vkey(a[1]) else 1)


def read_component():
    try:
        c = json.loads(sys.stdin.read(), object_pairs_hook=_pairs, parse_constant=_const)
    except Exception as e:
        raise Bad("component.json okunamadı: %s" % e)
    if not isinstance(c, dict):
        raise Bad("component.json nesne değil")
    return c


def cmd_profiles(a):
    c = read_component()
    out = []
    for p in c.get("profiles", []):
        if isinstance(p, dict) and p.get("status") == "supported" and isinstance(p.get("id"), str):
            out.append(p["id"])
    print(",".join(out))


def cmd_cjson(a):
    c = read_component()
    print("%s %s" % (c.get("id"), c.get("version")))


def cmd_pending_add(a):
    path, pid, repo, ver, sha, req, plat = a
    if os.path.exists(path):
        obj, _ = load(path)
        if not isinstance(obj, dict) or not isinstance(obj.get("packages"), dict):
            raise Bad("taslak biçimi geçersiz")
    else:
        obj = {"packages": {}}
    ent = {"repo": repo, "version": ver, "asset": "%s-%s.tar.gz" % (pid, ver), "sha256": sha}
    if req:
        ent["requires_sshpocket"] = req
    if plat:
        ent["platforms"] = plat.split(",")
    check_package(pid, ent)
    obj["packages"][pid] = ent
    write_atomic(path, dump(obj))


def cmd_merge(a):
    idx_path, pend_path, out, days = a[0], a[1], a[2], int(a[3])
    if not 1 <= days <= 90:
        raise Bad("--valid-days 1..90 olmalı")
    if os.path.exists(idx_path):
        base, _ = load(idx_path)
        prev = base["serial"]
    else:
        base, prev = {"schema": 1, "packages": {}}, 0
    changed = []
    if pend_path != "-":
        pend, _ = load(pend_path)
        if not isinstance(pend, dict) or not isinstance(pend.get("packages"), dict) or not pend["packages"]:
            raise Bad("taslak boş ya da biçimi geçersiz")
        for pid, ent in sorted(pend["packages"].items()):
            check_package(pid, ent)
            old = base["packages"].get(pid)
            if old is not None and vkey(ent["version"]) <= vkey(old["version"]):
                raise Bad("%s: taslaktaki sürüm %s, indeksteki %s'den büyük değil" % (pid, ent["version"], old["version"]))
            base["packages"][pid] = ent
            changed.append("%s %s" % (pid, ent["version"]))
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None, microsecond=0)
    base["schema"] = 1
    base["serial"] = prev + 1
    base["issued_at"] = fmt(now)
    base["valid_until"] = fmt(now + datetime.timedelta(days=days))
    write_atomic(out, dump(base))
    for c in changed:
        print(c)


CMDS = {"validate": cmd_validate, "field": cmd_field, "serial": cmd_serial, "newer": cmd_newer,
        "profiles": cmd_profiles, "cjson": cmd_cjson, "pending-add": cmd_pending_add, "merge": cmd_merge}

if __name__ == "__main__":
    try:
        CMDS[sys.argv[1]](sys.argv[2:])
    except Bad as e:
        print("HATA: %s" % e, file=sys.stderr)
        sys.exit(1)
    except (KeyError, IndexError):
        print("kullanım: index_lib.py <komut> ... (bkz. dosya başı)", file=sys.stderr)
        sys.exit(2)
