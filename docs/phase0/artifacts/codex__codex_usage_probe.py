#!/usr/bin/env python3
"""
codex_usage_probe.py - TokenBar Phase 0 probe (Codex side).

Spawns `codex app-server` (JSON-RPC over stdio, one JSON object per line),
performs the initialize -> initialized handshake, calls `account/read` and
`account/rateLimits/read`, prints the results (redacted) with latency, and then
shuts the server down cleanly.

The app-server authenticates with Codex's own stored credentials
($CODEX_HOME/auth.json, or the keyring if configured). This script never reads,
copies or logs any credential, and makes no HTTP request itself.

Usage:
  python3 codex_usage_probe.py [--codex /path/to/codex] [--codex-home DIR]
                               [--timeout 20] [-c key=value ...]
Env:
  TOKENBAR_CODEX_BIN  overrides binary discovery (same as --codex)
  CODEX_HOME          selects the Codex profile (same as --codex-home)
"""
import argparse
import glob
import json
import os
import queue
import re
import resource
import shutil
import subprocess
import sys
import threading
import time

CLIENT_INFO = {"name": "tokenbar_probe", "title": "TokenBar Probe", "version": "0.0.1"}

# --------------------------------------------------------------------------- #
# Binary discovery
# --------------------------------------------------------------------------- #
EDITOR_EXT_ROOTS = [
    "~/.vscode/extensions",
    "~/.vscode-insiders/extensions",
    "~/.cursor/extensions",
    "~/.windsurf/extensions",
    "~/.vscode-oss/extensions",
]
STANDALONE = [
    "~/.local/bin/codex",
    "/opt/homebrew/bin/codex",
    "/usr/local/bin/codex",
    "~/.bun/bin/codex",
    "~/.npm-global/bin/codex",
    "~/.nvm/versions/node/*/bin/codex",
    "/Applications/Codex.app/Contents/Resources/codex",
    "~/Applications/Codex.app/Contents/Resources/codex",
]


def _ver_tuple(s):
    return tuple(int(x) for x in re.findall(r"\d+", s or "")[:4]) or (0,)


def _is_exec(p):
    return os.path.isfile(p) and os.access(p, os.X_OK)


def _editor_candidates():
    """Yield (sort_key, path, source) for codex binaries bundled in editor extensions.

    Prefers the version VS Code records as installed (extensions.json) and skips
    directories listed in `.obsolete` (VS Code deletes those lazily)."""
    out = []
    for root in EDITOR_EXT_ROOTS:
        root = os.path.expanduser(root)
        if not os.path.isdir(root):
            continue
        obsolete, active = set(), set()
        try:
            with open(os.path.join(root, ".obsolete")) as fh:
                obsolete = set(json.load(fh).keys())
        except Exception:
            pass
        try:
            with open(os.path.join(root, "extensions.json")) as fh:
                for e in json.load(fh):
                    if e.get("identifier", {}).get("id", "").lower() == "openai.chatgpt":
                        loc = e.get("location", {}).get("path") or os.path.join(root, e.get("relativeLocation", ""))
                        active.add(os.path.realpath(loc))
        except Exception:
            pass
        for ext_dir in glob.glob(os.path.join(root, "openai.chatgpt-*")):
            if os.path.basename(ext_dir) in obsolete:
                continue
            for b in glob.glob(os.path.join(ext_dir, "bin", "*", "codex")):
                if not _is_exec(b):
                    continue
                cli_ver = ""
                try:
                    with open(os.path.join(os.path.dirname(b), "codex-package.json")) as fh:
                        cli_ver = json.load(fh).get("version", "")
                except Exception:
                    pass
                ext_ver = os.path.basename(ext_dir).split("-")[1] if "-" in os.path.basename(ext_dir) else ""
                is_active = os.path.realpath(ext_dir) in active
                out.append(((is_active, _ver_tuple(cli_ver), _ver_tuple(ext_ver)), b,
                            f"editor-ext {os.path.basename(ext_dir)} cli={cli_ver} active={is_active}"))
    return out


def locate_codex(override=None):
    """Return (path, source) of the codex binary to use, or raise."""
    override = override or os.environ.get("TOKENBAR_CODEX_BIN")
    if override:
        p = os.path.expanduser(override)
        if _is_exec(p):
            return p, "override"
        raise FileNotFoundError(f"override codex binary not executable: {p}")
    on_path = shutil.which("codex")
    if on_path:
        return on_path, "PATH"
    for pat in STANDALONE:
        for p in sorted(glob.glob(os.path.expanduser(pat)), key=_ver_tuple, reverse=True):
            if _is_exec(p):
                return p, f"standalone {pat}"
    cands = sorted(_editor_candidates(), key=lambda c: c[0], reverse=True)
    if cands:
        return cands[0][1], cands[0][2]
    raise FileNotFoundError("no codex binary found (install Codex CLI or the ChatGPT/Codex editor extension)")


# --------------------------------------------------------------------------- #
# Redaction (results contain no credentials, but be defensive)
# --------------------------------------------------------------------------- #
SECRET_KEY = re.compile(r"(token|secret|password|passwd|api[_-]?key|authorization|cookie|private)", re.I)
ID_KEY = re.compile(r"(account|user)_?id$", re.I)
SECRET_VAL = [
    re.compile(r"^eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]+"),  # JWT
    re.compile(r"^(sk|rk|pk)-[A-Za-z0-9_\-]{8,}"),           # API keys
    re.compile(r"^[A-Za-z0-9+/_\-]{48,}={0,2}$"),            # long opaque blobs
]


def redact(obj, key=""):
    if isinstance(obj, dict):
        return {k: redact(v, k) for k, v in obj.items()}
    if isinstance(obj, list):
        return [redact(v, key) for v in obj]
    if isinstance(obj, str):
        if SECRET_KEY.search(key) and obj:
            return "<redacted>"
        if any(r.search(obj) for r in SECRET_VAL):
            return "<redacted>"
        if key.lower() == "email" and "@" in obj:
            local, dom = obj.split("@", 1)
            return f"{local[:1]}***@{dom}"
        if ID_KEY.search(key) and len(obj) > 8:  # accountId, chatgptAccountId, user_id, ...
            return obj[:8] + "...(masked)"
    return obj


# --------------------------------------------------------------------------- #
# JSON-RPC client over the child's stdio
# --------------------------------------------------------------------------- #
class AppServer:
    def __init__(self, binary, codex_home=None, config_overrides=()):
        env = dict(os.environ)
        env.setdefault("RUST_LOG", "error")
        if codex_home:
            env["CODEX_HOME"] = os.path.expanduser(codex_home)
        # Per-process overrides only (never written to config.toml): keep the probe
        # from doing any memory work; no thread is started, so no model call happens.
        args = [binary,
                "-c", "memories.generate_memories=false",
                "-c", "memories.use_memories=false"]
        for kv in config_overrides:
            args += ["-c", kv]
        args += ["app-server", "--listen", "stdio://"]
        self.t_spawn = time.monotonic()
        self.proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, env=env, bufsize=0)
        self.inbox = queue.Queue()
        self.notifications = []
        self.stderr_tail = []
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()
        self.next_id = 0

    def _read_stdout(self):
        for raw in iter(self.proc.stdout.readline, b""):
            line = raw.decode("utf-8", "replace").strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if "method" in msg and "id" in msg:            # server -> client request
                self._send({"id": msg["id"], "error": {"code": -32601, "message": "not supported by TokenBar"}})
                self.notifications.append({"method": msg["method"], "kind": "server-request(declined)"})
            elif "method" in msg:                           # notification
                self.notifications.append({"method": msg["method"],
                                           "params": msg.get("params") if msg["method"].startswith("account/") else None,
                                           "t_ms": round((time.monotonic() - self.t_spawn) * 1000)})
            else:                                           # response / error
                self.inbox.put((time.monotonic(), msg))
        self.inbox.put((time.monotonic(), None))

    def _read_stderr(self):
        for raw in iter(self.proc.stderr.readline, b""):
            self.stderr_tail = (self.stderr_tail + [raw.decode("utf-8", "replace").rstrip()])[-5:]

    def _send(self, msg):
        self.proc.stdin.write((json.dumps(msg, separators=(",", ":")) + "\n").encode())
        self.proc.stdin.flush()

    def notify(self, method, params=None):
        msg = {"method": method}
        if params is not None:
            msg["params"] = params
        self._send(msg)

    def request(self, method, params=None):
        rid = self.next_id
        self.next_id += 1
        msg = {"method": method, "id": rid}
        if params is not None:
            msg["params"] = params
        self._send(msg)
        return rid, time.monotonic()

    def wait_for(self, ids, timeout):
        """Collect responses for the given ids; returns {id: (t_recv, msg)}."""
        got, deadline = {}, time.monotonic() + timeout
        pending = set(ids)
        while pending:
            left = deadline - time.monotonic()
            if left <= 0:
                break
            try:
                t, msg = self.inbox.get(timeout=left)
            except queue.Empty:
                break
            if msg is None:
                break  # stdout closed: server exited
            if msg.get("id") in pending:
                got[msg["id"]] = (t, msg)
                pending.discard(msg["id"])
        return got

    def shutdown(self):
        """Close stdin (server exits on EOF); escalate to SIGTERM / SIGKILL if needed."""
        how = "eof"
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            how = "sigterm"
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                how = "sigkill"
                self.proc.kill()
                self.proc.wait()
        return how, self.proc.returncode


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--codex")
    ap.add_argument("--codex-home")
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("-c", "--config", action="append", default=[], help="extra codex -c key=value (per process)")
    a = ap.parse_args()

    binary, source = locate_codex(a.codex)
    version = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=10).stdout.strip()
    srv = AppServer(binary, a.codex_home, a.config)
    report = {"binary": binary, "binarySource": source, "binaryVersion": version}
    try:
        # 1) initialize (request) -> 2) initialized (notification)
        rid, t0 = srv.request("initialize", {
            "clientInfo": CLIENT_INFO,
            "capabilities": {"experimentalApi": False, "requestAttestation": False},
        })
        init = srv.wait_for([rid], a.timeout).get(rid)
        if not init or "error" in init[1]:
            raise RuntimeError(f"initialize failed: {init and init[1]} stderr={srv.stderr_tail}")
        report["initialize"] = init[1]["result"]
        report["latency_ms"] = {"spawn_to_initialize": round((init[0] - srv.t_spawn) * 1000)}
        srv.notify("initialized")

        # 3) account/read and account/rateLimits/read (pipelined)
        acc_id, t_acc = srv.request("account/read", {"refreshToken": False})
        rl_id, t_rl = srv.request("account/rateLimits/read", {"excludeResetCreditDetails": True})
        got = srv.wait_for([acc_id, rl_id], a.timeout)
        for name, rid_, t_sent in (("account/read", acc_id, t_acc), ("account/rateLimits/read", rl_id, t_rl)):
            if rid_ not in got:
                report[name] = {"error": "timeout"}
                continue
            t_recv, msg = got[rid_]
            report["latency_ms"][name] = round((t_recv - t_sent) * 1000)
            report[name] = redact(msg.get("result")) if "result" in msg else {"error": redact(msg.get("error"))}
        report["latency_ms"]["spawn_to_all_results"] = round((time.monotonic() - srv.t_spawn) * 1000)
    finally:
        how, rc = srv.shutdown()
        report["shutdown"] = {"method": how, "exitCode": rc,
                              "total_ms": round((time.monotonic() - srv.t_spawn) * 1000)}
        # ru_maxrss is bytes on macOS, KiB on Linux
        ru = resource.getrusage(resource.RUSAGE_CHILDREN)  # includes the `--version` child
        report["child_peak_rss_mb"] = round(ru.ru_maxrss / (1024 * 1024 if sys.platform == "darwin" else 1024), 1)
        report["child_cpu_s"] = round(ru.ru_utime + ru.ru_stime, 3)
        report["notifications"] = [n for n in srv.notifications]
        if srv.stderr_tail:
            report["stderr_tail"] = [redact(s) for s in srv.stderr_tail]

    # Derived, human-readable summary of the codex bucket
    rl = (report.get("account/rateLimits/read") or {}).get("rateLimits") or {}
    now = time.time()
    summary = {}
    for k in ("primary", "secondary"):
        w = rl.get(k)
        if w:
            summary[k] = {"usedPercent": w.get("usedPercent"),
                          "windowMins": w.get("windowDurationMins"),
                          "resetsAt": w.get("resetsAt"),
                          "resetsAtLocal": time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(w["resetsAt"])) if w.get("resetsAt") else None,
                          "resetsInMin": round((w["resetsAt"] - now) / 60, 1) if w.get("resetsAt") else None}
    report["summary"] = {"planType": rl.get("planType"), **summary}
    print(json.dumps(report, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
