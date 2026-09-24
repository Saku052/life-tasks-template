#!/usr/bin/env python3
"""会社PC用のタスク操作。

会社のタスクはこのPCの data/tasks.json にだけ保存し、外には一切送らない。
私用のタスクは、私用側が書き出した暗号化コピー（secret gist）を読むだけ。

    ./office.py setup <gistのURL> <合言葉>   最初に1回
    ./office.py open                         ボードをブラウザで開く
    ./office.py add --title ... --summary ... --check ... [--label ..] [--priority P1] [--due 2026-10-01]
    ./office.py board [--json]               会社 + 私用のカンバンを表示
    ./office.py start 3 / move 3 pending --reason "..." / done 3
    ./office.py help

標準ライブラリと openssl（macOS に標準で入っている）だけで動く。
"""
import argparse
import datetime as dt
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(ROOT, "data")
DATA = os.path.join(DATA_DIR, "tasks.json")
CONFIG = os.path.join(ROOT, "config.json")
PID_FILE = os.path.join(ROOT, ".server.pid")
BOARD_HTML = os.path.join(ROOT, "board", "index.html")
PORT = int(os.environ.get("OFFICE_PORT", "8765"))

# 私用側 scripts/snapshot.sh と揃える
SNAPSHOT_FILE = "life-snapshot.txt"
PBKDF2_ITER = "200000"

STATUSES = ["To do", "Pending", "In progress", "Done"]
WIP_LIMITS = {"In progress": 5, "Pending": 10}
KEEP_DONE_DAYS = 14
PERSONAL_TTL = 60  # 秒。ボードが開いている間、私用タスクを取り直す間隔

CHECK_RE = re.compile(r"^\s*- \[([ xX])\] ?(.*)$")


def die(msg):
    print("ERROR: " + msg, file=sys.stderr)
    sys.exit(1)


def now_iso():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ------------------------------------------------------------------ status / priority

def canonical_status(raw):
    s = raw.strip().lower().replace("-", " ").replace("_", " ")
    table = {
        "to do": "To do", "todo": "To do",
        "pending": "Pending", "hold": "Pending", "on hold": "Pending",
        "in progress": "In progress", "inprogress": "In progress", "doing": "In progress", "wip": "In progress",
        "done": "Done", "complete": "Done", "completed": "Done", "closed": "Done",
    }
    if s not in table:
        die("不明なステータス: %s (To do / Pending / In progress / Done)" % raw)
    return table[s]


def canonical_priority(raw):
    s = raw.strip().upper()
    table = {"P0": "P0", "HIGH": "P0", "高": "P0", "P1": "P1", "MID": "P1", "MEDIUM": "P1", "中": "P1",
             "P2": "P2", "LOW": "P2", "低": "P2"}
    if s not in table:
        die("不明な優先度: %s (P0 / P1 / P2)" % raw)
    return table[s]


def sort_key(t):
    prio = {"P0": 0, "P1": 1, "P2": 2}.get(t.get("priority") or "", 3)
    return (prio, t.get("due") or "9999-99-99")


# ------------------------------------------------------------------ 会社タスク（ローカル）

def load_work():
    if not os.path.exists(DATA):
        return {"nextNumber": 1, "tasks": []}
    with open(DATA, encoding="utf-8") as f:
        return json.load(f)


def save_work(db):
    os.makedirs(DATA_DIR, exist_ok=True)
    tmp = DATA + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(db, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, DATA)


def parse_num(raw):
    m = re.fullmatch(r"[Ww]?-?(\d+)", str(raw).strip())
    if not m:
        die("タスク番号が不正です: %s（例: 3 または W3）" % raw)
    return int(m.group(1))


def find_task(db, num):
    for t in db["tasks"]:
        if t["number"] == num:
            return t
    die("W%d が見つかりません" % num)


def checklist(body):
    items = []
    for line in body.splitlines():
        m = CHECK_RE.match(line)
        if m:
            items.append({"done": m.group(1) != " ", "text": m.group(2)})
    return items


def progress(body):
    items = checklist(body)
    return sum(1 for i in items if i["done"]), len(items)


def touch(t):
    t["updatedAt"] = now_iso()


def set_status(t, status, reason=""):
    t["status"] = status
    t["closedAt"] = now_iso() if status == "Done" else None
    if status == "Pending":
        if reason:
            t["pendingReason"] = reason
    else:
        t.pop("pendingReason", None)
    if reason:
        t.setdefault("notes", []).append({"at": now_iso(), "text": "**%s**: %s" % (status, reason)})
    touch(t)


def toggle_line(body, index, checked):
    """index 番目（0始まり）のチェック項目を checked にする。"""
    out, n = [], 0
    for line in body.splitlines():
        if CHECK_RE.match(line):
            if n == index:
                line = re.sub(r"\[[ xX]\]", "[x]" if checked else "[ ]", line, count=1)
            n += 1
        out.append(line)
    if index >= n:
        raise IndexError(index)
    return "\n".join(out)


def work_view(t):
    d, n = progress(t.get("body", ""))
    v = dict(t)
    v["id"] = "W%d" % t["number"]
    v["source"] = "work"
    v["checklist"] = checklist(t.get("body", ""))
    v["progress"] = [d, n]
    return v


def visible_work(db):
    cut = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=KEEP_DONE_DAYS)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return [work_view(t) for t in db["tasks"]
            if t["status"] != "Done" or (t.get("closedAt") or t.get("updatedAt") or "") >= cut]


# ------------------------------------------------------------------ 私用タスク（暗号化コピーを読むだけ）

def load_config():
    if not os.path.exists(CONFIG):
        return None
    with open(CONFIG, encoding="utf-8") as f:
        return json.load(f)


def parse_gist(raw):
    s = raw.strip().rstrip("/")
    m = re.search(r"gist\.github(?:usercontent)?\.com/([^/]+)/([0-9a-f]{20,})", s)
    if not m:
        m = re.fullmatch(r"([A-Za-z0-9-]+)/([0-9a-f]{20,})", s)
    if not m:
        die("gist の URL として読めません: %s（例: https://gist.github.com/USER/ID）" % raw)
    return {"user": m.group(1), "id": m.group(2)}


def latest_revision(gist):
    """gist の最新コミットを git で調べる。

    「最新版」の raw URL は GitHub 側で数分キャッシュされ、API はログインなしだと
    1時間60回（同じネットワークの全員で共有）までしか使えない。git の ls-remote は
    どちらの制約もなく、常に最新を返す。認証情報は使わない。
    """
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    p = subprocess.run(
        ["git", "-c", "credential.helper=", "ls-remote", "https://gist.github.com/%s.git" % gist["id"], "HEAD"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=20)
    sha = p.stdout.decode().split("\t")[0].strip()
    return sha if re.fullmatch(r"[0-9a-f]{40}", sha) else None


def fetch_personal(cfg):
    """暗号化コピーを取ってきて復号する。失敗したら RuntimeError。"""
    gist = cfg["gist"]
    try:
        rev = latest_revision(gist)
    except (OSError, subprocess.SubprocessError):
        rev = None
    base = "https://gist.githubusercontent.com/%s/%s/raw" % (gist["user"], gist["id"])
    # 版を指定できれば常に最新。できなければ「最新版」URL（数分遅れることがある）に落とす
    url = "%s/%s/%s" % (base, rev, SNAPSHOT_FILE) if rev else "%s/%s?t=%d" % (base, SNAPSHOT_FILE, int(time.time()))
    try:
        with urllib.request.urlopen(url, timeout=15) as r:
            cipher = r.read()
    except Exception as e:
        raise RuntimeError("私用タスクを取得できませんでした（%s）" % e)
    env = dict(os.environ, OFFICE_PASS=cfg["passphrase"])
    p = subprocess.run(
        ["openssl", "enc", "-d", "-aes-256-cbc", "-pbkdf2", "-iter", PBKDF2_ITER, "-md", "sha256",
         "-a", "-A", "-pass", "env:OFFICE_PASS"],
        input=cipher.strip(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    try:
        if p.returncode != 0:
            raise ValueError
        data = json.loads(p.stdout.decode("utf-8"))
    except ValueError:
        raise RuntimeError("私用タスクを復号できませんでした（合言葉が違う可能性があります）")
    for it in data.get("items", []):
        it["id"] = "#%d" % it["number"]
        it["source"] = "personal"
        it["checklist"] = checklist(it.get("body", ""))
        it["progress"] = [sum(1 for c in it["checklist"] if c["done"]), len(it["checklist"])]
    return data


def personal_or_error():
    cfg = load_config()
    if not cfg:
        return None, "未設定です（./office.py setup <gistのURL> <合言葉>）"
    try:
        return fetch_personal(cfg), None
    except RuntimeError as e:
        return None, str(e)


# ------------------------------------------------------------------ 表示

def line_for(t):
    s = "  %s %s" % (t["id"], t["title"])
    if t.get("priority"):
        s += "  [%s]" % t["priority"]
    if t.get("due"):
        s += "  due:%s" % t["due"]
    d, n = t["progress"]
    if n:
        s += "  (%d/%d)" % (d, n)
    if t.get("labels"):
        s += "  {%s}" % ",".join(t["labels"])
    if t.get("pendingReason"):
        s += "  待ち: %s" % t["pendingReason"]
    return s


def combined_state():
    work = visible_work(load_work())
    personal, err = personal_or_error()
    return {
        "work": work,
        "personal": personal["items"] if personal else [],
        "personalGeneratedAt": personal.get("generatedAt") if personal else None,
        "personalError": err,
        "fetchedAt": now_iso(),
        "limits": WIP_LIMITS,
    }


def print_board(state, sources=("work", "personal")):
    items = []
    if "work" in sources:
        items += state["work"]
    if "personal" in sources:
        items += state["personal"]
    for s in STATUSES:
        col = sorted([t for t in items if t["status"] == s], key=sort_key)
        limit = WIP_LIMITS.get(s)
        head = "## %s (%d%s)" % (s, len(col), " / %d" % limit if limit else "")
        if limit and len(col) > limit:
            head += "  ⚠ 上限超過"
        print(head)
        for t in col:
            print(("[会社]" if t["source"] == "work" else "[私用]") + line_for(t))
        print()
    if "personal" in sources:
        if state["personalError"]:
            print("※ 私用タスク: " + state["personalError"])
        elif state["personalGeneratedAt"]:
            print("※ 私用タスクの最終変更: %s（UTC）" % state["personalGeneratedAt"])


# ------------------------------------------------------------------ コマンド

def cmd_setup(a):
    url = a.url or input("秘密URL（https://gist.github.com/...）: ")
    pw = a.passphrase or input("合言葉: ")
    cfg = {"gist": parse_gist(url), "passphrase": pw.strip()}
    try:
        data = fetch_personal(cfg)
    except RuntimeError as e:
        die(str(e))
    old = os.umask(0o077)
    try:
        with open(CONFIG, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
    finally:
        os.umask(old)
    if not os.path.exists(DATA):
        save_work(load_work())
    print("設定しました。私用タスク %d 件を読み込めました（最終変更 %s UTC）"
          % (len(data.get("items", [])), data.get("generatedAt", "?")))


def cmd_add(a):
    if not a.check:
        die("--check を最低1つ指定してください")
    parts = ["## 概要", "", a.summary, "", "## 完了に必要な手順", ""]
    parts += ["- [ ] " + c for c in a.check]
    if a.dod:
        parts += ["", "## 完了条件", "", a.dod]
    if a.due:
        parts += ["", "## 期限", "", a.due]
    if a.notes:
        parts += ["", "## メモ", "", a.notes]
    if a.due and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", a.due):
        die("期限は YYYY-MM-DD 形式で指定してください: %s" % a.due)
    db = load_work()
    t = {
        "number": db["nextNumber"],
        "title": a.title,
        "body": "\n".join(parts),
        "labels": a.label or [],
        "priority": canonical_priority(a.priority) if a.priority else "",
        "due": a.due or "",
        "status": canonical_status(a.status) if a.status else "To do",
        "createdAt": now_iso(),
        "updatedAt": now_iso(),
        "closedAt": None,
        "notes": [],
    }
    db["nextNumber"] += 1
    db["tasks"].append(t)
    save_work(db)
    print("created W%d [%s] %s" % (t["number"], t["status"], t["title"]))
    warn_wip(db, t["status"])


def warn_wip(db, status):
    limit = WIP_LIMITS.get(status)
    if limit:
        n = sum(1 for t in db["tasks"] if t["status"] == status)
        if n > limit:
            print("⚠ %s が上限 %d 件を超えています（会社のタスクだけで %d 件）" % (status, limit, n), file=sys.stderr)


def cmd_list(a):
    db = load_work()
    items = visible_work(db) if not a.all else [work_view(t) for t in db["tasks"]]
    if a.status:
        st = canonical_status(a.status)
        items = [t for t in items if t["status"] == st]
    if a.label:
        items = [t for t in items if a.label in t.get("labels", [])]
    if a.json:
        print(json.dumps(items, ensure_ascii=False, indent=2))
    else:
        for t in sorted(items, key=sort_key):
            print("%s\t%s\t%s" % (t["id"], t["status"], t["title"]))


def cmd_show(a):
    db = load_work()
    t = find_task(db, parse_num(a.num))
    d, n = progress(t["body"])
    print("W%d %s  [%s]" % (t["number"], t["title"], t["status"]))
    print("labels: %s  priority: %s  due: %s" % (" ".join(t.get("labels", [])), t.get("priority", ""), t.get("due", "")))
    if t.get("pendingReason"):
        print("待ち: " + t["pendingReason"])
    print()
    print(t["body"])
    print()
    print("checklist: %d/%d" % (d, n))
    if t.get("notes"):
        print()
        print("## 作業ログ")
        for note in t["notes"]:
            print("- %s %s" % (note["at"], note["text"]))


def cmd_move(a, status=None):
    db = load_work()
    t = find_task(db, parse_num(a.num))
    st = status or canonical_status(a.status)
    set_status(t, st, getattr(a, "reason", "") or "")
    save_work(db)
    print("W%d -> %s" % (t["number"], st))
    warn_wip(db, st)


def cmd_done(a):
    db = load_work()
    t = find_task(db, parse_num(a.num))
    left = [c["text"] for c in checklist(t["body"]) if not c["done"]]
    if left and not a.force:
        d, n = progress(t["body"])
        print("未消化のチェックリストがあります (%d/%d)。" % (d, n), file=sys.stderr)
        for c in left:
            print("- [ ] " + c, file=sys.stderr)
        print("それでも完了にするなら --force を付けてください。", file=sys.stderr)
        sys.exit(1)
    set_status(t, "Done")
    save_work(db)
    print("W%d -> Done" % t["number"])


def cmd_check(a, checked=True):
    db = load_work()
    t = find_task(db, parse_num(a.num))
    items = checklist(t["body"])
    for i, c in enumerate(items):
        if c["done"] != checked and a.text in c["text"]:
            t["body"] = toggle_line(t["body"], i, checked)
            touch(t)
            save_work(db)
            d, n = progress(t["body"])
            print("W%d checklist: %d/%d" % (t["number"], d, n))
            return
    die("「%s」を含む%sの項目が W%d に見つかりません" % (a.text, "未チェック" if checked else "チェック済み", t["number"]))


def cmd_note(a):
    db = load_work()
    t = find_task(db, parse_num(a.num))
    t.setdefault("notes", []).append({"at": now_iso(), "text": " ".join(a.text)})
    touch(t)
    save_work(db)
    print("W%d にメモを残しました" % t["number"])


def cmd_due(a):
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", a.date):
        die("期限は YYYY-MM-DD 形式で指定してください: %s" % a.date)
    db = load_work()
    t = find_task(db, parse_num(a.num))
    t["due"] = a.date
    # 本文の「## 期限」節を書き換える（無ければ末尾に足す）
    lines = t["body"].splitlines()
    try:
        i = next(i for i, l in enumerate(lines) if l.strip() == "## 期限")
    except StopIteration:
        lines += ["", "## 期限", "", a.date]
    else:
        j = next((j for j in range(i + 1, len(lines)) if lines[j].startswith("## ")), len(lines))
        lines[i + 1:j] = ["", a.date] + ([""] if j < len(lines) else [])
    t["body"] = "\n".join(lines)
    touch(t)
    save_work(db)
    print("W%d due: %s" % (t["number"], a.date))


def cmd_stale(a):
    cut = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=a.days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    print("## %d日以上動いていない会社のタスク（Done 以外）" % a.days)
    for t in sorted(load_work()["tasks"], key=lambda t: t["updatedAt"]):
        if t["status"] != "Done" and t["updatedAt"] < cut:
            print("  W%d  [%s]  %s  (last: %s)" % (t["number"], t["status"], t["title"], t["updatedAt"][:10]))


def cmd_board(a):
    state = combined_state()
    if a.json:
        print(json.dumps(state, ensure_ascii=False, indent=2))
    else:
        print_board(state)


def cmd_personal(a):
    data, err = personal_or_error()
    if err:
        die(err)
    if a.json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        print_board({"work": [], "personal": data["items"], "personalError": None,
                     "personalGeneratedAt": data.get("generatedAt")}, sources=("personal",))


# ------------------------------------------------------------------ ボード画面（localhost だけで動く小さなサーバ）

def code_version():
    return str(int(os.path.getmtime(__file__))) + "-" + str(int(os.path.getmtime(BOARD_HTML)))


class Handler(BaseHTTPRequestHandler):
    personal_cache = {"at": 0.0, "data": None, "error": None}
    lock = threading.Lock()

    def log_message(self, *args):
        pass

    def _host_ok(self):
        # DNS リバインディング対策: localhost 以外の Host 名で来たリクエストは拒否する
        return self.headers.get("Host", "") in ("127.0.0.1:%d" % PORT, "localhost:%d" % PORT)

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _personal(self, force=False):
        c = Handler.personal_cache
        with Handler.lock:
            if force or time.time() - c["at"] > PERSONAL_TTL:
                data, err = personal_or_error()
                c.update(at=time.time(), data=data if data else c["data"], error=err)
            return c["data"], c["error"], c["at"]

    def do_GET(self):
        if not self._host_ok():
            return self._send(403, {"error": "forbidden"})
        path = urllib.parse.urlparse(self.path)
        if path.path in ("/", "/index.html"):
            with open(BOARD_HTML, "rb") as f:
                return self._send(200, f.read(), "text/html; charset=utf-8")
        if path.path == "/api/ping":
            return self._send(200, {"ok": True, "version": code_version()})
        if path.path == "/api/state":
            force = "refresh=1" in (path.query or "")
            data, err, at = self._personal(force)
            return self._send(200, {
                "work": visible_work(load_work()),
                "personal": data["items"] if data else [],
                "personalGeneratedAt": data.get("generatedAt") if data else None,
                "personalError": err,
                "personalFetchedAt": dt.datetime.fromtimestamp(at, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if at else None,
                "limits": WIP_LIMITS,
            })
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        # 他のサイトからの書き込みを防ぐ: JSON 以外と、別オリジンからのリクエストは拒否する
        if not self._host_ok():
            return self._send(403, {"error": "forbidden"})
        origin = self.headers.get("Origin")
        if origin and origin not in ("http://127.0.0.1:%d" % PORT, "http://localhost:%d" % PORT):
            return self._send(403, {"error": "forbidden"})
        if not self.headers.get("Content-Type", "").startswith("application/json"):
            return self._send(415, {"error": "json only"})
        try:
            payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
        except ValueError:
            return self._send(400, {"error": "bad json"})
        m = re.fullmatch(r"/api/work/(\d+)/(move|check)", urllib.parse.urlparse(self.path).path)
        if not m:
            return self._send(404, {"error": "not found"})
        with Handler.lock:
            db = load_work()
            t = next((x for x in db["tasks"] if x["number"] == int(m.group(1))), None)
            if not t:
                return self._send(404, {"error": "not found"})
            if m.group(2) == "move":
                st = payload.get("status")
                if st not in STATUSES:
                    return self._send(400, {"error": "bad status"})
                left = [c["text"] for c in checklist(t["body"]) if not c["done"]]
                if st == "Done" and left and not payload.get("force"):
                    return self._send(409, {"error": "checklist", "remaining": left})
                set_status(t, st, (payload.get("reason") or "").strip())
            else:
                try:
                    t["body"] = toggle_line(t["body"], int(payload.get("index", -1)), bool(payload.get("checked")))
                except (IndexError, ValueError):
                    return self._send(400, {"error": "bad index"})
                touch(t)
            save_work(db)
        return self._send(200, {"ok": True, "task": work_view(t)})


def server_version():
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d/api/ping" % PORT, timeout=1) as r:
            return json.load(r).get("version")
    except Exception:
        return None


def cmd_serve(a):
    httpd = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))
    try:
        httpd.serve_forever()
    finally:
        if os.path.exists(PID_FILE):
            os.remove(PID_FILE)


def stop_server():
    if not os.path.exists(PID_FILE):
        return False
    try:
        with open(PID_FILE) as f:
            os.kill(int(f.read().strip()), signal.SIGTERM)
    except (OSError, ValueError):
        pass
    try:
        os.remove(PID_FILE)
    except OSError:
        pass
    for _ in range(20):
        if server_version() is None:
            break
        time.sleep(0.1)
    return True


def cmd_open(a):
    if not os.path.exists(DATA):
        save_work(load_work())
    v = server_version()
    if v is not None and v != code_version():
        stop_server()  # コードが更新されていたら起動し直す
        v = None
    if v is None:
        subprocess.Popen([sys.executable, os.path.abspath(__file__), "serve"],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True, cwd=ROOT)
        for _ in range(50):
            if server_version():
                break
            time.sleep(0.1)
        else:
            die("ボードのサーバを起動できませんでした（ポート %d が使用中かもしれません）" % PORT)
    url = "http://127.0.0.1:%d/" % PORT
    if not a.no_browser:
        webbrowser.open(url)
    print("ボード: " + url)


def cmd_stop(a):
    print("停止しました" if stop_server() else "動いていません")


# ------------------------------------------------------------------ main

def main():
    p = argparse.ArgumentParser(prog="office.py", description="会社PC用のタスク操作（会社タスクはローカル保存、私用タスクは閲覧のみ）")
    sub = p.add_subparsers(dest="cmd")

    s = sub.add_parser("setup", help="私用タスクの秘密URLと合言葉を設定（最初に1回）")
    s.add_argument("url", nargs="?")
    s.add_argument("passphrase", nargs="?")
    s.set_defaults(fn=cmd_setup)

    s = sub.add_parser("add", help="会社のタスクを追加")
    s.add_argument("--title", required=True)
    s.add_argument("--summary", required=True)
    s.add_argument("--check", action="append")
    s.add_argument("--dod")
    s.add_argument("--due")
    s.add_argument("--label", action="append")
    s.add_argument("--priority")
    s.add_argument("--status")
    s.add_argument("--notes")
    s.set_defaults(fn=cmd_add)

    s = sub.add_parser("list", help="会社のタスクを一覧")
    s.add_argument("--status")
    s.add_argument("--label")
    s.add_argument("--json", action="store_true")
    s.add_argument("--all", action="store_true", help="古い Done も含める")
    s.set_defaults(fn=cmd_list)

    s = sub.add_parser("show", help="会社のタスクの詳細")
    s.add_argument("num")
    s.set_defaults(fn=cmd_show)

    s = sub.add_parser("move", help="ステータス変更（To do / Pending / In progress / Done）")
    s.add_argument("num")
    s.add_argument("status")
    s.add_argument("--reason", default="")
    s.set_defaults(fn=cmd_move)

    s = sub.add_parser("start", help="In progress にする")
    s.add_argument("num")
    s.set_defaults(fn=lambda a: cmd_move(a, "In progress"))

    s = sub.add_parser("done", help="完了（チェックリストが残っていると止まる）")
    s.add_argument("num")
    s.add_argument("--force", action="store_true")
    s.set_defaults(fn=cmd_done)

    s = sub.add_parser("check", help="チェックリストの項目を消し込む")
    s.add_argument("num")
    s.add_argument("text")
    s.set_defaults(fn=lambda a: cmd_check(a, True))

    s = sub.add_parser("uncheck", help="チェックを外す")
    s.add_argument("num")
    s.add_argument("text")
    s.set_defaults(fn=lambda a: cmd_check(a, False))

    s = sub.add_parser("note", help="作業ログを残す")
    s.add_argument("num")
    s.add_argument("text", nargs="+")
    s.set_defaults(fn=cmd_note)

    s = sub.add_parser("due", help="期限を設定")
    s.add_argument("num")
    s.add_argument("date")
    s.set_defaults(fn=cmd_due)

    s = sub.add_parser("stale", help="動いていない会社のタスク")
    s.add_argument("days", nargs="?", type=int, default=7)
    s.set_defaults(fn=cmd_stale)

    s = sub.add_parser("board", help="会社 + 私用のカンバンを表示")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_board)

    s = sub.add_parser("personal", help="私用タスクだけを表示（閲覧のみ）")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_personal)

    s = sub.add_parser("open", help="ボードをブラウザで開く")
    s.add_argument("--no-browser", action="store_true")
    s.set_defaults(fn=cmd_open)

    s = sub.add_parser("serve", help="(内部用) ボードのサーバを前面で動かす")
    s.set_defaults(fn=cmd_serve)

    s = sub.add_parser("stop", help="ボードのサーバを止める")
    s.set_defaults(fn=cmd_stop)

    if sys.argv[1:2] == ["help"]:
        p.print_help()
        return
    a = p.parse_args()
    if not getattr(a, "fn", None):
        p.print_help()
        return
    a.fn(a)


if __name__ == "__main__":
    main()
