"""Model providers for Spike G, as Spike E ran them (spikes/memory-processing/providers.py): Claude through
`claude -p` and OpenAI through `codex exec`, both on the author's subscriptions, and Apple on-device through Spike E's
fm-runner. Each returns {ok, content, errorKind, error, promptTokens, outputTokens, ms}."""
import copy
import hashlib
import json
import subprocess
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
FM_RUNNER = HERE.parent / "memory-processing" / "swift" / ".build" / "release" / "fm-runner"


def for_provider(schema, provider):
    """OpenAI strict mode and Claude take the schema as is; Apple's guided generation drops
    additionalProperties and required."""
    s = copy.deepcopy(schema)

    def walk(n):
        if isinstance(n, dict):
            if provider == "apple":
                n.pop("additionalProperties", None)
                n.pop("required", None)
            for v in n.values():
                walk(v)
        elif isinstance(n, list):
            for v in n:
                walk(v)
    walk(s)
    return s


class Codex:
    """`codex exec` with the task instructions as model_instructions_file and the tools that aren't needed off."""
    kind = "cloud"

    def __init__(self, model, effort="low"):
        self.model, self.effort = model, effort
        self.label = f"OpenAI {model} ({effort} reasoning, via Codex)"
        self.dir = Path(tempfile.mkdtemp(prefix="spike-g-codex-"))

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
                out["outputTokens"] = u.get("output_tokens") or 0
                out["reasoningTokens"] = u.get("reasoning_output_tokens")
            if ev.get("type") in ("error", "turn.failed"):
                out["error"] = json.dumps(ev)[:300]
        try:
            out["content"] = json.loads(out_file.read_text())
            out["ok"] = True
            out_file.unlink()
        except (FileNotFoundError, json.JSONDecodeError) as e:
            out.update(ok=False, errorKind="codex" if out.get("error") else "json",
                       error=out.get("error") or (p.stderr[-300:] if p.stderr else str(e)))
        return out


class ClaudeCLI:
    """`claude -p`: the instructions as the system prompt, no tools, --json-schema, from an empty directory."""
    kind = "cloud"

    def __init__(self, model, effort="low"):
        self.model, self.effort = model, effort
        self.label = f"Anthropic {model} ({effort} effort, via Claude Code)"
        self.dir = Path(tempfile.mkdtemp(prefix="spike-g-claude-"))

    def generate(self, instructions, prompt, schema):
        cmd = ["claude", "-p", "--model", self.model, "--effort", self.effort, "--system-prompt", instructions,
               "--tools", "", "--strict-mcp-config", "--no-session-persistence",
               "--json-schema", json.dumps(for_provider(schema, "claude")), "--output-format", "json"]
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
        out["modelId"] = usage.get("canonicalModel")
        if d.get("is_error") or not isinstance(d.get("structured_output"), dict):
            return {**out, "ok": False, "errorKind": "refusal" if d.get("stop_reason") == "refusal" else "cli",
                    "error": str(d.get("result"))[:300]}
        return {**out, "ok": True, "content": d["structured_output"]}


class Apple:
    kind = "apple"
    label = "Apple on-device (Foundation Models)"

    def __init__(self):
        self.proc = subprocess.Popen([str(FM_RUNNER)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        json.loads(self.proc.stdout.readline())
        self.n = 0

    def generate(self, instructions, prompt, schema):
        self.n += 1
        req = {"id": str(self.n), "instructions": instructions, "prompt": prompt, "schema": for_provider(schema, "apple")}
        self.proc.stdin.write(json.dumps(req) + "\n")
        self.proc.stdin.flush()
        r = json.loads(self.proc.stdout.readline())
        out = {"ok": r.get("ok", False), "errorKind": r.get("errorKind"), "error": r.get("error"), "ms": r.get("ms"),
               "promptTokens": (r.get("instructionTokens") or 0) + (r.get("promptTokens") or 0), "outputTokens": r.get("outputTokens")}
        if out["ok"]:
            try:
                out["content"] = json.loads(r["content"])
            except (json.JSONDecodeError, TypeError):
                out.update(ok=False, errorKind="json", error=str(r.get("content"))[:300])
        return out


PROVIDERS = {
    "claude-haiku": lambda: ClaudeCLI("haiku"),
    "codex-terra": lambda: Codex("gpt-5.6-terra"),
    "codex-luna": lambda: Codex("gpt-6-luna"),
    "apple": Apple,
}
