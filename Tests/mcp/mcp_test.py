"""Funes's MCP tool paths over real loopback sockets (task 2.11).

Runs funes-mcp-test-server (the FUNES_MCP_TEST build: the real listener, MCP server,
pipeline, handlers, vault and key files on a temporary vault, with a fake approval
responder) and talks to it with http.client. The generic protocol checks (eras,
statuses, Host/Origin, slow-loris, lockout) live in BridgeKit's own harness; this one
checks what Funes adds. Standard library only.

Usage: mcp_test.py SERVER_BINARY TOOLS_JSON
"""

import http.client
import json
import os
import stat
import subprocess
import sys
import tempfile
import threading
import time

LEGACY = "2025-11-25"
APP = "Funes Vault"
PREFIX = "fns_mcp_v1_"

failures = []
checks = 0


def check(name, condition, detail=""):
    global checks
    checks += 1
    if not condition:
        failures.append(f"{name}: {detail}")


class Harness:
    def __init__(self, binary, **env_extra):
        self.dir = tempfile.mkdtemp(prefix="funes-mcp-test-")
        os.chmod(self.dir, 0o700)
        env = dict(os.environ, FUNES_MCP_TEST_DIR=self.dir, **{k: str(v) for k, v in env_extra.items()})
        self.proc = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, env=env, text=True)
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError("server exited: " + self.proc.stderr.read())
        first = json.loads(line)
        self.port = first["port"]
        self.agents = first["agents"]
        self.memories = first["memories"]
        self.lock = threading.Lock()

    def control(self, **command):
        with self.lock:
            self.proc.stdin.write(json.dumps(command) + "\n")
            self.proc.stdin.flush()
            return json.loads(self.proc.stdout.readline())

    def key(self, name):
        return self.agents[name]["key"]

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()


class Client:
    def __init__(self, harness, key=None, host=None):
        self.h = harness
        self.key = key
        self.host = host or f"127.0.0.1:{harness.port}"
        self.conn = http.client.HTTPConnection("127.0.0.1", harness.port, timeout=70)
        self.next_id = 1

    def raw(self, body, headers=None):
        all_headers = {"Host": self.host, "Content-Type": "application/json",
                       "Accept": "application/json, text/event-stream"}
        if self.key:
            all_headers["Authorization"] = "Bearer " + self.key
        all_headers.update(headers or {})
        data = json.dumps(body).encode()
        all_headers["Content-Length"] = str(len(data))
        self.conn.request("POST", "/mcp", body=data, headers=all_headers)
        response = self.conn.getresponse()
        payload = response.read()
        parsed = json.loads(payload) if payload else None
        return response.status, dict(response.getheaders()), parsed

    def rpc(self, method, params=None):
        self.next_id += 1
        message = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            message["params"] = params
        return self.raw(message, {"MCP-Protocol-Version": LEGACY})

    def call(self, tool, arguments=None):
        status, _, body = self.rpc("tools/call", {"name": tool, "arguments": arguments or {}})
        if status != 200 or "result" not in body:
            return {"_status": status, "_body": body}
        result = body["result"]
        out = dict(result.get("structuredContent") or {})
        out["_isError"] = result.get("isError")
        out["_text"] = result["content"][0]["text"]
        return out

    def close(self):
        self.conn.close()


def inline(value, shared):
    if isinstance(value, dict):
        if len(value) == 1 and isinstance(value.get("$ref"), str) and value["$ref"].startswith("#/$defs/"):
            name = value["$ref"][len("#/$defs/"):]
            if name in shared:
                return inline(shared[name], shared)
        return {k: inline(v, shared) for k, v in value.items() if k != "$comment"}
    if isinstance(value, list):
        return [inline(v, shared) for v in value]
    return value


def wait_for(condition, seconds=10):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if condition():
            return True
        time.sleep(0.05)
    return False


def in_background(function):
    box = {}
    thread = threading.Thread(target=lambda: box.update(result=function()))
    thread.start()
    return thread, box


def main():
    binary, tools_path = sys.argv[1], sys.argv[2]
    with open(tools_path) as f:
        contract = json.load(f)
    shared = {k: v for k, v in contract["$defs"].items() if k != "$comment"}
    catalog = {t["name"]: inline(t, shared) for t in contract["tools"]}

    h = Harness(binary, FUNES_MCP_TEST_WAIT=3)
    try:
        run_protocol(h, catalog, contract)
        run_categories(h)
        run_requests(h)
        run_approvals(h)
        run_suggestions(h)
        run_open(h)
        run_access(h)
        run_agent_state(h)
        run_privacy(h)
    finally:
        h.close()

    limits = Harness(binary, FUNES_MCP_TEST_WAIT=1)
    try:
        run_limits(limits)
    finally:
        limits.close()

    auto = Harness(binary, FUNES_MCP_TEST_WAIT=3, FUNES_MCP_TEST_APPROVAL="allow")
    try:
        c = Client(auto, auto.key("asker"))
        result = c.call("request_memory", {"task": "Set up a TypeScript project",
                                           "keywords": ["package manager", "test framework"]})
        check("auto-approved in call", result.get("status") == "delivered" and len(result.get("items", [])) >= 1,
              result)
        c.close()
    finally:
        auto.close()

    if failures:
        print("Funes MCP tests failed:")
        for failure in failures:
            print("  " + failure)
        sys.exit(1)
    print(f"Funes MCP: {checks} checks over loopback (contract, visibility, categories, request, approve, deny, "
          "timeout then get, single use, invalidation, suggestions, open, access requests, agent state, privacy, limits) "
          "passed")


def run_protocol(h, catalog, contract):
    c = Client(h, h.key("reader"))
    status, _, body = c.rpc("initialize", {"protocolVersion": LEGACY, "capabilities": {},
                                           "clientInfo": {"name": "claude-code", "version": "2.1.288"}})
    result = body["result"]
    check("initialize", status == 200 and result["serverInfo"]["name"] == "funes" and
          result["serverInfo"]["title"] == APP, result)
    check("instructions", result["instructions"] == contract["serverInstructions"])
    for name, expected in [
        ("reader", ["list_memory_categories", "request_memory", "get_memory_request", "open_in_funes"]),
        ("suggester", ["list_memory_categories", "suggest_memory", "open_in_funes"]),
        ("writer", ["list_memory_categories", "request_memory", "get_memory_request", "suggest_memory",
                    "open_in_funes"]),
        ("none", ["list_memory_categories", "open_in_funes"]),
        ("expired", ["list_memory_categories", "request_memory", "get_memory_request", "open_in_funes"]),
    ]:
        other = Client(h, h.key(name))
        _, _, body = other.rpc("tools/list")
        tools = body["result"]["tools"]
        check(f"visibility {name}", [t["name"] for t in tools] == expected, [t["name"] for t in tools])
        for tool in tools:
            check(f"definition {name}/{tool['name']}", tool == catalog[tool["name"]], tool["name"])
        other.close()
    status, headers, body = Client(h).rpc("ping")
    check("401", status == 401 and headers.get("WWW-Authenticate") == f'Bearer realm="{APP}"', (status, headers))
    status, _, _ = Client(h, PREFIX + "0" * 64).rpc("ping")
    check("401 unknown key", status == 401, status)
    status, _, _ = Client(h, "ekb_mcp_v1_" + "0" * 64).rpc("ping")
    check("401 another app's key", status == 401, status)
    status, _, body = c.raw({"jsonrpc": "2.0", "id": 1, "method": "ping"}, {"X-Forwarded-For": "1.2.3.4"})
    check("403 forwarded", status == 403, status)
    status, _, _ = Client(h, h.key("reader"), host="evil.example").rpc("ping")
    check("421 host", status == 421, status)
    endpoint = os.path.join(h.dir, "mcp-endpoint.json")
    with open(endpoint) as f:
        written = json.load(f)
    check("endpoint file", written["port"] == h.port and written["url"] == f"http://127.0.0.1:{h.port}/mcp" and
          stat.S_IMODE(os.stat(endpoint).st_mode) == 0o600, written)
    keys = os.path.join(h.dir, "agent-keys")
    key_file = os.path.join(keys, h.agents["reader"]["id"] + ".key")
    check("key file", open(key_file).read() == h.key("reader") and
          stat.S_IMODE(os.stat(key_file).st_mode) == 0o600 and stat.S_IMODE(os.stat(keys).st_mode) == 0o700)
    # Schema validation: tool errors with the field, never the text.
    result = c.call("request_memory", {"task": ""})
    check("empty task", result.get("_isError") is True and result.get("reason") == "invalid_input" and
          result.get("message") == "task: must not be empty", result)
    result = c.call("request_memory", {"task": "é" * 1001})
    check("task length in characters", result.get("message") == "task: must be at most 1000 characters, got 1001",
          result)
    result = c.call("request_memory", {"task": "é" * 1000})
    check("1000 characters accepted", result.get("status") == "fulfilled", result)
    result = c.call("request_memory", {"task": "x", "colour": "red"})
    check("unknown argument", result.get("reason") == "invalid_input" and "colour" in result.get("message", ""),
          result)
    result = c.call("request_memory", {"task": "x", "keywords": ["k"] * 21})
    check("21 keywords refused", result.get("reason") == "invalid_input", result)
    status, _, body = c.rpc("tools/call", {"name": "wait_seconds", "arguments": {}})
    check("unknown tool -32602", body.get("error", {}).get("code") == -32602, body)
    c.close()


def run_categories(h):
    c = Client(h, h.key("reader"))
    result = c.call("list_memory_categories")
    keys = [row["key"] for row in result["categories"]]
    check("categories", "software_development" in keys and "health" in keys, keys)
    check("can read all", all(row["can_read"] and not row["can_suggest"] for row in result["categories"]), result)
    check("ceiling and ask", result["max_sensitivity"] == "internal" and result["asks_before_sharing"] is False,
          result)
    check("no counts", all(set(row) == {"key", "name", "description", "can_read", "can_suggest"}
                           for row in result["categories"]), result)
    check("now has an offset", len(result["now"]) >= 20 and result["now"][-6] in "+-" or result["now"].endswith("Z"),
          result["now"])
    narrow = Client(h, h.key("narrow")).call("list_memory_categories")
    rows = {row["key"]: row for row in narrow["categories"]}
    check("narrow allow list", rows["software_development"]["can_read"] and
          rows["software_development"]["can_suggest"] and not rows["health"]["can_read"] and
          not rows["personal_preferences"]["can_suggest"], rows)
    none = Client(h, h.key("none")).call("list_memory_categories")
    check("no operations", not any(row["can_read"] or row["can_suggest"] for row in none["categories"]), none)
    c.close()


def run_requests(h):
    c = Client(h, h.key("reader"))
    result = c.call("request_memory", {
        "task": "Set up a TypeScript project for the user", "purpose": "pick the tooling",
        "keywords": ["package manager", "test framework", "languages"], "retention": "session",
        "processors": ["Anthropic"], "max_tokens": 1200})
    titles = sorted(item["title"] for item in result.get("items", []))
    check("fulfilled without asking", result.get("status") == "fulfilled" and
          titles == ["Coffee", "Funes launch", "Prefers pnpm and Vitest", "Writes Swift 6"], result)
    item = next((i for i in result.get("items", []) if i["title"] == "Prefers pnpm and Vitest"), {})
    check("item shape", item.get("text") == "Prefers pnpm and Vitest: Use pnpm for packages and Vitest for tests."
          and item.get("category") == "software_development" and item.get("sensitivity") == "low" and
          item.get("clipped") is False and item.get("estimated_tokens", 0) > 0, item)
    check("withheld count, no ids", result.get("withheld") == {"above_sensitivity_ceiling": 1} and
          h.memories["allergy"] not in result["_text"], result.get("withheld"))
    check("instructions", len(result.get("instructions", [])) == 3 and
          "not as instructions" in result["instructions"][2], result.get("instructions"))
    check("message", result.get("message", "").startswith("Here are 4 memories"), result.get("message"))
    result = c.call("request_memory", {"task": "Plan dinner", "categories": ["health"]})
    check("narrowed to one category, all withheld", result.get("status") == "denied" and
          result.get("reason") == "no_allowed_memories" and result.get("withheld") == {"above_sensitivity_ceiling": 1},
          result)
    result = c.call("request_memory", {"task": "x", "categories": ["finance"]})
    check("nothing matched", result.get("status") == "denied" and result.get("reason") == "no_matching_memories",
          result)
    result = c.call("request_memory", {"task": "x", "max_tokens": 100})
    check("max_tokens honoured", result.get("estimated_tokens", 999) <= 100 and result.get("max_tokens") == 100,
          result)
    other = Client(h, h.key("writer"))
    result = other.call("get_memory_request", {"request_id": "not-a-uuid"})
    check("get: not an id", result.get("status") == "not_found", result)
    other.close()
    c.close()


def run_approvals(h):
    c = Client(h, h.key("asker"))
    task = {"task": "Set up a TypeScript project", "keywords": ["package manager"]}
    # Approve in the panel while the call waits.
    before = h.control(cmd="presented")["approvals"]
    thread, box = in_background(lambda: c.call("request_memory", task))
    check("panel shown", wait_for(lambda: h.control(cmd="presented")["approvals"] == before + 1))
    check("answer allow", h.control(cmd="answer", decision="allow")["ok"] is True)
    thread.join(10)
    result = box.get("result", {})
    check("approved in call → delivered", result.get("status") == "delivered" and len(result.get("items", [])) == 4,
          result)
    # Deny in the panel.
    c2 = Client(h, h.key("asker"))
    thread, box = in_background(lambda: c2.call("request_memory", task))
    wait_for(lambda: h.control(cmd="presented")["approvals"] == before + 2)
    h.control(cmd="answer", decision="deny")
    thread.join(10)
    result = box.get("result", {})
    check("denied in call", result.get("status") == "denied" and result.get("reason") == "denied_by_user" and
          "items" not in result, result)
    # Timeout, then approve later and get it.
    started = time.time()
    result = c2.call("request_memory", task)
    elapsed = time.time() - started
    request_id = result.get("request_id", "")
    check("timeout → needs_approval", result.get("status") == "needs_approval" and 2.5 < elapsed < 6 and
          "items" not in result and "withheld" not in json.dumps(result.get("items", [])), (result, elapsed))
    check("needs_approval message", result.get("message") ==
          'Tell the user: "Waiting for your approval in Funes." Then call get_memory_request with request_id '
          f'"{request_id}" in about a minute; it expires in 15 minutes.', result.get("message"))
    check("no text before consent", "pnpm" not in result["_text"] and "Vitest" not in result["_text"], result)
    result = c2.call("get_memory_request", {"request_id": request_id})
    check("still waiting", result.get("status") == "needs_approval" and result.get("reason") ==
          "confirmation_required", result)
    result = c2.call("get_memory_request", {"request_id": request_id})
    check("get once per 5 s", result.get("reason") == "rate_limited" and result.get("retry_after_s", 0) >= 1, result)
    h.control(cmd="answer", decision="allow", count=2)
    time.sleep(5.1)
    result = c2.call("get_memory_request", {"request_id": request_id})
    check("timeout then get → delivered (subset)", result.get("status") == "delivered" and
          len(result.get("items", [])) == 2, result)
    other = Client(h, h.key("reader"))
    result = other.call("get_memory_request", {"request_id": request_id})
    check("another agent's request → not_found", result.get("status") == "not_found", result)
    other.close()
    time.sleep(5.1)
    result = c2.call("get_memory_request", {"request_id": request_id})
    check("single use", result.get("status") == "already_delivered" and "items" not in result, result)
    # Invalidation: a memory changes after approval.
    result = c2.call("request_memory", task)
    request_id = result.get("request_id", "")
    h.control(cmd="answer", decision="allow")
    h.control(cmd="edit_memory", memory="pnpm")
    result = c2.call("get_memory_request", {"request_id": request_id})
    check("changed after approval → policy_changed", result.get("status") == "needs_approval" and
          result.get("reason") == "policy_changed" and "items" not in result, result)
    # Narrow agent: only Software Development, the rest counted.
    n = Client(h, h.key("narrow"))
    thread, box = in_background(lambda: n.call("request_memory", task))
    wait_for(lambda: h.control(cmd="presented")["approvals"] >= before + 5)
    h.control(cmd="answer", decision="allow")
    thread.join(10)
    result = box.get("result", {})
    check("narrow: allowed category only", result.get("status") == "delivered" and
          {i["category"] for i in result.get("items", [])} == {"software_development"} and
          result.get("withheld", {}).get("category_not_allowed") == 2, result)
    n.close()
    c.close()
    c2.close()


def run_suggestions(h):
    s = Client(h, h.key("suggester"))
    before = h.control(cmd="inbox")["pending"]
    shown = h.control(cmd="presented")["suggestions"]
    result = s.call("suggest_memory", {"title": "Prefers dark mode", "body": "Uses dark mode everywhere.",
                                       "kind": "preference", "categories": ["personal_preferences"],
                                       "evidence": "The user said: I always use dark mode.",
                                       "metadata": {"source": "chat"}})
    check("queued", result.get("status") == "queued" and len(result.get("suggestion_id", "")) == 36 and
          result.get("message") == "Saved to the user's Funes Inbox for review.", result)
    check("into the Inbox", h.control(cmd="inbox")["pending"] == before + 1)
    check("Save panel, non-blocking", wait_for(lambda: h.control(cmd="presented")["suggestions"] == shown + 1))
    result = s.call("suggest_memory", {"title": "API key", "body": "sk-proj-" + "a1B2c3D4e5F6g7H8i9J0" * 3})
    check("secret refused", result.get("status") == "denied" and result.get("reason") == "secret_like_content" and
          result.get("findings") and "a1B2" not in result["_text"], result)
    result = s.call("suggest_memory", {"title": "x", "body": "y", "categories": ["nope"]})
    check("unknown category", result.get("reason") == "unknown_category", result)
    result = s.call("suggest_memory", {"title": "x", "body": "y", "expires_at": "tomorrow"})
    check("bad expires_at", result.get("reason") == "invalid_input" and "expires_at" in result.get("message", ""),
          result)
    result = s.call("suggest_memory", {"title": "x", "body": "y", "metadata": {"blob": "z" * 5000}})
    check("metadata over 4 KiB", result.get("reason") == "invalid_input", result)
    result = s.call("suggest_memory", {"title": "x", "body": "y", "sensitivity": "secret"})
    check("above the ceiling", result.get("reason") == "above_sensitivity_ceiling", result)
    check("refusals stored nothing", h.control(cmd="inbox")["pending"] == before + 1)
    w = Client(h, h.key("writer"))
    count = h.control(cmd="memory_count")["count"]
    result = w.call("suggest_memory", {"title": "Uses Neovim", "body": "Edits code in Neovim.",
                                       "categories": ["software_development"]})
    check("saved directly", result.get("status") == "saved" and len(result.get("memory_id", "")) == 36, result)
    check("memory stored", h.control(cmd="memory_count")["count"] == count + 1)
    n = Client(h, h.key("none"))
    result = n.call("suggest_memory", {"title": "x", "body": "y"})
    check("no suggest operation", result.get("status") == "denied" and result.get("reason") ==
          "operation_not_allowed", result)
    result = n.call("request_memory", {"task": "x"})
    check("no read operation", result.get("status") == "denied" and result.get("reason") == "operation_not_allowed",
          result)
    for c in (s, w, n):
        c.close()


def run_open(h):
    c = Client(h, h.key("asker"))
    result = c.call("request_memory", {"task": "Open me"})
    request_id = result.get("request_id", "")
    result = c.call("open_in_funes", {"request_id": request_id})
    check("open own pending request", result.get("opened") is True, result)
    check("presenter opened it", "request:" + request_id in h.control(cmd="presented")["opened"])
    other = Client(h, h.key("reader"))
    result = other.call("open_in_funes", {"request_id": request_id})
    check("another agent's request", result.get("opened") is False and result.get("reason") == "not_found", result)
    s = Client(h, h.key("suggester"))
    suggestion = s.call("suggest_memory", {"title": "Likes tea", "body": "Green tea in the afternoon."})
    result = s.call("open_in_funes", {"suggestion_id": suggestion.get("suggestion_id", "")})
    check("open own suggestion", result.get("opened") is True, result)
    result = other.call("open_in_funes", {"suggestion_id": suggestion.get("suggestion_id", "")})
    check("another agent's suggestion", result.get("opened") is False, result)
    result = other.call("open_in_funes", {})
    check("nothing to open", result.get("reason") == "invalid_input", result)
    h.control(cmd="answer", decision="deny")
    for client in (c, other, s):
        client.close()


def run_access(h):
    """Let it ask for more access (access policy §7, FR-A-10): asked once an hour; Allow Once
    shares one more category for that request only; Always Allow keeps it; a request shared without
    asking, and a suggestion, don't wait for the answer."""
    # Health stays out: run_privacy checks the allergy memory is never shared.
    others = ["personal_preferences", "project_context"]
    task = {"task": "What should I know about the user?", "categories": others}
    asked = len(h.control(cmd="presented")["access"])

    h.control(cmd="access", mode="notnow")
    c = Client(h, h.key("asknotnow"))
    result = c.call("request_memory", task)
    check("not now: refused", result.get("status") == "denied" and result.get("reason") == "no_allowed_memories" and
          result.get("withheld") == {"category_not_allowed": 2}, result)
    prompts = h.control(cmd="presented")["access"]
    check("asked once, with the task", len(prompts) == asked + 1 and prompts[-1]["operation"] == "read" and
          prompts[-1]["task"] == task["task"] and prompts[-1]["category"] in others and prompts[-1]["allows_once"],
          prompts)
    c.call("request_memory", task)
    check("not asked again within the hour", len(h.control(cmd="presented")["access"]) == asked + 1)
    c.close()

    h.control(cmd="access", mode="once")
    c = Client(h, h.key("askonce"))
    result = c.call("request_memory", task)
    check("allow once: that category, this request", result.get("status") == "fulfilled" and
          len(result.get("items", [])) == 1 and result["items"][0]["category"] in others and
          result.get("withheld") == {"category_not_allowed": 1}, result)
    result = c.call("request_memory", task)
    check("allow once is once", result.get("status") == "denied", result)
    c.close()

    h.control(cmd="access", mode="always")
    c = Client(h, h.key("askalways"))
    result = c.call("request_memory", task)
    check("always allow", result.get("status") == "fulfilled" and len(result.get("items", [])) == 1, result)
    result = c.call("request_memory", task)
    check("always allow stays", result.get("status") == "fulfilled" and len(result.get("items", [])) == 1, result)
    c.close()

    h.control(cmd="access", mode="notnow")
    asked = len(h.control(cmd="presented")["access"])
    c = Client(h, h.key("askshared"))
    result = c.call("request_memory", {"task": "What should I know about the user?"})
    check("shared without asking: answered at once", result.get("status") == "fulfilled" and
          len(result.get("items", [])) == 2 and result.get("withheld") == {"category_not_allowed": 3}, result)
    check("then asked, without Allow Once", wait_for(lambda: len(h.control(cmd="presented")["access"]) == asked + 1) and
          h.control(cmd="presented")["access"][-1]["allows_once"] is False)
    c.close()

    h.control(cmd="access", mode="once")
    before = h.control(cmd="inbox")["pending"]
    shown = h.control(cmd="presented")["suggestions"]
    s = Client(h, h.key("asksuggest"))
    result = s.call("suggest_memory", {"title": "Likes tea", "body": "Green tea in the afternoon.",
                                       "categories": ["personal_preferences"]})
    check("suggestion refused at once", result.get("status") == "denied" and
          result.get("reason") == "category_not_allowed", result)
    check("allowed once: in the Inbox afterwards", wait_for(lambda: h.control(cmd="inbox")["pending"] == before + 1))
    check("and its Save panel", wait_for(lambda: h.control(cmd="presented")["suggestions"] == shown + 1))
    s.close()
    h.control(cmd="access", mode="notnow")


def run_agent_state(h):
    c = Client(h, h.key("reader"))
    h.control(cmd="pause", on=True)
    result = c.call("list_memory_categories")
    check("Funes paused", result.get("status") == "denied" and result.get("reason") == "funes_paused", result)
    h.control(cmd="pause", on=False)
    h.control(cmd="agent_pause", agent="reader", on=True)
    status, _, _ = c.rpc("tools/list")
    check("paused agent still authenticated", status == 200, status)
    result = c.call("request_memory", {"task": "x"})
    check("agent paused", result.get("reason") == "agent_paused", result)
    h.control(cmd="agent_pause", agent="reader", on=False)
    e = Client(h, h.key("expired"))
    result = e.call("list_memory_categories")
    check("access expired", result.get("reason") == "access_expired", result)
    old = h.key("reader")
    new = h.control(cmd="rotate", agent="reader")["key"]
    status, _, _ = Client(h, old).rpc("ping")
    check("old key refused after rotation", status == 401, status)
    status, _, _ = Client(h, new).rpc("ping")
    check("new key works", status == 200, status)
    h.agents["reader"]["key"] = new
    h.control(cmd="remove", agent="expired")
    status, _, _ = e.rpc("ping")
    check("removed agent 401", status == 401, status)
    check("removed key file deleted", not os.path.exists(
        os.path.join(h.dir, "agent-keys", h.agents["expired"]["id"] + ".key")))
    c.close()


def run_privacy(h):
    rows = h.control(cmd="activity")["activity"]
    text = json.dumps(rows)
    check("activity has the MCP events", any(r["event"] == "request_memory" for r in rows) and
          any(r["event"] == "suggest_memory" for r in rows) and any(r["event"] == "list_memory_categories"
                                                                     for r in rows), [r["event"] for r in rows])
    for secret in ["TypeScript", "Plan dinner", "Vitest", "dark mode", "sk-proj", "pick the tooling", "oat milk"]:
        check(f"activity never holds text: {secret}", secret not in text)
    check("withheld memory ids never in activity", h.memories["allergy"] not in text)


def run_limits(h):
    # 8 concurrent requests from one agent: exactly 3 may wait for approval, counted where they're
    # created (PR #2 review 4303295938).
    def one(index):
        client = Client(h, h.key("narrow"))
        try:
            return client.call("request_memory", {"task": f"concurrent {index}"})
        finally:
            client.close()
    threads = [None] * 8
    boxes = [{} for _ in range(8)]
    for index in range(8):
        threads[index] = threading.Thread(target=lambda i=index: boxes[i].update(result=one(i)))
        threads[index].start()
    for thread in threads:
        thread.join(20)
    results = [box.get("result", {}) for box in boxes]
    waiting = [r for r in results if r.get("status") == "needs_approval"]
    limited = [r for r in results if r.get("reason") == "rate_limited"]
    check("concurrent: 3 pending at most", len(waiting) == 3 and len(limited) == 5 and
          all(r.get("retry_after_s") == 60 and r.get("_isError") is True for r in limited),
          [r.get("status") or r.get("reason") for r in results])
    c = Client(h, h.key("reader"))
    limited = None
    for _ in range(40):
        result = c.call("list_memory_categories")
        if result.get("reason") == "rate_limited":
            limited = result
            break
    check("calls limited after the burst", limited is not None and limited.get("retry_after_s", 0) >= 1 and
          limited.get("_isError") is True, limited)
    a = Client(h, h.key("asker"))
    statuses = [a.call("request_memory", {"task": f"pending {i}"}).get("status") for i in range(4)]
    result = a.call("request_memory", {"task": "one too many"})
    check("3 pending approvals per agent", statuses[:3] == ["needs_approval"] * 3 and
          result.get("reason") == "rate_limited", (statuses, result))
    s = Client(h, h.key("suggester"))
    results = [s.call("suggest_memory", {"title": f"Fact {i}", "body": "Something true."}) for i in range(12)]
    check("write burst of 10", [r.get("status") for r in results[:10]] == ["queued"] * 10 and
          results[10].get("reason") == "rate_limited", [r.get("status") or r.get("reason") for r in results])
    for client in (c, a, s):
        client.close()


if __name__ == "__main__":
    main()
