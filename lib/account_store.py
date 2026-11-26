#!/usr/bin/env python3
"""Secure identity-based multi-account store and scope inspector for colabd.

Accounts are uniquely identified by normalized (email, auth_mode):
  - oauth2 -> <email>          (stored in dir: oauth2__<safe_email>)
  - adc    -> adc:<email>      (stored in dir: adc__<safe_email>)

Manages OS keyring slots, 0600 ADC snapshots, per-account sessions.json,
OAuth2 token revocation, scope validation, and optional orphan unassignment.
"""

import argparse
import datetime
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

COLAB_KEYRING_SERVICE = "google-colab-cli"
COLAB_KEYRING_USER = "oauth_token"
PROFILE_KEYRING_SERVICE = "colabd-accounts"
PROFILE_KEYRING_USER_PREFIX = "oauth_token:"
KEYRING_TIMEOUT_SECONDS = 15.0

REVOKE_URL = "https://oauth2.googleapis.com/revoke"

SCOPE_COLAB = "https://www.googleapis.com/auth/colaboratory"
SCOPE_EMAIL = "https://www.googleapis.com/auth/userinfo.email"
SCOPE_CLOUD = "https://www.googleapis.com/auth/cloud-platform"
SCOPE_DRIVE = "https://www.googleapis.com/auth/drive.file"

REQUIRED_SCOPES = {
    "oauth2": [SCOPE_COLAB, SCOPE_EMAIL],
    "adc": [SCOPE_COLAB, SCOPE_CLOUD],
}
OPTIONAL_SCOPES = {
    "oauth2": [SCOPE_DRIVE],
    "adc": [SCOPE_EMAIL],
}


def _ensure_private_dir(path: pathlib.Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(path, 0o700)
    except OSError:
        pass


def _atomic_write_private(path: pathlib.Path, content: str) -> None:
    _ensure_private_dir(path.parent)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.tmp.", dir=str(path.parent))
    try:
        try:
            os.chmod(tmp_name, 0o600)
        except OSError:
            pass
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(content)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_name, path)
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def _normalize_email(email: str) -> str:
    cleaned = email.strip().lower()
    if not cleaned or "@" not in cleaned or any(ch.isspace() for ch in cleaned):
        raise ValueError(f"Invalid account email identity: {email!r}")
    return cleaned


def _canonical_id(email: str, auth_mode: str) -> str:
    norm = _normalize_email(email)
    if auth_mode == "adc":
        return f"adc:{norm}"
    return norm


def _dir_key_for(email: str, auth_mode: str) -> str:
    norm = _normalize_email(email)
    safe = re.sub(r"[^a-z0-9@._+-]", "_", norm)
    prefix = "adc__" if auth_mode == "adc" else "oauth2__"
    return f"{prefix}{safe}"


def _legacy_token_path(colab_config_dir: str) -> pathlib.Path:
    return pathlib.Path(os.path.expanduser(colab_config_dir)) / "token.json"


def _run_with_timeout(func, *args, timeout: float = KEYRING_TIMEOUT_SECONDS):
    result = None
    error: Optional[BaseException] = None

    def worker() -> None:
        nonlocal result, error
        try:
            result = func(*args)
        except BaseException as exc:  # pragma: no cover
            error = exc

    thread = threading.Thread(target=worker, daemon=True)
    thread.start()
    thread.join(timeout=timeout)
    if thread.is_alive():
        raise TimeoutError(f"Keyring operation timed out after {timeout:.1f}s")
    if error is not None:
        raise error
    return result


class _KeyringAdapter:
    """Abstraction over OS keyring or an isolated file keyring for tests."""

    def __init__(self) -> None:
        env_file = os.environ.get("COLABD_KEYRING_FILE", "").strip()
        self.file_path = pathlib.Path(env_file) if env_file else None
        self._keyring = None
        if self.file_path is None:
            try:
                import keyring  # type: ignore

                self._keyring = keyring
            except Exception:
                self._keyring = None

    def _load_file_db(self) -> Dict[str, Dict[str, str]]:
        assert self.file_path is not None
        if not self.file_path.exists():
            return {}
        try:
            data = json.loads(self.file_path.read_text(encoding="utf-8"))
            return data if isinstance(data, dict) else {}
        except Exception:
            return {}

    def _save_file_db(self, db: Dict[str, Dict[str, str]]) -> None:
        assert self.file_path is not None
        _atomic_write_private(self.file_path, json.dumps(db, indent=2, sort_keys=True))

    def get(self, service: str, username: str) -> Tuple[Optional[str], bool]:
        if self.file_path is not None:
            db = self._load_file_db()
            return db.get(service, {}).get(username), True
        if self._keyring is None:
            return None, False
        try:
            val = _run_with_timeout(self._keyring.get_password, service, username)
            return val, True
        except Exception:
            return None, False

    def set(self, service: str, username: str, secret: str) -> bool:
        if self.file_path is not None:
            db = self._load_file_db()
            svc = db.setdefault(service, {})
            svc[username] = secret
            self._save_file_db(db)
            return True
        if self._keyring is None:
            return False
        try:
            _run_with_timeout(self._keyring.set_password, service, username, secret)
            return True
        except Exception:
            return False

    def delete(self, service: str, username: str) -> bool:
        if self.file_path is not None:
            db = self._load_file_db()
            svc = db.get(service)
            if isinstance(svc, dict) and username in svc:
                del svc[username]
                if not svc:
                    del db[service]
                self._save_file_db(db)
            return True

        if self._keyring is not None:
            try:
                _run_with_timeout(self._keyring.delete_password, service, username)
                return True
            except Exception as exc:
                if type(exc).__name__ == "PasswordDeleteError":
                    return True

        if sys.platform == "darwin" and shutil.which("security"):
            try:
                res = subprocess.run(
                    ["security", "delete-generic-password", "-s", service, "-a", username],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=KEYRING_TIMEOUT_SECONDS,
                    check=False,
                )
                return res.returncode in (0, 44)
            except Exception:
                return False

        if sys.platform.startswith("linux") and shutil.which("secret-tool"):
            try:
                res = subprocess.run(
                    ["secret-tool", "clear", "service", service, "username", username],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=KEYRING_TIMEOUT_SECONDS,
                    check=False,
                )
                return res.returncode == 0
            except Exception:
                return False

        return False


def _now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _load_meta(pdir: pathlib.Path) -> Dict[str, Any]:
    meta_file = pdir / "meta.json"
    if not meta_file.exists():
        return {}
    try:
        data = json.loads(meta_file.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _save_meta(pdir: pathlib.Path, meta: Dict[str, Any]) -> None:
    _ensure_private_dir(pdir)
    meta["updated_at"] = _now_iso()
    _atomic_write_private(pdir / "meta.json", json.dumps(meta, indent=2, ensure_ascii=False) + "\n")


def _iter_accounts(accounts_dir: str) -> List[Tuple[pathlib.Path, Dict[str, Any]]]:
    base = pathlib.Path(accounts_dir)
    if not base.is_dir():
        return []
    items: List[Tuple[pathlib.Path, Dict[str, Any]]] = []
    for entry in sorted(base.iterdir(), key=lambda p: p.name):
        if not entry.is_dir():
            continue
        if not (entry / "meta.json").is_file():
            continue
        meta = _load_meta(entry)
        mode = str(meta.get("auth_mode") or "oauth2")
        email = str(meta.get("email") or "").strip().lower()
        if not meta.get("id"):
            if email and "@" in email:
                meta["id"] = _canonical_id(email, mode)
            else:
                meta["id"] = str(meta.get("name") or entry.name)
        meta.setdefault("dir_key", entry.name)
        meta.setdefault("auth_mode", mode)
        meta.setdefault("email", email)
        meta.setdefault("note", "")
        items.append((entry, meta))
    items.sort(key=lambda pair: str(pair[1].get("id", "")).lower())
    return items


def _resolve_account(accounts_dir: str, query: str) -> Optional[Tuple[pathlib.Path, Dict[str, Any]]]:
    q = query.strip()
    if not q:
        return None
    q_low = q.lower()
    entries = _iter_accounts(accounts_dir)

    # 1. Exact canonical ID match (case-insensitive)
    for pdir, meta in entries:
        if str(meta.get("id", "")).lower() == q_low:
            return pdir, meta

    # 2. Exact directory key or legacy name match
    for pdir, meta in entries:
        if pdir.name.lower() == q_low or str(meta.get("name", "")).lower() == q_low:
            return pdir, meta

    # 3. Bare email match (when e.g. only adc:<email> exists)
    email_matches = [pair for pair in entries if str(pair[1].get("email", "")).lower() == q_low]
    if len(email_matches) == 1:
        return email_matches[0]

    return None


def _parse_sessions_file(path: pathlib.Path) -> List[Tuple[str, str, str, str]]:
    if not path.exists():
        return []
    try:
        raw = path.read_text(encoding="utf-8").strip()
        if not raw:
            return []
        data = json.loads(raw)
        if not isinstance(data, dict):
            return []
    except Exception:
        return []

    rows: List[Tuple[str, str, str, str]] = []
    for name, item in sorted(data.items()):
        if not isinstance(item, dict):
            continue
        accel = str(item.get("accelerator") or "NONE")
        shape = str(item.get("machine_shape") or "STANDARD")
        endpoint = str(item.get("endpoint") or "")
        rows.append((str(name), accel, shape, endpoint))
    return rows


FIELD_SEP = "\x1f"


def _sanitize_tsv(value: str) -> str:
    return value.replace(FIELD_SEP, " ").replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()


def _read_active_oauth_token(kr: _KeyringAdapter, colab_config_dir: str) -> Tuple[Optional[str], str]:
    token, _ = kr.get(COLAB_KEYRING_SERVICE, COLAB_KEYRING_USER)
    if token:
        return token, "keyring"
    legacy = _legacy_token_path(colab_config_dir)
    if legacy.exists():
        try:
            content = legacy.read_text(encoding="utf-8").strip()
            if content:
                return content, "legacy"
        except OSError:
            pass
    return None, "none"


def _remove_file_quiet(path: pathlib.Path) -> None:
    try:
        if path.exists() or path.is_symlink():
            path.unlink()
    except OSError:
        pass


def _short_scope_name(scope: str) -> str:
    if "/" in scope:
        return scope.rsplit("/", 1)[-1]
    return scope


def _extract_adc_email(adc_path: Optional[str]) -> str:
    if not adc_path:
        return ""
    p = pathlib.Path(os.path.expanduser(adc_path))
    if not p.is_file():
        return ""
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            for key in ("client_email", "mock_email", "email"):
                val = str(data.get(key) or "").strip().lower()
                if val and "@" in val:
                    return val
    except Exception:
        pass
    return ""


def _parse_whoami_output(text: str, auth_mode: str, adc_file: str = "") -> Dict[str, Any]:
    email = ""
    scopes: List[str] = []
    saw_scopes_header = False

    for line in text.splitlines():
        m_email = re.match(r"^\s*Email:\s*(\S+@\S+)\s*$", line)
        if m_email:
            email = m_email.group(1).strip().lower()
            continue
        if re.match(r"^\s*Scopes:\s*$", line) or re.match(r"^\s*Scopes:\s*<none>\s*$", line):
            saw_scopes_header = True
            continue
        if saw_scopes_header:
            m_sc = re.match(r"^\s*-\s+(\S+)\s*$", line)
            if m_sc:
                scopes.append(m_sc.group(1).strip())

    if not email and auth_mode == "adc" and adc_file:
        email = _extract_adc_email(adc_file)

    missing_req: List[str] = []
    missing_opt: List[str] = []
    if saw_scopes_header:
        scope_set = set(scopes)
        # Google tokeninfo may emit OIDC short scope 'email' instead of full userinfo.email URI.
        if "email" in scope_set:
            scope_set.add(SCOPE_EMAIL)
        for req in REQUIRED_SCOPES.get(auth_mode, []):
            if req not in scope_set:
                missing_req.append(req)
        for opt in OPTIONAL_SCOPES.get(auth_mode, []):
            if opt not in scope_set:
                missing_opt.append(opt)
        if auth_mode == "adc" and not email and SCOPE_EMAIL not in scope_set:
            if SCOPE_EMAIL not in missing_req:
                missing_req.append(SCOPE_EMAIL)

    return {
        "email": email,
        "scope_checked": saw_scopes_header,
        "scopes": sorted(set(scopes)),
        "missing_req": missing_req,
        "missing_opt": missing_opt,
    }


def _scope_status_label(meta: Dict[str, Any]) -> str:
    m_req = meta.get("missing_required_scopes") or []
    m_opt = meta.get("missing_optional_scopes") or []
    if isinstance(m_req, list) and m_req:
        return "missing:" + ",".join(_short_scope_name(s) for s in m_req)
    if isinstance(m_opt, list) and m_opt:
        return "warn:" + ",".join(_short_scope_name(s) for s in m_opt)
    if meta.get("scopes"):
        return "ok"
    return "unknown"


def _revoke_token_best_effort(token_json: str) -> bool:
    """Best-effort OAuth2 token revocation against Google's revoke endpoint."""
    try:
        data = json.loads(token_json)
        tok = data.get("refresh_token") or data.get("token") or data.get("access_token")
    except Exception:
        tok = None
    if not tok:
        return False

    test_log = os.environ.get("COLABD_TEST_REVOKE_LOG", "").strip()
    if test_log:
        try:
            with open(test_log, "a", encoding="utf-8") as fh:
                fh.write(f"REVOKE token={tok}\n")
            return True
        except OSError:
            return False

    if os.environ.get("COLABD_KEYRING_FILE", "").strip():
        return True

    try:
        body = urllib.parse.urlencode({"token": tok}).encode("utf-8")
        req = urllib.request.Request(
            REVOKE_URL,
            data=body,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=4.0) as resp:
            return 200 <= resp.status < 300
    except Exception:
        return False


def cmd_canonical_id(args: argparse.Namespace) -> int:
    print(_canonical_id(args.email, args.auth_mode))
    return 0


def cmd_resolve_id(args: argparse.Namespace) -> int:
    found = _resolve_account(args.accounts_dir, args.query)
    if not found:
        return 1
    print(found[1]["id"])
    return 0


def cmd_exists(args: argparse.Namespace) -> int:
    return 0 if _resolve_account(args.accounts_dir, args.query) else 1


def cmd_path(args: argparse.Namespace) -> int:
    found = _resolve_account(args.accounts_dir, args.query)
    if not found:
        return 1
    print(str(found[0]))
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    kr = _KeyringAdapter()
    for pdir, meta in _iter_accounts(args.accounts_dir):
        acc_id = str(meta["id"])
        dir_key = str(meta.get("dir_key") or pdir.name)
        mode = str(meta.get("auth_mode") or "oauth2")
        email = str(meta.get("email") or "")
        note = str(meta.get("note") or "")
        updated = str(meta.get("updated_at") or "")
        if mode == "adc":
            has_cred = (pdir / "adc.json").is_file()
        else:
            tok, _ = kr.get(PROFILE_KEYRING_SERVICE, PROFILE_KEYRING_USER_PREFIX + dir_key)
            if not tok and dir_key != acc_id:
                tok, _ = kr.get(PROFILE_KEYRING_SERVICE, PROFILE_KEYRING_USER_PREFIX + acc_id)
            has_cred = bool(tok) or (pdir / "oauth_token.json").is_file()
        scope_st = _scope_status_label(meta)
        sessions = _parse_sessions_file(pdir / "sessions.json")
        snames = ",".join(row[0] for row in sessions)
        fields = [
            _sanitize_tsv(acc_id),
            _sanitize_tsv(mode),
            _sanitize_tsv(email),
            _sanitize_tsv(note),
            "1" if has_cred else "0",
            _sanitize_tsv(scope_st),
            str(len(sessions)),
            _sanitize_tsv(snames),
            _sanitize_tsv(updated),
        ]
        print(FIELD_SEP.join(fields))
    return 0


def cmd_meta_get(args: argparse.Namespace) -> int:
    found = _resolve_account(args.accounts_dir, args.query)
    if not found:
        return 1
    val = found[1].get(args.field, "")
    if isinstance(val, list):
        print(",".join(str(x) for x in val))
    else:
        print("" if val is None else str(val))
    return 0


def cmd_meta_set(args: argparse.Namespace) -> int:
    found = _resolve_account(args.accounts_dir, args.query)
    if not found:
        print(f"Account not found: {args.query}", file=sys.stderr)
        return 1
    pdir, meta = found
    if args.note is not None:
        meta["note"] = args.note.strip()
    if args.scopes_csv is not None:
        meta["scopes"] = [s for s in args.scopes_csv.split(",") if s]
    if args.missing_req_csv is not None:
        meta["missing_required_scopes"] = [s for s in args.missing_req_csv.split(",") if s]
    if args.missing_opt_csv is not None:
        meta["missing_optional_scopes"] = [s for s in args.missing_opt_csv.split(",") if s]
    _save_meta(pdir, meta)
    return 0


def cmd_parse_whoami(args: argparse.Namespace) -> int:
    text = sys.stdin.read() if args.text == "-" else args.text
    info = _parse_whoami_output(text, args.auth_mode, args.adc_file)
    fields = [
        _sanitize_tsv(info["email"]),
        "1" if info["scope_checked"] else "0",
        _sanitize_tsv(",".join(info["missing_req"])),
        _sanitize_tsv(",".join(info["missing_opt"])),
        _sanitize_tsv(",".join(info["scopes"])),
    ]
    print(FIELD_SEP.join(fields))
    return 0


def cmd_adc_extract_email(args: argparse.Namespace) -> int:
    email = _extract_adc_email(args.adc_file)
    if not email:
        return 1
    print(email)
    return 0


def cmd_oauth_has_active(args: argparse.Namespace) -> int:
    kr = _KeyringAdapter()
    token, source = _read_active_oauth_token(kr, args.colab_config_dir)
    print(source)
    return 0 if token else 1


def cmd_oauth_export_active(args: argparse.Namespace) -> int:
    kr = _KeyringAdapter()
    token, _ = _read_active_oauth_token(kr, args.colab_config_dir)
    if not token:
        return 1
    _atomic_write_private(pathlib.Path(args.dest_file), token)
    return 0


def cmd_oauth_import_active(args: argparse.Namespace) -> int:
    src = pathlib.Path(args.src_file)
    if not src.is_file():
        return 1
    token = src.read_text(encoding="utf-8").strip()
    if not token:
        return 1
    kr = _KeyringAdapter()
    legacy = _legacy_token_path(args.colab_config_dir)
    if kr.set(COLAB_KEYRING_SERVICE, COLAB_KEYRING_USER, token):
        _remove_file_quiet(legacy)
        print("keyring")
        return 0
    _atomic_write_private(legacy, token)
    print("legacy")
    return 0


def cmd_oauth_clear_active(args: argparse.Namespace) -> int:
    kr = _KeyringAdapter()
    if args.revoke:
        token, _ = _read_active_oauth_token(kr, args.colab_config_dir)
        if token:
            _revoke_token_best_effort(token)
    ok = kr.delete(COLAB_KEYRING_SERVICE, COLAB_KEYRING_USER)
    legacy = _legacy_token_path(args.colab_config_dir)
    had_legacy = legacy.exists()
    _remove_file_quiet(legacy)
    if ok:
        return 0
    if had_legacy and not legacy.exists():
        return 0
    return 1


def _find_or_prepare_identity_dir(
    accounts_dir: str, email: str, auth_mode: str
) -> Tuple[pathlib.Path, Dict[str, Any], str, str, bool]:
    norm_email = _normalize_email(email)
    acc_id = _canonical_id(norm_email, auth_mode)
    base = pathlib.Path(accounts_dir)

    # Deduplicate by (email, auth_mode) even if an older legacy directory exists.
    for existing_dir, existing_meta in _iter_accounts(accounts_dir):
        ex_email = str(existing_meta.get("email") or "").strip().lower()
        ex_mode = str(existing_meta.get("auth_mode") or "oauth2")
        if ex_email == norm_email and ex_mode == auth_mode:
            dir_key = str(existing_meta.get("dir_key") or existing_dir.name)
            return existing_dir, existing_meta, acc_id, dir_key, True

    dir_key = _dir_key_for(norm_email, auth_mode)
    pdir = base / dir_key
    return pdir, {}, acc_id, dir_key, False


def _apply_scope_meta(meta: Dict[str, Any], args: argparse.Namespace) -> None:
    if args.scopes_csv:
        meta["scopes"] = [s for s in args.scopes_csv.split(",") if s]
    if args.missing_req_csv is not None:
        meta["missing_required_scopes"] = [s for s in args.missing_req_csv.split(",") if s]
    if args.missing_opt_csv is not None:
        meta["missing_optional_scopes"] = [s for s in args.missing_opt_csv.split(",") if s]


def cmd_oauth_save_account(args: argparse.Namespace) -> int:
    kr = _KeyringAdapter()
    token, _ = _read_active_oauth_token(kr, args.colab_config_dir)
    if not token:
        print("No active OAuth2 token found to save.", file=sys.stderr)
        return 1

    pdir, meta, acc_id, dir_key, existed = _find_or_prepare_identity_dir(
        args.accounts_dir, args.email, "oauth2"
    )
    _ensure_private_dir(pdir)
    fallback_file = pdir / "oauth_token.json"
    if kr.set(PROFILE_KEYRING_SERVICE, PROFILE_KEYRING_USER_PREFIX + dir_key, token):
        storage = "keyring"
        _remove_file_quiet(fallback_file)
    else:
        _atomic_write_private(fallback_file, token)
        storage = "file"

    meta["id"] = acc_id
    meta["dir_key"] = dir_key
    meta["email"] = _normalize_email(args.email)
    meta["auth_mode"] = "oauth2"
    meta["storage"] = storage
    if args.note is not None and args.note != "":
        meta["note"] = args.note.strip()
    else:
        meta.setdefault("note", "")
    _apply_scope_meta(meta, args)
    _save_meta(pdir, meta)

    status = "updated" if existed else "created"
    print(f"{status}\t{acc_id}\t{storage}")
    return 0


def cmd_oauth_activate_account(args: argparse.Namespace) -> int:
    found = _resolve_account(args.accounts_dir, args.query)
    if not found:
        print(f"Account not found: {args.query}", file=sys.stderr)
        return 1
    pdir, meta = found
    dir_key = str(meta.get("dir_key") or pdir.name)
    acc_id = str(meta["id"])

    kr = _KeyringAdapter()
    token, _ = kr.get(PROFILE_KEYRING_SERVICE, PROFILE_KEYRING_USER_PREFIX + dir_key)
    if not token and dir_key != acc_id:
        token, _ = kr.get(PROFILE_KEYRING_SERVICE, PROFILE_KEYRING_USER_PREFIX + acc_id)
    fallback_file = pdir / "oauth_token.json"
    if not token and fallback_file.is_file():
        token = fallback_file.read_text(encoding="utf-8").strip()
    if not token:
        print(f"No saved OAuth2 token found for account '{acc_id}'.", file=sys.stderr)
        return 1

    legacy = _legacy_token_path(args.colab_config_dir)
    if kr.set(COLAB_KEYRING_SERVICE, COLAB_KEYRING_USER, token):
        _remove_file_quiet(legacy)
        print("keyring")
        return 0

    _atomic_write_private(legacy, token)
    print("legacy")
    return 0


def cmd_adc_save_account(args: argparse.Namespace) -> int:
    src = pathlib.Path(os.path.expanduser(args.src_adc_file))
    if not src.is_file():
        print(f"ADC credentials file not found: {src}", file=sys.stderr)
        return 1
    raw = src.read_text(encoding="utf-8")
    try:
        parsed = json.loads(raw)
        if not isinstance(parsed, dict):
            raise ValueError("ADC file is not a JSON object.")
    except Exception as exc:
        print(f"Invalid ADC credentials JSON: {exc}", file=sys.stderr)
        return 1

    pdir, meta, acc_id, dir_key, existed = _find_or_prepare_identity_dir(
        args.accounts_dir, args.email, "adc"
    )
    _ensure_private_dir(pdir)
    _atomic_write_private(pdir / "adc.json", raw)

    meta["id"] = acc_id
    meta["dir_key"] = dir_key
    meta["email"] = _normalize_email(args.email)
    meta["auth_mode"] = "adc"
    meta["storage"] = "file"
    if args.note is not None and args.note != "":
        meta["note"] = args.note.strip()
    else:
        meta.setdefault("note", "")
    _apply_scope_meta(meta, args)
    _save_meta(pdir, meta)

    status = "updated" if existed else "created"
    print(f"{status}\t{acc_id}\tfile")
    return 0


def cmd_delete_account(args: argparse.Namespace) -> int:
    found = _resolve_account(args.accounts_dir, args.query)
    if not found:
        return 0
    pdir, meta = found
    dir_key = str(meta.get("dir_key") or pdir.name)
    acc_id = str(meta["id"])
    kr = _KeyringAdapter()
    if args.revoke and str(meta.get("auth_mode") or "oauth2") == "oauth2":
        tok, _ = kr.get(PROFILE_KEYRING_SERVICE, PROFILE_KEYRING_USER_PREFIX + dir_key)
        if not tok and dir_key != acc_id:
            tok, _ = kr.get(PROFILE_KEYRING_SERVICE, PROFILE_KEYRING_USER_PREFIX + acc_id)
        if not tok and (pdir / "oauth_token.json").is_file():
            tok = (pdir / "oauth_token.json").read_text(encoding="utf-8").strip()
        if tok:
            _revoke_token_best_effort(tok)
    kr.delete(PROFILE_KEYRING_SERVICE, PROFILE_KEYRING_USER_PREFIX + dir_key)
    if dir_key != acc_id:
        kr.delete(PROFILE_KEYRING_SERVICE, PROFILE_KEYRING_USER_PREFIX + acc_id)
    if pdir.exists():
        shutil.rmtree(pdir)
    return 0


def cmd_purge_all_keyrings(args: argparse.Namespace) -> int:
    kr = _KeyringAdapter()
    for pdir, meta in _iter_accounts(args.accounts_dir):
        dir_key = str(meta.get("dir_key") or pdir.name)
        acc_id = str(meta["id"])
        kr.delete(PROFILE_KEYRING_SERVICE, PROFILE_KEYRING_USER_PREFIX + dir_key)
        if dir_key != acc_id:
            kr.delete(PROFILE_KEYRING_SERVICE, PROFILE_KEYRING_USER_PREFIX + acc_id)
    return 0


def cmd_oauth_peek_active_email(args: argparse.Namespace) -> int:
    kr = _KeyringAdapter()
    tok, _ = _read_active_oauth_token(kr, args.colab_config_dir)
    if not tok:
        return 1
    try:
        data = json.loads(tok)
        if isinstance(data, dict):
            email = str(data.get("email") or "").strip().lower()
            if email and "@" in email:
                print(email)
                return 0
    except Exception:
        pass
    return 1


def cmd_sessions_list(args: argparse.Namespace) -> int:
    path = pathlib.Path(os.path.expanduser(args.sessions_file))
    for name, accel, shape, endpoint in _parse_sessions_file(path):
        print("\t".join([_sanitize_tsv(name), _sanitize_tsv(accel), _sanitize_tsv(shape), _sanitize_tsv(endpoint)]))
    return 0


def cmd_sessions_clear(args: argparse.Namespace) -> int:
    path = pathlib.Path(os.path.expanduser(args.sessions_file))
    _remove_file_quiet(path)
    _remove_file_quiet(pathlib.Path(f"{path}.lock"))
    return 0


def cmd_sessions_migrate(args: argparse.Namespace) -> int:
    src = pathlib.Path(os.path.expanduser(args.src_file))
    dst = pathlib.Path(os.path.expanduser(args.dst_file))
    if src.resolve() == dst.resolve():
        return 0
    src_sessions = _parse_sessions_file(src)
    if not src_sessions:
        return 0
    dst_sessions = _parse_sessions_file(dst)
    if dst_sessions:
        try:
            src_data = json.loads(src.read_text(encoding="utf-8"))
            dst_data = json.loads(dst.read_text(encoding="utf-8"))
            if isinstance(src_data, dict) and isinstance(dst_data, dict):
                for k, v in src_data.items():
                    dst_data.setdefault(k, v)
                _atomic_write_private(dst, json.dumps(dst_data, indent=2) + "\n")
                _remove_file_quiet(src)
                _remove_file_quiet(pathlib.Path(f"{src}.lock"))
                return 0
        except Exception:
            return 1
    _atomic_write_private(dst, src.read_text(encoding="utf-8"))
    _remove_file_quiet(src)
    _remove_file_quiet(pathlib.Path(f"{src}.lock"))
    return 0


def cmd_unassign_orphan(args: argparse.Namespace) -> int:
    if args.adc_file:
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = os.path.expanduser(args.adc_file)
    os.environ["BROWSER"] = "/usr/bin/false"
    try:
        from colab_cli.auth import AuthProvider, get_credentials  # type: ignore
        from colab_cli.client import Client, Prod  # type: ignore
    except Exception as exc:
        print(f"Cannot import colab_cli to unassign orphan runtime: {exc}", file=sys.stderr)
        return 1

    # Prevent get_credentials() from blocking on interactive OAuth input() if token expired.
    old_stdin = sys.stdin
    try:
        with open(os.devnull, "r", encoding="utf-8") as devnull:
            sys.stdin = devnull
            provider = AuthProvider.ADC if args.auth_mode == "adc" else AuthProvider.OAUTH2
            creds = get_credentials(provider=provider)
            client = Client(Prod(), creds)
            client.unassign(args.endpoint)
        return 0
    except BaseException as exc:
        print(f"Failed to unassign orphan endpoint '{args.endpoint}': {exc}", file=sys.stderr)
        return 1
    finally:
        sys.stdin = old_stdin


def build_parser() -> argparse.ArgumentParser:
    default_colab_dir = os.environ.get("COLAB_CLI_CONFIG_DIR", "~/.config/colab-cli")
    parser = argparse.ArgumentParser(description="colabd identity-based multi-account store")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("canonical-id")
    p.add_argument("email")
    p.add_argument("auth_mode", choices=["oauth2", "adc"])
    p.set_defaults(func=cmd_canonical_id)

    p = sub.add_parser("resolve-id")
    p.add_argument("accounts_dir")
    p.add_argument("query")
    p.set_defaults(func=cmd_resolve_id)

    p = sub.add_parser("exists")
    p.add_argument("accounts_dir")
    p.add_argument("query")
    p.set_defaults(func=cmd_exists)

    p = sub.add_parser("path")
    p.add_argument("accounts_dir")
    p.add_argument("query")
    p.set_defaults(func=cmd_path)

    p = sub.add_parser("list")
    p.add_argument("accounts_dir")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("meta-get")
    p.add_argument("accounts_dir")
    p.add_argument("query")
    p.add_argument("field")
    p.set_defaults(func=cmd_meta_get)

    p = sub.add_parser("meta-set")
    p.add_argument("accounts_dir")
    p.add_argument("query")
    p.add_argument("--note", default=None)
    p.add_argument("--scopes-csv", default=None)
    p.add_argument("--missing-req-csv", default=None)
    p.add_argument("--missing-opt-csv", default=None)
    p.set_defaults(func=cmd_meta_set)

    p = sub.add_parser("parse-whoami")
    p.add_argument("auth_mode", choices=["oauth2", "adc"])
    p.add_argument("text")
    p.add_argument("--adc-file", default="")
    p.set_defaults(func=cmd_parse_whoami)

    p = sub.add_parser("adc-extract-email")
    p.add_argument("adc_file")
    p.set_defaults(func=cmd_adc_extract_email)

    p = sub.add_parser("oauth-has-active")
    p.add_argument("--colab-config-dir", default=default_colab_dir)
    p.set_defaults(func=cmd_oauth_has_active)

    p = sub.add_parser("oauth-export-active")
    p.add_argument("dest_file")
    p.add_argument("--colab-config-dir", default=default_colab_dir)
    p.set_defaults(func=cmd_oauth_export_active)

    p = sub.add_parser("oauth-import-active")
    p.add_argument("src_file")
    p.add_argument("--colab-config-dir", default=default_colab_dir)
    p.set_defaults(func=cmd_oauth_import_active)

    p = sub.add_parser("oauth-clear-active")
    p.add_argument("--revoke", action="store_true")
    p.add_argument("--colab-config-dir", default=default_colab_dir)
    p.set_defaults(func=cmd_oauth_clear_active)

    p = sub.add_parser("oauth-save-account")
    p.add_argument("accounts_dir")
    p.add_argument("email")
    p.add_argument("--note", default=None)
    p.add_argument("--scopes-csv", default="")
    p.add_argument("--missing-req-csv", default=None)
    p.add_argument("--missing-opt-csv", default=None)
    p.add_argument("--colab-config-dir", default=default_colab_dir)
    p.set_defaults(func=cmd_oauth_save_account)

    p = sub.add_parser("oauth-activate-account")
    p.add_argument("accounts_dir")
    p.add_argument("query")
    p.add_argument("--colab-config-dir", default=default_colab_dir)
    p.set_defaults(func=cmd_oauth_activate_account)

    p = sub.add_parser("adc-save-account")
    p.add_argument("accounts_dir")
    p.add_argument("email")
    p.add_argument("src_adc_file")
    p.add_argument("--note", default=None)
    p.add_argument("--scopes-csv", default="")
    p.add_argument("--missing-req-csv", default=None)
    p.add_argument("--missing-opt-csv", default=None)
    p.set_defaults(func=cmd_adc_save_account)

    p = sub.add_parser("delete-account")
    p.add_argument("accounts_dir")
    p.add_argument("query")
    p.add_argument("--revoke", action="store_true")
    p.set_defaults(func=cmd_delete_account)

    p = sub.add_parser("purge-all-keyrings")
    p.add_argument("accounts_dir")
    p.set_defaults(func=cmd_purge_all_keyrings)

    p = sub.add_parser("oauth-peek-active-email")
    p.add_argument("--colab-config-dir", default=default_colab_dir)
    p.set_defaults(func=cmd_oauth_peek_active_email)

    p = sub.add_parser("sessions-list")
    p.add_argument("sessions_file")
    p.set_defaults(func=cmd_sessions_list)

    p = sub.add_parser("sessions-clear")
    p.add_argument("sessions_file")
    p.set_defaults(func=cmd_sessions_clear)

    p = sub.add_parser("sessions-migrate")
    p.add_argument("src_file")
    p.add_argument("dst_file")
    p.set_defaults(func=cmd_sessions_migrate)

    p = sub.add_parser("unassign-orphan")
    p.add_argument("auth_mode", choices=["oauth2", "adc"])
    p.add_argument("endpoint")
    p.add_argument("--adc-file", default="")
    p.set_defaults(func=cmd_unassign_orphan)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        return int(args.func(args))
    except ValueError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
