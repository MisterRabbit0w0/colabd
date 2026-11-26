#!/usr/bin/env python3
"""
colabd remote VM Google / Drive OAuth helper.

Works around an upstream bug in google-colab-cli v0.8.0 (`colab_cli/runtime.py`),
where `wrapped_stdin_hook` passes the raw Jupyter `input_request` dict to `input()`
and never sends an `input_reply` back on the WebSocket stdin channel, causing
`colab auth` (`google.colab.auth.authenticate_user()`) to dump a Python dict and hang.

This module uses `colab_cli`'s own `State` & `ColabRuntime` session management
with a proper Jupyter Messaging Protocol `stdin_hook` that:
  1. Extracts `msg["content"]["prompt"]` cleanly and highlights the OAuth URL.
  2. Reads the user's verification code from `/dev/tty` (falling back to stdin).
  3. Sends a proper `input_reply` message (with `parent_header`) back to the kernel.
  4. Interrupts the remote kernel cleanly on Ctrl+C so it is never left hung on stdin.
  5. Pre-checks and post-verifies Drive-scoped ADC credentials on the remote VM.
"""

from __future__ import annotations

import argparse
import getpass
import os
import re
import sys
from typing import Any, Callable, Dict, List, Optional, Tuple


DEFAULT_TIMEOUT_SEC = 600.0
OAUTH_URL_RE = re.compile(r"https://[^\s'\"<>]+")

REMOTE_CHECK_CODE = r"""
import os
import shutil
import subprocess
from pathlib import Path

def _colabd_check_vm_drive_auth():
    scopes = ["https://www.googleapis.com/auth/drive"]
    try:
        import google.auth
        from google.auth.transport.requests import Request
        creds, _ = google.auth.default(scopes=scopes)
        if not creds.valid or not creds.token:
            creds.refresh(Request())
        if creds.token:
            print("COLABD_VM_DRIVE_AUTH_OK")
            return
    except Exception:
        pass
    try:
        from google.oauth2.credentials import Credentials
        from google.auth.transport.requests import Request
        for cand in (
            Path("/content/.config/application_default_credentials.json"),
            Path.home() / ".config/gcloud/application_default_credentials.json",
        ):
            if cand.is_file():
                creds = Credentials.from_authorized_user_file(str(cand), scopes=scopes)
                if not creds.valid or not creds.token:
                    creds.refresh(Request())
                if creds.token:
                    print("COLABD_VM_DRIVE_AUTH_OK")
                    return
    except Exception:
        pass
    try:
        if shutil.which("gcloud"):
            tok = subprocess.check_output(
                ["gcloud", "auth", "print-access-token"],
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=15,
            ).strip()
            if tok:
                print("COLABD_VM_DRIVE_AUTH_OK")
                return
    except Exception:
        pass
    print("COLABD_VM_DRIVE_AUTH_MISSING")

_colabd_check_vm_drive_auth()
"""

REMOTE_AUTH_CODE = (
    "import os\n"
    "os.environ['USE_AUTH_EPHEM'] = '0'\n"
    "from google.colab import auth\n"
    "auth.authenticate_user()\n"
)


def extract_prompt_and_url(msg: Dict[str, Any]) -> Tuple[str, bool, Optional[str]]:
    """Extract clean prompt text, password flag, and first HTTPS URL from a Jupyter input_request."""
    content = msg.get("content") if isinstance(msg, dict) else None
    if not isinstance(content, dict):
        prompt_text = str(msg or "")
        is_password = False
    else:
        prompt_text = str(content.get("prompt") or "")
        is_password = bool(content.get("password", False))

    match = OAUTH_URL_RE.search(prompt_text)
    url = match.group(0).rstrip(".,);") if match else None
    return prompt_text, is_password, url


def _read_user_line(prompt_label: str, is_password: bool = False) -> str:
    """Read a line from the interactive terminal (/dev/tty), falling back to sys.stdin."""
    if is_password and sys.stdin.isatty():
        return getpass.getpass(prompt_label)

    sys.stdout.write(prompt_label)
    sys.stdout.flush()
    if os.environ.get("COLABD_VM_AUTH_USE_STDIN") != "1":
        try:
            with open("/dev/tty", "r", encoding="utf-8", errors="replace") as tty:
                line = tty.readline()
                if line == "":
                    raise EOFError("EOF on /dev/tty")
                return line.rstrip("\r\n")
        except (FileNotFoundError, OSError):
            pass

    line = sys.stdin.readline()
    if line == "":
        raise EOFError("EOF on stdin")
    return line.rstrip("\r\n")


def _try_open_browser(url: str) -> bool:
    if os.environ.get("COLABD_NO_OPEN_BROWSER") == "1":
        return False
    if os.environ.get("BROWSER") == "/usr/bin/false":
        return False
    try:
        from colab_cli.utils import open_url_in_browser  # type: ignore

        return bool(open_url_in_browser(url))
    except Exception:
        return False


def make_stdin_hook(
    wsclient: Any,
    kernel_client: Any = None,
    input_reader: Optional[Callable[[str, bool], str]] = None,
    browser_opener: Optional[Callable[[str], bool]] = None,
    state_flags: Optional[Dict[str, Any]] = None,
) -> Callable[[Dict[str, Any]], None]:
    """Create a Jupyter-protocol-compliant stdin_hook that sends `input_reply` back to the kernel."""
    reader = input_reader or _read_user_line
    opener = browser_opener or _try_open_browser
    flags = state_flags if state_flags is not None else {}

    def on_stdin_request(msg: Dict[str, Any]) -> None:
        prompt_text, is_password, url = extract_prompt_and_url(msg)
        flags["stdin_requests"] = int(flags.get("stdin_requests", 0)) + 1

        sys.stdout.write("\n")
        if url:
            sys.stdout.write("========================================================================\n")
            sys.stdout.write("[Google / Drive 远端授权] 请在浏览器打开下方链接并完成登录同意：\n\n")
            sys.stdout.write(f"  {url}\n\n")
            if opener(url):
                sys.stdout.write("(已尝试在默认浏览器打开上述链接；若未弹出请手动复制打开)\n")
            sys.stdout.write("完成同意后，请复制网页显示的验证码并粘贴到下方：\n")
            sys.stdout.write("========================================================================\n")
            input_label = "请输入浏览器验证码 (Ctrl+C 取消): "
        else:
            cleaned = prompt_text.strip()
            input_label = (cleaned + " ") if cleaned else "请输入远端内核请求的值: "
        sys.stdout.flush()

        try:
            raw_val = reader(input_label, is_password)
        except KeyboardInterrupt:
            flags["cancelled"] = True
            sys.stdout.write("\n[已取消] 正在中断远端内核的授权等待...\n")
            sys.stdout.flush()
            if kernel_client is not None:
                try:
                    kernel_client.interrupt()
                except Exception:
                    pass
            return
        except EOFError:
            flags["eof"] = True
            raw_val = ""

        value = raw_val.strip() if url else raw_val

        # Only send reply if kernel hasn't already finished or queued another stdin request
        stdin_ready = getattr(wsclient, "stdin_channel", None)
        shell_ready = getattr(wsclient, "shell_channel", None)
        if stdin_ready is not None and shell_ready is not None:
            if stdin_ready.msg_ready() or shell_ready.msg_ready():
                return

        parent_header = msg.get("header") if isinstance(msg, dict) else None
        reply = wsclient.session.msg("input_reply", {"value": value}, parent=parent_header)
        wsclient.stdin_channel.send(reply)
        flags["replies_sent"] = int(flags.get("replies_sent", 0)) + 1
        if url:
            sys.stdout.write("[已提交] 验证码已回传远端 Colab 内核，正在完成令牌交换...\n")
            sys.stdout.flush()

    return on_stdin_request


def execute_kernel_interactive(
    runtime: Any,
    code: str,
    allow_stdin: bool = True,
    timeout: float = DEFAULT_TIMEOUT_SEC,
    quiet_stdout: bool = False,
    input_reader: Optional[Callable[[str, bool], str]] = None,
    browser_opener: Optional[Callable[[str], bool]] = None,
) -> Tuple[bool, str, List[str], Dict[str, Any]]:
    """Run code via `kernel_client.execute_interactive` with proper stdin_hook & live output."""
    kc = runtime.kernel_client
    wsclient = kc._manager.client

    stdout_chunks: List[str] = []
    errors: List[str] = []
    flags: Dict[str, Any] = {}

    def on_output(msg: Dict[str, Any]) -> None:
        mtype = (msg.get("header") or {}).get("msg_type") or msg.get("msg_type")
        content = msg.get("content") or {}
        if mtype == "stream":
            name = content.get("name", "stdout")
            text = str(content.get("text") or "")
            if name == "stdout":
                stdout_chunks.append(text)
                if not quiet_stdout:
                    sys.stdout.write(text)
                    sys.stdout.flush()
            else:
                if not quiet_stdout:
                    sys.stderr.write(text)
                    sys.stderr.flush()
        elif mtype == "error":
            ename = content.get("ename", "Error")
            evalue = content.get("evalue", "")
            tb = content.get("traceback") or []
            err_txt = "".join(tb) if tb else f"{ename}: {evalue}"
            errors.append(err_txt)
            if not quiet_stdout:
                sys.stderr.write(err_txt + "\n")
                sys.stderr.flush()

    stdin_hook = (
        make_stdin_hook(
            wsclient,
            kernel_client=kc,
            input_reader=input_reader,
            browser_opener=browser_opener,
            state_flags=flags,
        )
        if allow_stdin
        else None
    )

    reply = kc.execute_interactive(
        code,
        allow_stdin=allow_stdin,
        timeout=timeout,
        output_hook=on_output,
        stdin_hook=stdin_hook,
    )
    reply_content = (reply or {}).get("content") or {}
    status = reply_content.get("status", "ok")
    if status == "error" and not errors:
        ename = reply_content.get("ename", "Error")
        evalue = reply_content.get("evalue", "Unknown error")
        errors.append(f"{ename}: {evalue}")

    ok = (status == "ok") and not errors and not flags.get("cancelled")
    return ok, "".join(stdout_chunks), errors, flags


def _open_runtime(config_path: Optional[str], auth_mode: str, session_name: Optional[str]) -> Tuple[Any, str]:
    from colab_cli.auth import AuthProvider  # type: ignore
    from colab_cli.common import state  # type: ignore
    from colab_cli.runtime import ColabRuntime  # type: ignore

    state.config_path = config_path or None
    state.auth_provider = AuthProvider.ADC if auth_mode == "adc" else AuthProvider.OAUTH2
    resolved_name = state.resolve_session(session_name)
    sess = state.get_session(resolved_name)
    runtime = ColabRuntime(sess.url, sess.token, session_name=sess.name, history=state.history)
    return runtime, resolved_name


def _check_vm_has_drive_auth(runtime: Any) -> bool:
    ok, stdout_txt, _errors, _flags = execute_kernel_interactive(
        runtime,
        REMOTE_CHECK_CODE,
        allow_stdin=False,
        timeout=30.0,
        quiet_stdout=True,
    )
    return ok and "COLABD_VM_DRIVE_AUTH_OK" in stdout_txt


def cmd_check(args: argparse.Namespace) -> int:
    runtime, _name = _open_runtime(args.config, args.auth, args.session)
    try:
        if _check_vm_has_drive_auth(runtime):
            print("COLABD_VM_DRIVE_AUTH_OK")
            return 0
        print("COLABD_VM_DRIVE_AUTH_MISSING")
        return 1
    finally:
        runtime.stop()


def cmd_auth(args: argparse.Namespace) -> int:
    runtime, name = _open_runtime(args.config, args.auth, args.session)
    try:
        if not args.force:
            try:
                if _check_vm_has_drive_auth(runtime):
                    print(f"[colabd] 远端实例 '{name}' 已具备有效 Google / Drive API 凭证，跳过重复授权。")
                    return 0
            except Exception:
                pass

        print(f"[colabd] 正在为远端实例 '{name}' 启动交互式 Google / Drive 授权回调...")
        ok, _out, errors, flags = execute_kernel_interactive(
            runtime,
            REMOTE_AUTH_CODE,
            allow_stdin=True,
            timeout=args.timeout,
            quiet_stdout=False,
        )
        if flags.get("cancelled"):
            return 130
        if not ok:
            if errors:
                print(f"[colabd] 远端授权执行失败: {errors[-1].splitlines()[-1]}", file=sys.stderr)
            return 1

        if _check_vm_has_drive_auth(runtime):
            print(f"[colabd] 远端实例 '{name}' Google / Drive API 凭证已生效并核验通过！")
            return 0

        print(
            f"[colabd] 远端授权命令已返回，但未检测到有效 Drive 作用域凭证（可能验证码无效或未勾选 Drive 权限）。",
            file=sys.stderr,
        )
        return 1
    finally:
        runtime.stop()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="colabd remote VM Google/Drive interactive OAuth helper")
    sub = parser.add_subparsers(dest="cmd", required=True)

    for cname, fn in (("check", cmd_check), ("auth", cmd_auth)):
        p = sub.add_parser(cname)
        p.add_argument("--config", default=None, help="Path to isolated sessions.json")
        p.add_argument("--auth", default="oauth2", choices=["oauth2", "adc"])
        p.add_argument("-s", "--session", default=None, help="Colab session name")
        if cname == "auth":
            p.add_argument("--force", action="store_true", help="Force re-auth even if VM already has credentials")
            p.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SEC)
        p.set_defaults(func=fn)

    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except SystemExit as exc:
        return int(exc.code) if isinstance(exc.code, int) else 1
    except KeyboardInterrupt:
        return 130
    except Exception as exc:
        print(f"[colabd] 远端 VM 授权流程异常: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
