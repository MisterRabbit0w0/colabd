# Security policy

## Reporting a vulnerability

Do not open a public GitHub issue for security vulnerabilities such as token leakage, command injection, or unauthenticated endpoint exposure. Report vulnerabilities privately via [GitHub Security Advisories](https://github.com/MisterRabbit0w0/colabd/security/advisories/new).

## Credential handling model

- **Local config & multi-account permissions.** `colabd` writes `~/.config/colabd/config.env` inside a `umask 077` subshell and enforces `chmod 600` on every load and save. Multi-account OAuth 2.0 refresh tokens are stored in the OS keyring (`colabd-accounts`), and per-account metadata, isolated `sessions.json`, and ADC snapshots live inside `0700` directories with atomic `0600` writes.
- **Loopback binding behind tunnels.** When `TUNNEL_MODE` is `cf_quick`, `cf_named`, or `ssh`, the remote [`mw00/project-maya`](https://github.com/mw00/project-maya) server binds exclusively to `127.0.0.1` and requires `Authorization: Bearer <MAYA_API_KEY>` on `/v1/*`, `/v1/messages`, `/v1/responses`, and `/health`.
- **Safe parameter serialization.** Host configuration values pass to `session_runner.py` via `sys.argv` and Python `repr()`, preventing shell or Python string injection when tokens contain quotes or `$` characters.
- **Account-aware orphan runtime protection.** Exiting the console, receiving `SIGINT`, `SIGTERM`, or `SIGHUP`, switching accounts, clearing credentials on logout, or deleting a saved profile stops active Colab runtimes under their exact owning account so GPU Compute Units do not burn in the background.
