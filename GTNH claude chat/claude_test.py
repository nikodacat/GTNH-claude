# =============================================
#  claude_server.py  (v2 - with web UI)
#  Runs on your PC. Bridges OC HTTP requests
#  to Claude Code CLI (claude -p).
#  Requires: Claude Code installed + signed in
#  pip install nothing -- uses stdlib only
#
#  Endpoints:
#    POST /ping        -- health check (OC)
#    POST /chat        -- send message  (OC)
#    GET  /            -- web chat viewer (browser)
#    GET  /history     -- poll for new messages (browser)
# =============================================

import http.server
import json
import subprocess
import sys
import os
import threading
import time

PORT       = 11434
CLAUDE_PATH = os.environ.get("CLAUDE_CLI_PATH", "claude")

# ── shared conversation log ───────────────────────────────────
# Each entry: { "role": "player"|"claude"|"error", "text": str, "time": str }
log_lock   = threading.Lock()
chat_log   = []

def append_log(role, text):
    ts = time.strftime("%H:%M:%S")
    with log_lock:
        chat_log.append({"role": role, "text": text, "time": ts})

# ── CJK detection ─────────────────────────────────────────────
def contains_cjk(text):
    """Return True if text contains any CJK (Chinese/Japanese/Korean) characters."""
    for ch in text:
        cp = ord(ch)
        if (0x4E00 <= cp <= 0x9FFF   or   # CJK Unified Ideographs
            0x3400 <= cp <= 0x4DBF   or   # CJK Extension A
            0xF900 <= cp <= 0xFAFF   or   # CJK Compatibility
            0x3000 <= cp <= 0x303F   or   # CJK Symbols & Punctuation
            0xFF00 <= cp <= 0xFFEF):      # Halfwidth/Fullwidth Forms
            return True
    return False

def make_oc_notice(reply):
    """
    Given a reply that contains CJK, produce a short ASCII-safe notice
    for the OC terminal telling the player to check the web viewer.
    """
    # strip to first sentence or 80 chars of ASCII for a preview hint
    ascii_only = ''.join(c if ord(c) < 128 else '?' for c in reply)
    preview = ascii_only.strip()[:60].rsplit(' ', 1)[0]  # trim at word boundary
    return (
        "[!] Reply contains Chinese/non-ASCII text.\n"
        "    Check the web viewer for the full response.\n"
        + (("    Preview: " + preview + "...") if preview else "")
    )



# ── recipe database ───────────────────────────────────────────
RECIPE_DB_PATH = "recipe_db.json"
recipe_db = {}

def load_recipe_db():
    global recipe_db
    if not os.path.exists(RECIPE_DB_PATH):
        print(f"[warn] {RECIPE_DB_PATH} not found — recipe lookups disabled.")
        print(f"       Run parse_recipes.py to generate it.")
        return
    print(f"[~] Loading recipe DB...", end=" ", flush=True)
    with open(RECIPE_DB_PATH, "r", encoding="utf-8") as f:
        recipe_db = json.load(f)
    print(f"done. {len(recipe_db):,} items indexed.")

def search_items(query, limit=10):
    """Fuzzy search item names containing query string."""
    q = query.lower()
    results = []
    for name in recipe_db:
        if q in name.lower():
            results.append(name)
        if len(results) >= limit:
            break
    return results


# ── verify claude ─────────────────────────────────────────────
def check_claude():
    try:
        result = subprocess.run(
            [CLAUDE_PATH, "--version"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            print(f"[ok] Claude CLI found: {result.stdout.strip()}")
            return True
    except FileNotFoundError:
        pass
    print("[err] Claude CLI not found.")
    print("      Install: npm install -g @anthropic-ai/claude-code")
    print("      Sign in: claude")
    return False

# ── call claude -p ────────────────────────────────────────────
def ask_claude(messages, system=None):
    parts = []
    if system:
        parts.append(f"[System]\n{system}\n")
    for msg in messages:
        label = "User" if msg.get("role") == "user" else "Assistant"
        parts.append(f"[{label}]\n{msg.get('content','')}")
    parts.append("[Assistant]\n(reply below)")
    prompt = "\n\n".join(parts)

    try:
        result = subprocess.run(
            [CLAUDE_PATH, "-p", prompt],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=60
        )
        if result.returncode != 0:
            err = result.stderr.strip() or "unknown error"
            return None, f"claude exited {result.returncode}: {err}"
        return result.stdout.strip(), None
    except subprocess.TimeoutExpired:
        return None, "claude timed out (>60s)"
    except Exception as e:
        return None, str(e)

# ── web UI HTML ───────────────────────────────────────────────
WEB_PAGE = """<!DOCTYPE html>
<html lang="zh-TW">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Claude × GTNH Chat</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    background: #1a1a2e; color: #e0e0e0;
    font-family: 'Segoe UI', sans-serif;
    display: flex; flex-direction: column; height: 100vh;
  }
  header {
    background: #16213e; padding: 14px 20px;
    border-bottom: 2px solid #0f3460;
    display: flex; align-items: center; gap: 12px;
  }
  header h1 { font-size: 1.1rem; color: #00d4ff; }
  #status {
    margin-left: auto; font-size: 0.75rem;
    color: #888; display: flex; align-items: center; gap: 6px;
  }
  #dot {
    width: 8px; height: 8px; border-radius: 50%;
    background: #00ff88; animation: pulse 2s infinite;
  }
  @keyframes pulse {
    0%,100% { opacity:1; } 50% { opacity:0.3; }
  }
  #log {
    flex: 1; overflow-y: auto;
    padding: 16px 20px;
    display: flex; flex-direction: column; gap: 12px;
  }
  .msg { display: flex; flex-direction: column; gap: 4px; max-width: 80%; }
  .msg.player { align-self: flex-end; align-items: flex-end; }
  .msg.claude  { align-self: flex-start; }
  .msg.error   { align-self: center; }
  .bubble {
    padding: 10px 14px; border-radius: 14px;
    line-height: 1.55; white-space: pre-wrap; word-break: break-word;
    font-size: 0.95rem;
  }
  .player .bubble {
    background: #0f3460; color: #e0f0ff;
    border-bottom-right-radius: 4px;
  }
  .claude .bubble {
    background: #16213e; color: #e0e0e0;
    border: 1px solid #0f3460;
    border-bottom-left-radius: 4px;
  }
  .error .bubble {
    background: #3a0f0f; color: #ff8888;
    font-size: 0.85rem;
  }
  .diag .bubble {
    background: #1a1a1a; color: #aaffaa;
    font-family: monospace; font-size: 0.82rem;
    border: 1px solid #2a2a2a;
    white-space: pre;
  }
  .diag .label { color: #aaffaa; }
  .meta {
    font-size: 0.72rem; color: #555;
    padding: 0 4px;
  }
  .label { font-weight: 600; font-size: 0.78rem; margin-bottom: 2px; }
  .player .label { color: #00d4ff; }
  .claude  .label { color: #00ff88; }
  #empty {
    flex: 1; display: flex; align-items: center; justify-content: center;
    color: #444; font-size: 0.9rem;
  }
  #inputBar {
    display: flex; gap: 8px;
    padding: 12px 20px;
    background: #16213e; border-top: 2px solid #0f3460;
  }
  #chatInput {
    flex: 1; padding: 10px 14px; border-radius: 10px;
    border: 1px solid #0f3460; background: #1a1a2e; color: #e0e0e0;
    font-size: 0.95rem; font-family: inherit;
  }
  #chatInput:disabled { opacity: 0.5; }
  #sendBtn {
    padding: 10px 18px; border-radius: 10px; border: none;
    background: #00d4ff; color: #0b1220; font-weight: 600;
    cursor: pointer; font-size: 0.9rem;
  }
  #sendBtn:disabled { opacity: 0.5; cursor: default; }
  #matchHint {
    font-size: 0.72rem; color: #666; padding: 0 20px 4px;
    min-height: 1em;
  }
</style>
</head>
<body>
<header>
  <div>⛏</div>
  <h1>Claude × GTNH Chat</h1>
  <div id="status"><div id="dot"></div><span id="statusText">Connecting...</span></div>
</header>
<div id="log">
  <div id="empty">Waiting for messages from in-game...</div>
</div>
<div id="matchHint"></div>
<div id="inputBar">
  <input id="chatInput" type="text" placeholder="Ask Claude, or ask about a craft (e.g. how do I make redstone alloy dust)..." autocomplete="off">
  <button id="sendBtn">Send</button>
</div>
<script>
  let lastCount = 0;

  function addMessage(entry) {
    const log = document.getElementById('log');
    const empty = document.getElementById('empty');
    if (empty) empty.remove();

    const wrap = document.createElement('div');
    wrap.className = 'msg ' + entry.role;

    const label = document.createElement('div');
    label.className = 'label';
    label.textContent = entry.role === 'player' ? '🎮 Player' :
                        entry.role === 'claude'  ? '🤖 Claude' : '⚠ Error';
    wrap.appendChild(label);

    const bubble = document.createElement('div');
    bubble.className = 'bubble';
    bubble.textContent = entry.text;
    wrap.appendChild(bubble);

    const meta = document.createElement('div');
    meta.className = 'meta';
    meta.textContent = entry.time;
    wrap.appendChild(meta);

    log.appendChild(wrap);
    log.scrollTop = log.scrollHeight;
  }

  async function poll() {
    try {
      const res = await fetch('/history?since=' + lastCount);
      if (!res.ok) throw new Error('bad response');
      const data = await res.json();
      document.getElementById('statusText').textContent = 'Live';
      document.getElementById('dot').style.background = '#00ff88';
      for (const entry of data.entries) {
        addMessage(entry);
        lastCount++;
      }
    } catch(e) {
      document.getElementById('statusText').textContent = 'Disconnected';
      document.getElementById('dot').style.background = '#ff4444';
    }
    setTimeout(poll, 1500);
  }

  poll();

  // ── web chat input ─────────────────────────────────────────
  // Lets you talk to Claude straight from the browser, without the
  // Minecraft server/OC terminal needing to be up. Not connected to
  // a live AE2 network, so it can only advise using recipe_db.json --
  // actual crafting still has to happen in-game via the OC terminal.

  const WEB_SYSTEM = 'You are a GTNH (GregTech: New Horizons) crafting ' +
    'assistant. You may be given a [Recipe DB] block containing a ' +
    'verified crafting recipe -- use it if present, and say so plainly ' +
    'if no recipe was found (note that GTNH recipes often differ from ' +
    'vanilla Minecraft). This conversation is running from a web ' +
    'browser with no live connection to the player\'s in-game inventory ' +
    'or AE2 network -- you cannot check what they have in stock and ' +
    'cannot trigger an actual craft from here. If they want to execute ' +
    'a craft for real, tell them to do it from the in-game OC terminal. ' +
    'Reply conversationally and concisely.';

  let convHistory = []; // {role:'user'|'assistant', content:string}

  async function lookupRecipeContext(text) {
    const words = (text.toLowerCase().match(/[a-z]{3,}/g) || []);
    const hint = words.join('_');
    if (!hint) return { context: '(no recipe DB match)', item: null };
    try {
      const sres = await fetch('/search?q=' + encodeURIComponent(hint) + '&limit=3');
      const sdata = await sres.json();
      if (!sdata.results || sdata.results.length === 0) {
        return { context: '(no recipe DB match)', item: null };
      }
      const item = sdata.results[0];
      const rres = await fetch('/recipe?item=' + encodeURIComponent(item));
      const rdata = await rres.json();
      if (!rdata.found) return { context: '(no recipe DB match)', item: null };
      return {
        context: '[Recipe DB]\nItem: ' + item + '\n' + JSON.stringify(rdata.recipes),
        item: item
      };
    } catch (e) {
      return { context: '(recipe lookup failed: ' + e + ')', item: null };
    }
  }

  async function sendMessage() {
    const inputEl = document.getElementById('chatInput');
    const btn = document.getElementById('sendBtn');
    const hint = document.getElementById('matchHint');
    const text = inputEl.value.trim();
    if (!text) return;

    inputEl.value = '';
    inputEl.disabled = true;
    btn.disabled = true;
    btn.textContent = '...';
    hint.textContent = 'looking up recipe...';

    const { context, item } = await lookupRecipeContext(text);
    hint.textContent = item ? ('matched: ' + item) : 'no recipe DB match';

    convHistory.push({ role: 'user', content: text + '\n\n' + context });

    try {
      const res = await fetch('/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          messages: convHistory,
          display: text,
          system: WEB_SYSTEM,
          source: 'web'
        })
      });
      const data = await res.json();
      if (data.reply) {
        convHistory.push({ role: 'assistant', content: data.reply });
      }
      // rendering happens via the normal poll() cycle picking up the
      // shared server-side log, so we don't append here ourselves.
    } catch (e) {
      hint.textContent = 'send failed: ' + e;
    }

    inputEl.disabled = false;
    btn.disabled = false;
    btn.textContent = 'Send';
    inputEl.focus();
  }

  document.getElementById('sendBtn').addEventListener('click', sendMessage);
  document.getElementById('chatInput').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') sendMessage();
  });
</script>
</body>
</html>"""

# ── HTTP handler ──────────────────────────────────────────────
class Handler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        print(f"[req] {self.address_string()} — {fmt % args}")

    def send_json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def send_html(self, html):
        body = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    # ── GET ───────────────────────────────────────────────────
    def do_GET(self):
        if self.path == "/":
            self.send_html(WEB_PAGE)

        elif self.path.startswith("/history"):
            # ?since=N  returns entries from index N onward
            since = 0
            if "since=" in self.path:
                try: since = int(self.path.split("since=")[1])
                except: since = 0
            with log_lock:
                entries = chat_log[since:]
            self.send_json(200, {"entries": entries})

        elif self.path == "/ping":
            self.send_json(200, {"status": "ok"})

        elif self.path.startswith("/recipe"):
            # /recipe?item=gregtech:gt.metaitem.01:810
            item = None
            if "item=" in self.path:
                item = self.path.split("item=")[1].split("&")[0]
                item = item.replace("%3A", ":").replace("+", " ")
            if not item:
                self.send_json(400, {"error": "missing ?item= parameter"})
            elif not recipe_db:
                self.send_json(503, {"error": "recipe DB not loaded"})
            else:
                recipes = recipe_db.get(item, [])
                self.send_json(200, {
                    "item"   : item,
                    "found"  : len(recipes) > 0,
                    "count"  : len(recipes),
                    "recipes": recipes,
                })

        elif self.path.startswith("/search"):
            # /search?q=iron_ingot&limit=10
            query = ""
            limit = 10
            if "q=" in self.path:
                query = self.path.split("q=")[1].split("&")[0]
                query = query.replace("%3A", ":").replace("+", " ")
            if "limit=" in self.path:
                try: limit = int(self.path.split("limit=")[1].split("&")[0])
                except: limit = 10
            results = search_items(query, limit) if query else []
            self.send_json(200, {"query": query, "results": results})

        else:
            self.send_json(404, {"error": "not found"})

    # ── POST ──────────────────────────────────────────────────
    def do_POST(self):
        if self.path == "/ping":
            length = int(self.headers.get("Content-Length", 0))
            if length: self.rfile.read(length)
            self.send_json(200, {"status": "ok"})
            return

        if self.path == "/log":
            # accepts {"role": "diag", "text": "..."} from OC scripts
            length = int(self.headers.get("Content-Length", 0))
            if length:
                try:
                    body = self.rfile.read(length)
                    data = json.loads(body.decode("utf-8"))
                    role = data.get("role", "diag")
                    text = data.get("text", "")
                    print(f"[{role}] {text[:80]}")
                    append_log(role, text)
                    self.send_json(200, {"status": "ok"})
                except Exception as e:
                    self.send_json(400, {"error": str(e)})
            else:
                self.send_json(400, {"error": "empty body"})
            return

        if self.path != "/chat":
            self.send_json(404, {"error": "use POST /chat"})
            return

        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            self.send_json(400, {"error": "empty body"})
            return

        try:
            body = self.rfile.read(length)
            data = json.loads(body.decode("utf-8"))
        except Exception as e:
            self.send_json(400, {"error": f"bad JSON: {e}"})
            return

        messages = data.get("messages", [])
        system   = data.get("system", None)
        source   = data.get("source", "web")  # "oc" or "web"
        # optional: what to show in the chat log, if different from the
        # full message content sent to Claude (e.g. web client strips out
        # a big recipe-DB context blob before displaying the bubble)
        display  = data.get("display", None)

        if not messages:
            self.send_json(400, {"error": "no messages"})
            return

        # log player message
        last = messages[-1].get("content", "")
        shown = display if display is not None else last
        print(f"[player] {shown}")
        append_log("player", shown)

        reply, err = ask_claude(messages, system)
        if err:
            print(f"[err] {err}")
            append_log("error", err)
            self.send_json(500, {"error": err})
            return

        print(f"[claude] {reply}")
        append_log("claude", reply)

        # If the reply contains CJK and the client is OC terminal,
        # send a safe ASCII notice instead of the raw reply.
        # Web clients always get the full reply.
        if source == "oc" and contains_cjk(reply):
            oc_reply = make_oc_notice(reply)
            self.send_json(200, {"reply": oc_reply, "has_cjk": True})
        else:
            self.send_json(200, {"reply": reply, "has_cjk": False})

# ── main ──────────────────────────────────────────────────────
if __name__ == "__main__":
    if not check_claude():
        sys.exit(1)

    load_recipe_db()

    server = http.server.HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"[ok] Listening on 0.0.0.0:{PORT}")
    print(f"     OC endpoint : http://<your-pc-ip>:{PORT}")
    print(f"     Web viewer  : http://<your-pc-ip>:{PORT}/   (open in browser)")
    print(f"     Press Ctrl+C to stop.\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[ok] Stopped.")