#!/usr/bin/env python3
"""Secure multi-account credential and session store helper for colabd.

Manages isolated OAuth 2.0 keyring slots, ADC credential snapshots, per-account
Colab CLI session files, and optional orphaned runtime unassignment.
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
from typing import Any, Dict, List, Optional, Tuple

COLAB_KEYRING_SERVICE = "google-colab-cli"
COLAB_KEYRING_USER = "oauth_token"
PROFILE_KEYRING_SERVICE = "colabd-accounts"
PROFILE_KEYRING_USER_PREFIX = "oauth_token:"
KEYRING_TIMEOUT_SECONDS = 15.0

ALIAS_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


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


def _validate_alias(alias: str) -> str:
    if not alias or alias in (".", "..") or not ALIAS_RE.match(alias):
        raise ValueError(
            "Invalid account alias. Use 1-64 characters: letters, digits, '.', '_', '-' "
            "(starting with a letter or digit)."
        )
    return alias


def _profile_dir(accounts_dir: str, alias: str) -> pathlib.Path:
    safe_alias = _validate_alias(alias)
    base = pathlib.Path(accounts_dir).resolve()
    target = (base / safe_alias).resolve()
    if target.parent != base:
        raise ValueError("Account path escapes accounts directory.")
    return target


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
        """Returns (secret_or_none, backend_available)."""
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
                err_name = type(exc).__name__
                if err_name == "PasswordDeleteError":
                    return True
                # Fall through to OS CLI fallback below if keyring backend failed.

        if sys.platform == "darwin" and shutil.which("security"):
            res = subprocess.run(
                ["security", "delete-generic-password", "-s", service, "-a", username],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            # 0 = deleted, 44 = item not found
            return res.returncode in (0, 44)

        if sys.platform.startswith("linux") and shutil.which("secret-tool"):
            res = subprocess.run(
                ["secret-tool", "clear", "service", service, "username", username],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            return res.returncode == 0

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


def _sanitize_tsv(value: str) -> str:
    return value.replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()


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


def cmd_validate_name(args: argparse.Namespace) -> int:
    try:
        _validate_alias(args.alias)
        return 0
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1


def cmd_exists(args: argparse.Namespace) -> int:
    try:
        pdir = _profile_dir(args.accounts_dir, args.alias)
    except ValueError:
        return 1
    return 0 if (pdir / "meta.json").is_file() else 1


def cmd_list(args: argparse.Namespace) -> int:
    base = pathlib.Path(args.accounts_dir)
    if not base.is_dir():
        return 0
    kr = _KeyringAdapter()
    for entry in sorted(base.iterdir(), key=lambda p: p.name):
        if not entry.is_dir():
            continue
        meta_path = entry / "meta.json"
        if not meta_path.is_file():
            continue
        meta = _load_meta(entry)
        name = entry.name
        mode = str(meta.get("auth_mode") or "oauth2")
        email = str(meta.get("email") or "")
        updated = str(meta.get("updated_at") or "")
        if mode == "adc":
            has_cred = (entry / "adc.json").is_file()
        else:
            tok, _ = kr.get(PROFILE_KEYRING_SERVICE, PROFILE_KEYRING_USER_PREFIX + name)
            has_cred = bool(tok) or (entry / "oauth_token.json").is_file()
        sessions = _parse_sessions_file(entry / "sessions.json")
        snames = ",".join(row[0] for row in sessions)
        fields = [
            _sanitize_tsv(name),
            _sanitize_tsv(mode),
            _sanitize_tsv(email),
            "1" if has_cred else "0",
            str(len(sessions)),
            _sanitize_tsv(snames),
            _sanitize_tsv(updated),
        ]
        print("\t".join(fields))
    return 0


def cmd_meta_get(args: argparse.Namespace) -> int:
    pdir = _profile_dir(args.accounts_dir, args.alias)
    meta = _load_meta(pdir)
    val = meta.get(args.field, "")
    print("" if val is None else str(val))
    return 0


def cmd_meta_set(args: argparse.Namespace) -> int:
    pdir = _profile_dir(args.accounts_dir, args.alias)
    meta = _load_meta(pdir)
    meta["name"] = args.alias
    if args.auth_mode is not None:
        meta["auth_mode"] = args.auth_mode
    if args.email is not None:
        meta["email"] = args.email
    if args.storage is not None:
        meta["storage"] = args.storage
    _save_meta(pdir, meta)
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


def cmd_oauth_save_profile(args: argparse.Namespace) -> int:
    pdir = _profile_dir(args.accounts_dir, args.alias)
    kr = _KeyringAdapter()
    token, _ = _read_active_oauth_token(kr, args.colab_config_dir)
    if not token:
        print("No active OAuth2 token found to save.", file=sys.stderr)
        return 1

    _ensure_private_dir(pdir)
    fallback_file = pdir / "oauth_token.json"
    if kr.set(PROFILE_KEYRING_SERVICE, PROFILE_KEYRING_USER_PREFIX + args.alias, token):
        storage = "keyring"
        _remove_file_quiet(fallback_file)
    else:
        _atomic_write_private(fallback_file, token)
        storage = "file"

    meta = _load_meta(pdir)
    meta["name"] = args.alias
    meta["auth_mode"] = "oauth2"
    meta["storage"] = storage
    if args.email:
        meta["email"] = args.email
    _save_meta(pdir, meta)
    print(storage)
    return 0


def cmd_oauth_activate_profile(args: argparse.Namespace) -> int:
    pdir = _profile_dir(args.accounts_dir, args.alias)
    kr = _KeyringAdapter()
    token, _ = kr.get(PROFILE_KEYRING_SERVICE, PROFILE_KEYRING_USER_PREFIX + args.alias)
    fallback_file = pdir / "oauth_token.json"
    if not token and fallback_file.is_file():
        token = fallback_file.read_text(encoding="utf-8").strip()
    if not token:
        print(f"No saved OAuth2 token found for profile '{args.alias}'.", file=sys.stderr)
        return 1

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
    ok = kr.delete(COLAB_KEYRING_SERVICE, COLAB_KEYRING_USER)
    legacy = _legacy_token_path(args.colab_config_dir)
    had_legacy = legacy.exists()
    _remove_file_quiet(legacy)
    if ok:
        return 0
    if had_legacy and not legacy.exists():
        return 0
    return 1


def cmd_adc_save_profile(args: argparse.Namespace) -> int:
    pdir = _profile_dir(args.accounts_dir, args.alias)
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

    _ensure_private_dir(pdir)
    _atomic_write_private(pdir / "adc.json", raw)
    meta = _load_meta(pdir)
    meta["name"] = args.alias
    meta["auth_mode"] = "adc"
    meta["storage"] = "file"
    if args.email:
        meta["email"] = args.email
    _save_meta(pdir, meta)
    print("file")
    return 0


def cmd_delete_profile(args: argparse.Namespace) -> int:
    pdir = _profile_dir(args.accounts_dir, args.alias)
    kr = _KeyringAdapter()
    kr.delete(PROFILE_KEYRING_SERVICE, PROFILE_KEYRING_USER_PREFIX + args.alias)
    if pdir.exists():
        shutil.rmtree(pdir)
    return 0


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
        # Merge non-destructively, keeping destination entries on name collision.
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
    try:
        from colab_cli.auth import AuthProvider, get_credentials  # type: ignore
        from colab_cli.client import Client, Prod  # type: ignore
    except Exception as exc:
        print(f"Cannot import colab_cli to unassign orphan runtime: {exc}", file=sys.stderr)
        return 1

    provider = AuthProvider.ADC if args.auth_mode == "adc" else AuthProvider.OAUTH2
    creds = get_credentials(provider=provider)
    client = Client(Prod(), creds)
    client.unassign(args.endpoint)
    return 0


def build_parser() -> argparse.ArgumentParser:
    default_colab_dir = os.environ.get("COLAB_CLI_CONFIG_DIR", "~/.config/colab-cli")
    parser = argparse.ArgumentParser(description="colabd multi-account store helper")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("validate-name")
    p.add_argument("alias")
    p.set_defaults(func=cmd_validate_name)

    p = sub.add_parser("exists")
    p.add_argument("accounts_dir")
    p.add_argument("alias")
    p.set_defaults(func=cmd_exists)

    p = sub.add_parser("list")
    p.add_argument("accounts_dir")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("meta-get")
    p.add_argument("accounts_dir")
    p.add_argument("alias")
    p.add_argument("field")
    p.set_defaults(func=cmd_meta_get)

    p = sub.add_parser("meta-set")
    p.add_argument("accounts_dir")
    p.add_argument("alias")
    p.add_argument("--auth-mode", default=None)
    p.add_argument("--email", default=None)
    p.add_argument("--storage", default=None)
    p.set_defaults(func=cmd_meta_set)

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

    p = sub.add_parser("oauth-save-profile")
    p.add_argument("accounts_dir")
    p.add_argument("alias")
    p.add_argument("--email", default="")
    p.add_argument("--colab-config-dir", default=default_colab_dir)
    p.set_defaults(func=cmd_oauth_save_profile)

    p = sub.add_parser("oauth-activate-profile")
    p.add_argument("accounts_dir")
    p.add_argument("alias")
    p.add_argument("--colab-config-dir", default=default_colab_dir)
    p.set_defaults(func=cmd_oauth_activate_profile)

    p = sub.add_parser("oauth-clear-active")
    p.add_argument("--colab-config-dir", default=default_colab_dir)
    p.set_defaults(func=cmd_oauth_clear_active)

    p = sub.add_parser("adc-save-profile")
    p.add_argument("accounts_dir")
    p.add_argument("alias")
    p.add_argument("src_adc_file")
    p.add_argument("--email", default="")
    p.set_defaults(func=cmd_adc_save_profile)

    p = sub.add_parser("delete-profile")
    p.add_argument("accounts_dir")
    p.add_argument("alias")
    p.set_defaults(func=cmd_delete_profile)

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
