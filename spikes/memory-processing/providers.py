"""Model providers for Spike E: Apple on-device (swift fm-runner), Ollama (HTTP), and OpenAI through the Codex CLI.

Every provider returns {ok, content (parsed JSON), errorKind, error, promptTokens, outputTokens, ms}.
"""
import hashlib
import json
import subprocess
import tempfile
import threading
import time
import urllib.request
from pathlib import Path

from prompts import for_provider

HERE = Path(__file__).resolve().parent


class Apple:
    name = "apple"
    label = "Apple on-device (Foundation Models)"

    def __init__(self, guardrails="default"):
        self.guardrails = guardrails
        self.proc = subprocess.Popen([str(HERE / "swift/.build/release/fm-runner")], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, text=True, bufsize=1)
        ready = json.loads(self.proc.stdout.readline())
        self.context_size = ready.get("contextSize")
        self.lock = threading.Lock()
        self.n = 0

    def generate(self, instructions, prompt, schema):
        with self.lock:
            self.n += 1
            req = {"id": str(self.n), "instructions": instructions, "prompt": prompt,
                   "schema": for_provider(schema, "apple"), "guardrails": self.guardrails}
            self.proc.stdin.write(json.dumps(req) + "\n")
            self.proc.stdin.flush()
            r = json.loads(self.proc.stdout.readline())
        out = {"ok": r.get("ok", False), "errorKind": r.get("errorKind"), "error": r.get("error"), "ms": r.get("ms"),
               "promptTokens": (r.get("instructionTokens") or 0) + (r.get("promptTokens") or 0) + (r.get("schemaTokens") or 0),
               "outputTokens": r.get("outputTokens"), "schemaTokens": r.get("schemaTokens")}
        if out["ok"]:
            try:
                out["content"] = json.loads(r["content"])
            except (json.JSONDecodeError, TypeError):
                out.update(ok=False, errorKind="json", error=str(r.get("content"))[:300])
        return out


class Ollama:
    name = "ollama"

    def __init__(self, model="qwen3:4b-instruct-2507-q4_K_M", num_ctx=4096):
        self.model = model
        self.num_ctx = num_ctx
        self.label = f"Ollama {model}"

    def generate(self, instructions, prompt, schema):
        body = {"model": self.model, "stream": False, "format": for_provider(schema, "ollama"), "keep_alive": "30m",
                "options": {"temperature": 0, "num_ctx": self.num_ctx},
                "messages": [{"role": "system", "content": instructions}, {"role": "user", "content": prompt}]}
        start = time.time()
        try:
            req = urllib.request.Request("http://127.0.0.1:11434/api/chat", data=json.dumps(body).encode(),
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=1800) as resp:
                r = json.loads(resp.read())
        except Exception as e:  # noqa: BLE001 - recorded as a failure
            return {"ok": False, "errorKind": "http", "error": str(e)[:300], "ms": int((time.time() - start) * 1000)}
        out = {"ok": True, "ms": int((time.time() - start) * 1000), "promptTokens": r.get("prompt_eval_count"),
               "outputTokens": r.get("eval_count")}
        if out["promptTokens"] and out["promptTokens"] >= self.num_ctx - 1:
            out["truncated"] = True
        try:
            out["content"] = json.loads(r["message"]["content"])
        except (json.JSONDecodeError, KeyError, TypeError):
            out.update(ok=False, errorKind="json", error=str(r.get("message"))[:300])
        return out


class Codex:
    """OpenAI's GPT-6-Luna through `codex exec` on the user's subscription. The task instructions replace Codex's
    base instructions (model_instructions_file); tools that aren't needed are disabled. Codex still adds its tool
    definitions, so promptTokens includes a fixed overhead, measured once and reported separately."""
    name = "codex"

    def __init__(self, model="gpt-6-luna", effort="low"):
        self.model, self.effort = model, effort
        self.label = f"OpenAI {model} ({effort} reasoning, via Codex CLI)"
        self.dir = Path(tempfile.mkdtemp(prefix="spike-e-codex-"))

    def _file(self, name, text):
        p = self.dir / f"{name}-{hashlib.sha256(text.encode()).hexdigest()[:16]}"
        if not p.exists():
            p.write_text(text)
        return p

    def generate(self, instructions, prompt, schema):
        ins = self._file("ins", instructions)
        sch = self._file("schema", json.dumps(for_provider(schema, "codex")))
        out_file = self.dir / f"out-{threading.get_ident()}-{time.time_ns()}.json"
        cmd = ["codex", "exec", "--ignore-user-config", "-m", self.model, "-c", f"model_reasoning_effort={self.effort}",
               "-c", f"model_instructions_file=\"{ins}\"", "-c", "web_search=disabled",
               "--disable", "apps", "--disable", "browser_use", "--disable", "browser_use_external",
               "--disable", "computer_use", "--disable", "goals", "--disable", "code_mode_host",
               "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral", "--output-schema", str(sch),
               "-o", str(out_file), "--json", "-C", str(self.dir), "-"]
        start = time.time()
        try:
            p = subprocess.run(cmd, input=prompt, capture_output=True, text=True, timeout=300)
        except subprocess.TimeoutExpired:
            return {"ok": False, "errorKind": "timeout", "error": "300 s", "ms": 300000}
        out = {"ms": int((time.time() - start) * 1000)}
        for line in p.stdout.splitlines():
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if ev.get("type") == "turn.completed":
                u = ev.get("usage") or {}
                out["promptTokens"] = u.get("input_tokens")
                out["outputTokens"] = (u.get("output_tokens") or 0)
                out["reasoningTokens"] = u.get("reasoning_output_tokens")
            if ev.get("type") in ("error", "turn.failed"):
                out["error"] = json.dumps(ev)[:300]
        try:
            out["content"] = json.loads(out_file.read_text())
            out["ok"] = True
            out_file.unlink()
        except (FileNotFoundError, json.JSONDecodeError) as e:
            out.update(ok=False, errorKind=out.get("error") and "codex" or "json",
                       error=out.get("error") or (p.stderr[-300:] if p.stderr else str(e)))
        return out


class ClaudeCLI:
    """Anthropic models through `claude -p` on the user's Claude subscription: the task instructions as the system
    prompt, no tools, structured output with --json-schema, run from an empty directory (no CLAUDE.md)."""
    name = "claude"

    def __init__(self, model="haiku", effort="low"):
        self.model, self.effort = model, effort
        self.label = f"Anthropic {model} ({effort} effort, via the Claude CLI)"
        self.dir = Path(tempfile.mkdtemp(prefix="spike-e-claude-"))

    def generate(self, instructions, prompt, schema):
        cmd = ["claude", "-p", "--model", self.model, "--effort", self.effort, "--system-prompt", instructions,
               "--tools", "", "--strict-mcp-config", "--no-session-persistence",
               "--json-schema", json.dumps(for_provider(schema, "codex")), "--output-format", "json"]
        start = time.time()
        try:
            p = subprocess.run(cmd, input=prompt, capture_output=True, text=True, timeout=300, cwd=self.dir)
        except subprocess.TimeoutExpired:
            return {"ok": False, "errorKind": "timeout", "error": "300 s", "ms": 300000}
        out = {"ms": int((time.time() - start) * 1000)}
        try:
            d = json.loads(p.stdout)
        except json.JSONDecodeError:
            return {**out, "ok": False, "errorKind": "cli", "error": (p.stderr or p.stdout)[-300:]}
        usage = next(iter((d.get("modelUsage") or {}).values()), {})
        out["promptTokens"] = sum(usage.get(k) or 0 for k in ("inputTokens", "cacheReadInputTokens", "cacheCreationInputTokens"))
        out["outputTokens"] = usage.get("outputTokens")
        out["reasoningTokens"] = usage.get("thinkingTokens")
        out["costUSD"] = d.get("total_cost_usd")
        out["modelId"] = usage.get("canonicalModel")
        if d.get("is_error") or not isinstance(d.get("structured_output"), dict):
            return {**out, "ok": False, "errorKind": "refusal" if d.get("stop_reason") == "refusal" else "cli",
                    "error": str(d.get("result"))[:300]}
        return {**out, "ok": True, "content": d["structured_output"]}


def make(name, **kw):
    return {"apple": Apple, "ollama": Ollama, "codex": Codex, "claude": ClaudeCLI}[name](**kw)
