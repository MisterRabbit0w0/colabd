# Security policy

## Reporting a vulnerability

Do not open a public GitHub issue for security vulnerabilities such as token leakage, command injection, or unauthenticated endpoint exposure. Report vulnerabilities privately via [GitHub Security Advisories](https://github.com/MisterRabbit0w0/colabd/security/advisories/new).

## Credential handling model

- **Local config permissions.** `colabd` writes `~/.config/colabd/config.env` inside a `umask 077` subshell and enforces `chmod 600` on every load and save.
- **Loopback binding behind tunnels.** When `TUNNEL_MODE` is `cf_quick`, `cf_named`, or `ssh`, the remote [`mw00/project-maya`](https://github.com/mw00/project-maya) server binds exclusively to `127.0.0.1` and requires `Authorization: Bearer <MAYA_API_KEY>` on `/v1/*`, `/v1/messages`, `/v1/responses`, and `/health`.
- **Safe parameter serialization.** Host configuration values pass to `session_runner.py` via `sys.argv` and Python `repr()`, preventing shell or Python string injection when tokens contain quotes or `$` characters.
- **Orphan runtime protection.** Exiting the console, receiving `SIGINT`, `SIGTERM`, or `SIGHUP`, or switching accounts via `colab logout` stops active Colab runtimes so GPU Compute Units do not burn in the background.
