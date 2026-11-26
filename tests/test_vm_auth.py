#!/usr/bin/env python3
"""
Unit tests for colab_vm_auth.py (fixing google-colab-cli v0.8.0's broken `colab auth` stdin_hook)
and remote_supervisor.py's HTTP 401 token auto-refresh during Drive API streaming uploads.
"""

from __future__ import annotations

import http.server
import io
import json
import os
import pathlib
import re
import socketserver
import sys
import tempfile
import threading
import urllib.parse

ROOT_DIR = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT_DIR / "lib"))

import colab_vm_auth  # noqa: E402


class FakeSession:
    def msg(self, msg_type: str, content: dict, parent=None) -> dict:
        return {
            "header": {"msg_id": "reply-1", "msg_type": msg_type},
            "parent_header": parent if isinstance(parent, dict) else {},
            "metadata": {},
            "content": content,
        }


class FakeChannel:
    def __init__(self) -> None:
        self.sent: list[dict] = []

    def msg_ready(self) -> bool:
        return False

    def send(self, msg: dict) -> None:
        self.sent.append(msg)


class FakeWSClient:
    def __init__(self) -> None:
        self.session = FakeSession()
        self.stdin_channel = FakeChannel()
        self.shell_channel = FakeChannel()


class FakeManager:
    def __init__(self, wsclient: FakeWSClient) -> None:
        self.client = wsclient


class FakeKernelClient:
    def __init__(self, wsclient: FakeWSClient, input_request_msg: dict, cancel_mode: bool = False) -> None:
        self._manager = FakeManager(wsclient)
        self.input_request_msg = input_request_msg
        self.cancel_mode = cancel_mode
        self.interrupted = False

    def interrupt(self) -> None:
        self.interrupted = True

    def execute_interactive(self, code, allow_stdin=False, timeout=None, output_hook=None, stdin_hook=None):
        assert allow_stdin is True
        assert stdin_hook is not None
        stdin_hook(self.input_request_msg)
        if self.cancel_mode:
            return {"content": {"status": "error", "ename": "KeyboardInterrupt", "evalue": ""}}
        if output_hook:
            output_hook(
                {
                    "header": {"msg_type": "stream"},
                    "content": {"name": "stdout", "text": "Authenticated successfully.\n"},
                }
            )
        return {"content": {"status": "ok"}}


class FakeRuntime:
    def __init__(self, kc: FakeKernelClient) -> None:
        self.kernel_client = kc


def test_input_request_url_and_reply() -> None:
    real_prompt = (
        "Go to the following link in your browser, and complete the sign-in prompts:\n\n"
        "    https://accounts.google.com/o/oauth2/auth?response_type=code&client_id=32555940559.apps.googleusercontent.com"
        "&scope=openid+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive\n\n"
        "Once finished, enter the verification code provided in your browser: "
    )
    req_msg = {
        "header": {"msg_id": "req-744-13", "msg_type": "input_request"},
        "content": {"prompt": real_prompt, "password": False},
    }

    prompt_txt, is_pw, url = colab_vm_auth.extract_prompt_and_url(req_msg)
    assert is_pw is False
    assert url == (
        "https://accounts.google.com/o/oauth2/auth?response_type=code"
        "&client_id=32555940559.apps.googleusercontent.com"
        "&scope=openid+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive"
    )
    assert "Go to the following link" in prompt_txt

    ws = FakeWSClient()
    kc = FakeKernelClient(ws, req_msg)
    rt = FakeRuntime(kc)

    opened_urls: list[str] = []
    ok, out_txt, errors, flags = colab_vm_auth.execute_kernel_interactive(
        rt,
        colab_vm_auth.REMOTE_AUTH_CODE,
        allow_stdin=True,
        input_reader=lambda _lbl, _pw: "  4/0A-mock-verification-code  ",
        browser_opener=lambda u: (opened_urls.append(u) or True),
    )

    assert ok is True, f"Expected ok=True, got errors={errors}"
    assert "Authenticated successfully." in out_txt
    assert opened_urls == [url]
    assert flags.get("replies_sent") == 1
    assert len(ws.stdin_channel.sent) == 1
    sent_reply = ws.stdin_channel.sent[0]
    assert sent_reply["header"]["msg_type"] == "input_reply"
    assert sent_reply["parent_header"]["msg_id"] == "req-744-13"
    assert sent_reply["content"]["value"] == "4/0A-mock-verification-code"


def test_ctrl_c_interrupts_remote_kernel() -> None:
    req_msg = {
        "header": {"msg_id": "req-cancel", "msg_type": "input_request"},
        "content": {"prompt": "Visit https://accounts.google.com/o/oauth2/auth?x=1 and paste code: ", "password": False},
    }
    ws = FakeWSClient()
    kc = FakeKernelClient(ws, req_msg, cancel_mode=True)
    rt = FakeRuntime(kc)

    def raise_ctrl_c(_lbl: str, _pw: bool) -> str:
        raise KeyboardInterrupt()

    ok, _out, _errs, flags = colab_vm_auth.execute_kernel_interactive(
        rt,
        colab_vm_auth.REMOTE_AUTH_CODE,
        allow_stdin=True,
        input_reader=raise_ctrl_c,
        browser_opener=lambda _u: False,
    )
    assert ok is False
    assert flags.get("cancelled") is True
    assert kc.interrupted is True
    assert len(ws.stdin_channel.sent) == 0


def test_supervisor_401_token_refresh_mid_upload() -> None:
    """Verify remote_supervisor.stream_hf_to_drive_api auto-refreshes token on HTTP 401 mid-upload."""
    payload = (b"REFRESH_401_CHUNK_" * 60000)[: 1024 * 1024]  # 1 MiB (2 x 512 KiB chunks)

    with tempfile.TemporaryDirectory() as tmp:
        box = pathlib.Path(tmp)
        drive_dir = box / "drive"
        (drive_dir / "maya-models").mkdir(parents=True, exist_ok=True)
        work_dir = box / "work"
        work_dir.mkdir(parents=True, exist_ok=True)

        state = {
            "active_token": "tok-v1",
            "put_count": 0,
            "forced_401": False,
            "buf": bytearray(),
            "lock": threading.Lock(),
        }

        class RefreshHandler(http.server.BaseHTTPRequestHandler):
            def log_message(self, fmt, *args):
                pass

            def _json(self, code, obj):
                raw = json.dumps(obj).encode("utf-8")
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_GET(self):
                parsed = urllib.parse.urlparse(self.path)
                if parsed.path.startswith("/org/repo/resolve/main/"):
                    rng = self.headers.get("Range")
                    if rng and rng.startswith("bytes="):
                        s_s, e_s = rng[6:].split("-", 1)
                        start = int(s_s) if s_s else 0
                        end = int(e_s) if e_s else len(payload) - 1
                        end = min(end, len(payload) - 1)
                        chunk = payload[start : end + 1]
                        self.send_response(206)
                        self.send_header("Accept-Ranges", "bytes")
                        self.send_header("Content-Range", f"bytes {start}-{end}/{len(payload)}")
                        self.send_header("Content-Length", str(len(chunk)))
                        self.end_headers()
                        self.wfile.write(chunk)
                        return
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return
                if parsed.path == "/drive/v3/files":
                    self._json(200, {"files": []})
                    return
                self.send_response(404)
                self.end_headers()

            def do_POST(self):
                parsed = urllib.parse.urlparse(self.path)
                cl = int(self.headers.get("Content-Length") or "0")
                _ = self.rfile.read(cl) if cl else b""
                if parsed.path == "/drive/v3/files":
                    self._json(200, {"id": "fld-1", "name": "maya-models"})
                    return
                if parsed.path == "/upload/drive/v3/files":
                    h, p = self.server.server_address
                    self.send_response(200)
                    self.send_header("Location", f"http://{h}:{p}/upload/sess/1")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                self.send_response(404)
                self.end_headers()

            def do_PUT(self):
                cl = int(self.headers.get("Content-Length") or "0")
                chunk = self.rfile.read(cl) if cl else b""
                cr = self.headers.get("Content-Range", "")
                auth_hdr = self.headers.get("Authorization", "")

                with state["lock"]:
                    # Simulate token expiring right on the 2nd chunk!
                    if cr.startswith("bytes */"):
                        if auth_hdr != f"Bearer {state['active_token']}":
                            self.send_response(401)
                            self.end_headers()
                            return
                        self.send_response(308)
                        if len(state["buf"]) > 0:
                            self.send_header("Range", f"bytes=0-{len(state['buf']) - 1}")
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        return

                    if state["put_count"] == 1 and not state["forced_401"]:
                        state["forced_401"] = True
                        state["active_token"] = "tok-v2"
                        self.send_response(401)
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        return

                    if auth_hdr != f"Bearer {state['active_token']}":
                        self.send_response(401)
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        return

                    m = re.match(r"bytes (\d+)-(\d+)/(\d+)", cr)
                    assert m, cr
                    start, end, total = int(m.group(1)), int(m.group(2)), int(m.group(3))
                    assert start == len(state["buf"])
                    state["buf"].extend(chunk)
                    state["put_count"] += 1
                    if len(state["buf"]) < total:
                        self.send_response(308)
                        self.send_header("Range", f"bytes=0-{end}")
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        return
                    out_p = drive_dir / "maya-models" / "refreshed.gguf"
                    out_p.write_bytes(bytes(state["buf"]))
                self._json(200, {"id": "f-1", "name": "refreshed.gguf", "size": str(len(payload))})

        class Srv(socketserver.ThreadingMixIn, http.server.HTTPServer):
            daemon_threads = True

        srv = Srv(("127.0.0.1", 0), RefreshHandler)
        port = srv.server_address[1]
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            old_env = dict(os.environ)
            os.environ["MAYA_WORK_ROOT"] = str(work_dir)
            os.environ["MAYA_DRIVE_MOUNT_ROOT"] = str(drive_dir)
            os.environ["COLABD_HF_BASE_URL"] = f"http://127.0.0.1:{port}"
            os.environ["COLABD_DRIVE_API_BASE"] = f"http://127.0.0.1:{port}/drive/v3"
            os.environ["COLABD_DRIVE_UPLOAD_BASE"] = f"http://127.0.0.1:{port}/upload/drive/v3"
            os.environ["COLABD_DRIVE_CHUNK_BYTES"] = str(512 * 1024)
            os.environ["COLABD_DISABLE_GCLOUD_TOKEN_FALLBACK"] = "1"
            os.environ.pop("COLABD_DRIVE_ACCESS_TOKEN", None)

            ns: dict = {"__name__": "test_refresh_401"}
            sup_src = (ROOT_DIR / "lib" / "remote_supervisor.py").read_text(encoding="utf-8")
            exec(compile(sup_src, "remote_supervisor.py", "exec"), ns)

            refreshes = {"n": 0}

            def fake_get_token(force_refresh: bool = False):
                if force_refresh:
                    refreshes["n"] += 1
                    return "tok-v2"
                return "tok-v1"

            ns["_get_drive_api_token"] = fake_get_token
            dst = drive_dir / "maya-models" / "refreshed.gguf"
            res = ns["stream_hf_to_drive_api"]("org/repo", "refreshed.gguf", dst, token="tok-v1")
            assert res == dst
            assert refreshes["n"] == 1, f"Expected exactly 1 token refresh on 401, got {refreshes['n']}"
            assert dst.read_bytes() == payload
        finally:
            os.environ.clear()
            os.environ.update(old_env)
            srv.shutdown()
            srv.server_close()


if __name__ == "__main__":
    test_input_request_url_and_reply()
    test_ctrl_c_interrupts_remote_kernel()
    test_supervisor_401_token_refresh_mid_upload()
    print("VM_AUTH_AND_401_REFRESH_TESTS_OK")
