"""Funes's Remote Access paths over real loopback sockets (Phase 4b, task 4b.13).

Runs funes-mcp-test-server with its remote listener (`remote_start`: a second loopback port,
the public origin https://remote.test faked through Host, as a tunnel forwards it) and the
fake sign-in approver. Checks what Funes adds on top of BridgeKitRemote's own harness:
- the gate (404 outside the secret, 421, 403) and credentials kept apart;
- an agent's Allow cloud access, its remote token and its OAuth-connected apps;
- OAuth pairing opened for one agent, code, token, refresh, reuse revokes;
- turning Remote Access off;
- the same decision, local vs remote: one agent with a local key and a remote token, the same
  requests through both listeners, the results compared field by field (not ids);
- the rate limits shared by both listeners, plus the stricter remote buckets.
Standard library only.

Usage: remote_test.py SERVER_BINARY
"""

import base64
import hashlib
import http.client
import json
import os
import re
import sys
import threading
import time
from urllib.parse import parse_qs, urlencode, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcp_test  # noqa: E402
from mcp_test import LEGACY, Client, Harness, check, in_background, wait_for  # noqa: E402

SECRET = "q7Zk2vN4bXwP9sL1mT6hYa"
PREFIX = "/r/" + SECRET
REMOTE_HOST = "remote.test"
RESOURCE = f"https://{REMOTE_HOST}{PREFIX}/mcp"
ISSUER = f"https://{REMOTE_HOST}{PREFIX}"
CALLBACK = "https://claude.ai/api/mcp/auth_callback"
LIST = {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}


class Remote(Client):
    """A client of the Remote Access port, as a tunnel forwards it."""

    def __init__(self, harness, port, key=None, host=REMOTE_HOST, forwarded="203.0.113.7"):
        self.h = harness
        self.key = key
        self.host = host
        self.port = port
        self.conn = http.client.HTTPConnection("127.0.0.1", port, timeout=70)
        self.next_id = 1
        self.forwarded = forwarded

    def request(self, method="POST", path=PREFIX + "/mcp", body=None, headers=None, content_type="application/json",
                auth=True):
        all_headers = {"Host": self.host, "X-Forwarded-For": self.forwarded, "Tailscale-Funnel-Request": "?1",
                       "Accept": "application/json, text/event-stream"}
        if content_type:
            all_headers["Content-Type"] = content_type
        if auth and self.key:
            all_headers["Authorization"] = "Bearer " + self.key
        all_headers.update(headers or {})
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        body = body or b""
        if method == "POST":
            all_headers["Content-Length"] = str(len(body))
        self.conn.request(method, path, body=body if body else None, headers=all_headers)
        response = self.conn.getresponse()
        payload = response.read()
        parsed = None
        if payload and response.getheader("Content-Type", "").startswith("application/json"):
            parsed = json.loads(payload)
        return response.status, dict(response.getheaders()), parsed, payload

    def raw(self, body, headers=None):
        status, headers, parsed, _ = self.request(body=body, headers={"MCP-Protocol-Version": LEGACY,
                                                                       **(headers or {})})
        return status, headers, parsed


def start(h):
    h.control(cmd="remote_start")
    wait_for(lambda: h.control(cmd="remote_port")["port"] is not None)
    return h.control(cmd="remote_port")["port"]


def cloud(h, name):
    """Allow cloud access for an agent and issue its remote token."""
    h.control(cmd="set_cloud", agent=name, on=True)
    issued = h.control(cmd="issue_remote_key", agent=name)
    return issued["key"]


def run_gate(h, port):
    token = cloud(h, "reader")
    check("remote key prefix and file", token.startswith("fns_mcpr_v1_") and len(token) == 12 + 64 and
          h.control(cmd="remote_key_file", agent="reader") == {"exists": True, "mode": 0o600}, token[:12])
    for path in ["/", "/mcp", "/r/wrong/mcp", PREFIX + "x/mcp", PREFIX + "/other",
                 "/.well-known/oauth-authorization-server"]:
        status, _, _, _ = Remote(h, port, token, host="evil.example").request(path=path, body=LIST)
        check(f"404 outside the secret {path}", status == 404, status)
    status, _, _, _ = Remote(h, port, token, host="evil.example").request(body=LIST)
    check("421 for a foreign Host", status == 421, status)
    status, _, _, _ = Remote(h, port, token).request(body=LIST, headers={"Origin": "https://evil.example"})
    check("403 for Origin", status == 403, status)
    for host in [REMOTE_HOST, f"127.0.0.1:{port}", f"localhost:{port}"]:
        status, _, body, _ = Remote(h, port, token, host=host).request(body=LIST)
        check(f"remote Host {host}", status == 200 and "result" in (body or {}), (status, body))

    # Credentials stay apart.
    status, headers, body, _ = Remote(h, port, h.key("reader")).request(body=LIST)
    challenge = headers.get("WWW-Authenticate", "")
    check("a local key is refused remotely", status == 401 and
          f'resource_metadata="https://{REMOTE_HOST}/.well-known/oauth-protected-resource{PREFIX}/mcp"' in challenge
          and 'scope="memory"' in challenge, (status, challenge))
    check("remote 401 wording", "Funes Vault doesn't recognize this credential" in json.dumps(body), body)
    local = Client(h, token)
    status, _, _ = local.rpc("tools/list")
    check("a remote token is refused locally", status == 401, status)
    local.close()
    # The local port is unchanged: tunnel and forwarding headers get 403 there, credentials or not.
    for header in ["X-Forwarded-For", "Tailscale-Funnel-Request", "CF-Ray", "Forwarded"]:
        local = Client(h, h.key("reader"))
        status, _, _ = local.raw({"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
                                 {"MCP-Protocol-Version": LEGACY, header: "203.0.113.7"})
        check(f"local port refuses {header}", status == 403, status)
        local.close()

    # An agent without cloud access gets 401, even with a well-formed token of its own making.
    status, _, _, _ = Remote(h, port, "fns_mcpr_v1_" + "0" * 64).request(body=LIST)
    check("unknown remote token 401", status == 401, status)

    # A remote call: same tools, same pipeline, Activity marks it remote.
    r = Remote(h, port, token)
    status, _, body, _ = r.request(body=LIST)
    names = sorted(t["name"] for t in body["result"]["tools"])
    check("remote tools as for the agent", names == ["get_memory_request", "list_memory_categories", "open_in_funes",
                                                     "request_memory"], names)
    result = r.call("list_memory_categories")
    check("remote call", result.get("_isError") is False and len(result.get("categories", [])) > 0, result)
    row = h.control(cmd="activity")["activity"][0]
    check("Activity via remote", row["via"] == "remote" and row["event"] == "list_memory_categories", row)
    notes = h.control(cmd="remote_notes")["notes"]
    check("tunnel and forwarded address kept", notes and notes[0]["tunnel"] == "Tailscale Funnel" and
          notes[0]["address"] == "203.0.113.7" and notes[0]["agentID"] == h.agents["reader"]["id"], notes[:1])
    l = Client(h, h.key("reader"))
    l.call("list_memory_categories")
    check("the same agent locally: via mcp", h.control(cmd="activity")["activity"][0]["via"] == "mcp")
    l.close()

    # Turning cloud access off: the token stops at once, and the revision goes up.
    before = h.control(cmd="agent", agent="reader")["agent"]["revision"]
    h.control(cmd="set_cloud", agent="reader", on=False)
    after = h.control(cmd="agent", agent="reader")["agent"]
    status, _, _, _ = Remote(h, port, token).request(body=LIST)
    check("cloud access off: 401", status == 401 and after["revision"] > before and after["remote_key"] is False and
          h.control(cmd="remote_key_file", agent="reader") == {"exists": False}, (status, after))
    h.control(cmd="set_cloud", agent="reader", on=True)
    status, _, _, _ = Remote(h, port, token).request(body=LIST)
    check("the old token stays dead", status == 401, status)
    token = h.control(cmd="issue_remote_key", agent="reader")["key"]
    reset = h.control(cmd="issue_remote_key", agent="reader")
    status, _, _, _ = Remote(h, port, token).request(body=LIST)
    status2, _, _, _ = Remote(h, port, reset["key"]).request(body=LIST)
    check("Reset Remote Token: the old one fails, the new one works", status == 401 and status2 == 200 and
          reset["file_matches"] is True, (status, status2))
    # Removed agents: 401.
    gone = cloud(h, "writer")
    h.control(cmd="remove_cloud_agent", agent="writer")
    status, _, _, _ = Remote(h, port, gone).request(body=LIST)
    check("removed agent 401", status == 401, status)

    # Paused and expired agents still authenticate and get their reason codes, as locally.
    expired = cloud(h, "expired")
    result = Remote(h, port, expired).call("request_memory", {"task": "x"})
    check("expired agent: reason code", result.get("reason") == "access_expired", result)
    h.control(cmd="agent_pause", agent="reader", on=True)
    result = Remote(h, port, reset["key"]).call("list_memory_categories")
    check("paused agent: reason code", result.get("reason") == "agent_paused", result)
    h.control(cmd="agent_pause", agent="reader", on=False)
    return reset["key"]


def status_url(page):
    found = re.search(rb'data-request="([0-9A-Za-z-]+)"', page)
    return PREFIX + "/oauth/authorize/status?request=" + found.group(1).decode() if found else None


def run_oauth(h, port):
    o = Remote(h, port)
    status, _, prm, _ = o.request(method="GET", path=f"/.well-known/oauth-protected-resource{PREFIX}/mcp",
                                  content_type=None)
    check("PRM", status == 200 and prm["resource"] == RESOURCE and prm["scopes_supported"] == ["memory"], prm)
    status, _, asm, _ = o.request(method="GET", path=f"/.well-known/oauth-authorization-server{PREFIX}",
                                  content_type=None)
    check("AS metadata", status == 200 and asm["issuer"] == ISSUER, asm)
    verifier = "v" * 64
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")

    def register():
        return o.request(path=PREFIX + "/oauth/register", body={"redirect_uris": [CALLBACK], "client_name": "claude.ai"})

    def authorize(client_id):
        query = urlencode({"response_type": "code", "client_id": client_id, "redirect_uri": CALLBACK,
                           "code_challenge": challenge, "code_challenge_method": "S256", "state": "s1",
                           "resource": RESOURCE})
        return o.request(method="GET", path=PREFIX + "/oauth/authorize?" + query, content_type=None)

    def token(fields):
        return o.request(path=PREFIX + "/oauth/token", body=urlencode(fields).encode(),
                         content_type="application/x-www-form-urlencoded")

    # Pairing closed: nothing is shown on the Mac.
    status, _, body, _ = register()
    check("DCR needs pairing", status == 403 and "open the agent" in body.get("error_description", ""), body)
    status, _, _, page = authorize("dcr_none")
    check("pairing closed: page, nothing shown", status == 403 and b"Pairing isn" in page and
          h.control(cmd="pairings")["pending"] == [], status)
    # Pairing needs cloud access.
    check("no pairing without cloud access", h.control(cmd="open_pairing", agent="asker")["ok"] is False)

    cloud(h, "asker")
    before = h.control(cmd="agent", agent="asker")["agent"]["revision"]
    check("pairing opened for one agent", h.control(cmd="open_pairing", agent="asker")["ok"] is True and
          h.control(cmd="pairings")["open"] == h.agents["asker"]["id"])
    status, _, reg, _ = register()
    check("DCR", status == 201 and reg["client_id"].startswith("dcr_"), reg)
    status, headers, _, page = authorize(reg["client_id"])
    pending = h.control(cmd="pairings")["pending"]
    check("sign-in page: code, agent, return host", status == 200 and len(pending) == 1 and
          pending[0]["code"].replace(" ", "").encode() in page.replace(b" ", b"") and
          b"<dt>Agent</dt><dd>asker</dd>" in page and pending[0]["redirectHost"] == "claude.ai" and
          b"Connect claude.ai to Funes Vault" in page, (status, pending))
    h.control(cmd="answer_pairing", allow=True)
    _, _, answered, _ = o.request(method="GET", path=status_url(page), content_type=None)
    params = parse_qs(urlparse(answered.get("redirect", "")).query)
    check("code returned with state and iss", params.get("state") == ["s1"] and params.get("iss") == [ISSUER] and
          "code" in params, answered)
    status, _, tokens, _ = token({"grant_type": "authorization_code", "code": params["code"][0],
                                  "client_id": reg["client_id"], "redirect_uri": CALLBACK, "code_verifier": verifier,
                                  "resource": RESOURCE})
    check("token", status == 200 and tokens["access_token"].startswith("fns_oat_v1_") and
          tokens["refresh_token"].startswith("fns_ort_v1_") and tokens["scope"] == "memory", tokens)
    check("connected app listed", h.control(cmd="oauth_connections", agent="asker")["names"] == ["claude.ai"])
    check("connecting an app bumps the revision",
          wait_for(lambda: h.control(cmd="agent", agent="asker")["agent"]["revision"] > before))
    m = Remote(h, port, tokens["access_token"])
    result = m.call("list_memory_categories")
    check("MCP with the OAuth token, as the agent", result.get("_isError") is False and
          result.get("asks_before_sharing") is True, result)
    local = Client(h, tokens["access_token"])
    status, _, _ = local.rpc("tools/list")
    check("an OAuth token is refused locally", status == 401, status)
    local.close()
    status, _, rotated, _ = token({"grant_type": "refresh_token", "refresh_token": tokens["refresh_token"],
                                   "client_id": reg["client_id"]})
    check("refresh rotates", status == 200 and rotated["refresh_token"] != tokens["refresh_token"], rotated)
    status, _, _, _ = Remote(h, port, rotated["access_token"]).request(body=LIST)
    check("rotated access works", status == 200, status)
    status, _, reuse, _ = token({"grant_type": "refresh_token", "refresh_token": tokens["refresh_token"],
                                 "client_id": reg["client_id"]})
    status2, _, _, _ = Remote(h, port, rotated["access_token"]).request(body=LIST)
    check("reusing a rotated refresh token revokes", status == 400 and reuse["error"] == "invalid_grant" and
          status2 == 401 and h.control(cmd="oauth_connections", agent="asker")["count"] == 0, (status, status2))

    # Again, then Revoke from the Mac, then cloud access off revokes too.
    def connect():
        h.control(cmd="open_pairing", agent="asker")
        _, _, _, page = authorize(reg["client_id"])
        h.control(cmd="answer_pairing", allow=True)
        _, _, answered, _ = o.request(method="GET", path=status_url(page), content_type=None)
        code = parse_qs(urlparse(answered["redirect"]).query)["code"][0]
        _, _, tokens, _ = token({"grant_type": "authorization_code", "code": code, "client_id": reg["client_id"],
                                 "redirect_uri": CALLBACK, "code_verifier": verifier})
        return tokens
    tokens = connect()
    app = h.control(cmd="oauth_connections", agent="asker")["ids"][0]
    h.control(cmd="revoke_app", id=app)
    status, _, _, _ = Remote(h, port, tokens["access_token"]).request(body=LIST)
    check("Revoke", status == 401, status)
    tokens = connect()
    h.control(cmd="set_cloud", agent="asker", on=False)
    status, _, _, _ = Remote(h, port, tokens["access_token"]).request(body=LIST)
    check("cloud access off revokes apps", status == 401 and
          h.control(cmd="oauth_connections", agent="asker")["count"] == 0, status)
    h.control(cmd="set_cloud", agent="asker", on=True)
    tokens = connect()
    revoked = h.control(cmd="remote_secret", secret="Zz9Yy8Xx7Ww6Vv5Uu4Tt3S")
    status, _, _, _ = Remote(h, port, tokens["access_token"]).request(path="/r/Zz9Yy8Xx7Ww6Vv5Uu4Tt3S/mcp", body=LIST)
    check("Reset Path disconnects apps", revoked["revoked"] == 1 and status == 401, (revoked, status))
    h.control(cmd="remote_secret", secret=SECRET)
    # Deny on the code panel.
    h.control(cmd="open_pairing", agent="asker")
    _, _, _, page = authorize(reg["client_id"])
    h.control(cmd="answer_pairing", allow=False)
    _, _, answered, _ = o.request(method="GET", path=status_url(page), content_type=None)
    params = parse_qs(urlparse(answered.get("redirect", "")).query)
    check("Deny", params.get("error") == ["access_denied"] and
          params.get("error_description") == ["The connection was declined in Funes Vault."], answered)


def run_off(h, port, token):
    h.control(cmd="open_pairing", agent="reader")
    h.control(cmd="remote_stop")
    check("off: pairing ends", h.control(cmd="pairings")["open"] is None)
    try:
        Remote(h, port, token).request(body=LIST)
        refused = False
    except OSError:
        refused = True
    check("off: the URL stops answering", refused)
    check("off: cloud access and the token are kept",
          h.control(cmd="agent", agent="reader")["agent"]["remote_key"] is True)


# MARK: - The same decision, local vs remote

COMPARED = ["status", "reason", "withheld", "estimated_tokens", "max_tokens", "_isError", "asks_before_sharing",
            "max_sensitivity", "profile"]


def shape(result):
    """The fields that must match on both channels: no ids, no times."""
    out = {key: result.get(key) for key in COMPARED}
    out["items"] = sorted((i["title"], i["text"], i["category"], i["sensitivity"], i["estimated_tokens"],
                           i["clipped"]) for i in result.get("items", []))
    out["categories"] = result.get("categories")
    out["retry"] = "retry_after_s" in result
    return out


def run_same_decision(h):
    """One agent per access shape, with a local key and a remote token. Each request goes
    through the local port, then the remote one; the two results must be the same, field by
    field. Approvals are answered the same way on both."""
    port = start(h)
    remote = {name: cloud(h, name) for name in ["reader", "asker", "narrow", "none", "expired", "suggester",
                                                  "writer"]}

    def pair(name):
        return Client(h, h.key(name)), Remote(h, port, remote[name])

    def same(label, local_result, remote_result):
        check(f"same decision: {label}", shape(local_result) == shape(remote_result),
              (shape(local_result), shape(remote_result)))

    # Plain calls: ALLOW, each gate denial, retrieval narrowing, the ceiling.
    plain = [
        ("reader", "list_memory_categories", {}),
        ("reader", "request_memory", {"task": "Set up a TypeScript project", "keywords": ["package manager"]}),
        ("reader", "request_memory", {"task": "Plan dinner", "categories": ["health"]}),
        ("reader", "request_memory", {"task": "x", "categories": ["finance"]}),
        ("reader", "request_memory", {"task": "x", "max_tokens": 100}),
        ("narrow", "list_memory_categories", {}),
        ("none", "request_memory", {"task": "x"}),
        ("none", "list_memory_categories", {}),
        ("expired", "request_memory", {"task": "x"}),
        ("suggester", "request_memory", {"task": "x"}),
        ("reader", "suggest_memory", {"title": "Nope", "body": "Readers can't suggest."}),
    ]
    for name, tool, arguments in plain:
        local, rem = pair(name)
        same(f"{name} {tool} {json.dumps(arguments)[:40]}", local.call(tool, arguments), rem.call(tool, arguments))
        local.close()
        rem.close()
    # About you over Remote Access (access policy §3.10 rule 10): the same fields, after the gate only.
    local, rem = pair("reader")
    answer = rem.call("request_memory", {"task": "What's my name?", "categories": ["finance"]})
    check("remote: the profile with no matching memories", answer.get("profile") ==
          {"name": {"given": "Martin", "family": "Bereciartua", "called": "Martin"}}, answer)
    local.close()
    rem.close()
    rem = Remote(h, port, remote["suggester"])
    check("remote: no profile at the gate", "profile" not in rem.call("request_memory", {"task": "x"}))
    rem.close()
    # get_memory_request is once per 5 s per agent and request id, whichever the channel, so the
    # two unknown ids differ.
    local, rem = pair("reader")
    same("get_memory_request, unknown id",
         local.call("get_memory_request", {"request_id": "00000000-0000-4000-8000-000000000001"}),
         rem.call("get_memory_request", {"request_id": "00000000-0000-4000-8000-000000000002"}))
    local.close()
    rem.close()

    # Paused agent, then Funes paused.
    h.control(cmd="agent_pause", agent="reader", on=True)
    local, rem = pair("reader")
    same("agent paused", local.call("request_memory", {"task": "x"}), rem.call("request_memory", {"task": "x"}))
    h.control(cmd="agent_pause", agent="reader", on=False)
    h.control(cmd="pause", on=True)
    same("Funes paused", local.call("request_memory", {"task": "x"}), rem.call("request_memory", {"task": "x"}))
    h.control(cmd="pause", on=False)
    local.close()
    rem.close()

    # NEEDS_APPROVAL: approve, deny, timeout then get_memory_request.
    task = {"task": "Set up a TypeScript project", "keywords": ["package manager"]}

    def answered(client, decision):
        before = h.control(cmd="presented")["approvals"]
        thread, box = in_background(lambda: client.call("request_memory", task))
        wait_for(lambda: h.control(cmd="presented")["approvals"] == before + 1)
        h.control(cmd="answer", decision=decision)
        thread.join(10)
        return box.get("result", {})
    for decision in ["allow", "deny"]:
        local, rem = pair("asker")
        same(f"asked, {decision}", answered(local, decision), answered(rem, decision))
        local.close()
        rem.close()
    local, rem = pair("asker")
    results = []
    for client in (local, rem):
        waited = client.call("request_memory", task)
        h.control(cmd="answer", decision="allow", count=2)
        time.sleep(5.1)
        results.append((waited, client.call("get_memory_request", {"request_id": waited.get("request_id", "")})))
    same("timeout → needs_approval", results[0][0], results[1][0])
    same("then get_memory_request", results[0][1], results[1][1])
    check("timed-out remote request delivered later", results[1][1].get("status") == "delivered" and
          len(results[1][1].get("items", [])) == 2, results[1][1])
    # A pending request belongs to the agent, not the channel: the remote one can collect a local one.
    waited = local.call("request_memory", task)
    h.control(cmd="answer", decision="allow")
    time.sleep(0.2)
    collected = rem.call("get_memory_request", {"request_id": waited.get("request_id", "")})
    check("one pending list per agent", collected.get("status") == "delivered", collected)
    local.close()
    rem.close()

    # suggest_memory: queued for review, and saved directly for an agent that may write.
    for name, title in [("suggester", "Prefers dark mode"), ("writer", "Uses Zed")]:
        local, rem = pair(name)
        first = local.call("suggest_memory", {"title": title + " L", "body": "Something true.",
                                              "categories": ["personal_preferences"]})
        second = rem.call("suggest_memory", {"title": title + " R", "body": "Something true.",
                                             "categories": ["personal_preferences"]})
        same(f"{name} suggest", first, second)
        check(f"{name} suggest status", first.get("status") == ("queued" if name == "suggester" else "saved"), first)
        local.close()
        rem.close()
    rows = [r for r in h.control(cmd="activity")["activity"] if r["event"] == "suggest_memory"]
    check("suggest rows marked by channel", sorted(r["via"] for r in rows[:4]) == ["mcp", "mcp", "remote", "remote"],
          [r["via"] for r in rows[:4]])

    # Rate limits: the agent's own buckets are shared by both listeners. 30 local calls empty the
    # 30-call burst (it refills at 2 a second), so a remote call is limited within a few, long
    # before the remote bucket's 15.
    local, rem = pair("narrow")
    for _ in range(30):
        local.call("list_memory_categories")
    statuses = [rem.call("list_memory_categories").get("reason") for _ in range(4)]
    check("rate limits shared across listeners", "rate_limited" in statuses[:3], statuses)
    local.close()
    rem.close()
    # And remote calls also take the stricter remote bucket (15 in a burst), as network hygiene.
    rem = Remote(h, port, remote["none"])
    remote_only = [rem.call("list_memory_categories").get("reason") for _ in range(18)]
    first_limited = remote_only.index("rate_limited") if "rate_limited" in remote_only else None
    check("remote bucket: 15 in a burst", first_limited is not None and 12 <= first_limited <= 15, remote_only)
    rem.close()


def main():
    binary = sys.argv[1]
    h = Harness(binary, FUNES_MCP_TEST_WAIT=3)
    try:
        port = start(h)
        token = run_gate(h, port)
        run_oauth(h, port)
        run_off(h, port, token)
    finally:
        h.close()
    same = Harness(binary, FUNES_MCP_TEST_WAIT=2)
    try:
        run_same_decision(same)
    finally:
        same.close()
    if mcp_test.failures:
        print("Funes Remote Access tests failed:")
        for failure in mcp_test.failures:
            print("  " + failure)
        sys.exit(1)
    print(f"Funes Remote Access: {mcp_test.checks} checks over loopback (gate, credentials kept apart, cloud access, "
          "remote tokens, OAuth pairing, refresh, Revoke, Reset Path, off, the same decision local vs remote, "
          "shared limits) passed")


if __name__ == "__main__":
    main()
