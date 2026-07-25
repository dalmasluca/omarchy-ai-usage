#!/usr/bin/env python3
"""Safe provider detection for dalmasluca.ai-usage.

One script, dispatched by provider id on argv[1]:

    provider_probe.py <kimi|grok>

Emits a single line of normalized JSON on stdout. Detection only: it never
prints tokens/keys/cookies, never launches an agent or TUI, never parses a
browser store. It checks CLI presence + version and non-sensitive config-dir
/ auth-file *existence*. Official quota is reported as unavailable unless a
documented machine-readable command exists (Kimi Code and Grok Build have
one: scripts/kimi_usage.py and scripts/grok_usage.py), so the UI shows the
CLI's own usage surface instead of inventing numbers.
"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

HOME = Path.home()


def runtime_env():
  path_parts = [
    os.environ.get("PATH", ""),
    str(HOME / ".local" / "bin"),
    str(HOME / ".npm-global" / "bin"),
    str(HOME / ".local" / "share" / "mise" / "shims"),
  ]
  env = {
    "PATH": os.pathsep.join(p for p in path_parts if p),
    "HOME": str(HOME),
  }
  return env


ENV = runtime_env()


def which(name):
  return shutil.which(name, path=ENV.get("PATH"))


def run(argv, timeout=6):
  """Run a command with a minimal env, returning (ok, stdout). Never raises."""
  try:
    proc = subprocess.run(
      argv,
      stdout=subprocess.PIPE,
      stderr=subprocess.DEVNULL,
      text=True,
      timeout=timeout,
      env=ENV,
    )
    return proc.returncode == 0, (proc.stdout or "")
  except Exception:
    return False, ""


def first_line(text, limit=120):
  for line in str(text or "").splitlines():
    line = line.strip()
    if line:
      return line[:limit]
  return ""


def version_of(cli, *args):
  ok, out = run([cli, *args], timeout=6)
  if not ok:
    return ""
  return first_line(out)


def base(pid, display):
  return {
    "id": pid,
    "displayName": display,
    "installed": False,
    "authenticated": False,
    "authKind": "",
    "plan": "",
    "version": "",
    "experimental": True,
    "officialQuotaAvailable": False,
    "quotaNote": "",
    "loginCommand": "",
    "docsUrl": "",
    "error": "",
  }


def probe_kimi():
  out = base("kimi", "Kimi Code")
  out["docsUrl"] = "https://www.kimi.com/code/docs/en/kimi-code-cli/reference/slash-commands.html"
  out["loginCommand"] = "kimi login"
  cli = which("kimi")
  if not cli:
    out["quotaNote"] = "Kimi CLI not installed"
    return out
  out["installed"] = True
  out["version"] = version_of(cli, "--version")
  home = Path(os.environ.get("KIMI_CODE_HOME") or (HOME / ".kimi-code"))
  # Existence only — never read credential contents.
  out["authenticated"] = home.exists() and any(home.iterdir()) if home.exists() else False
  out["authKind"] = "cli-login" if out["authenticated"] else ""
  out["quotaNote"] = "Quota available in Kimi /usage"
  return out


def probe_grok():
  out = base("grok", "Grok Build")
  out["docsUrl"] = "https://docs.x.ai/build/cli/reference"
  out["loginCommand"] = "grok login --device-auth"
  cli = which("grok")
  if not cli:
    out["quotaNote"] = "Grok CLI not installed"
    return out
  out["installed"] = True
  out["version"] = version_of(cli, "--version")
  # Auth lives in $GROK_HOME|~/.grok/auth.json (keyed by issuer::client-id).
  # Presence of a non-empty token only — values are never read or printed.
  # (`grok inspect --json` carries no auth state, so it is not used here.)
  grok_home = Path(os.environ.get("GROK_HOME") or (HOME / ".grok"))
  entry = {}
  try:
    store = json.loads((grok_home / "auth.json").read_text())
    for value in (store or {}).values():
      if isinstance(value, dict) and value.get("key"):
        entry = value
        break
  except Exception:
    entry = {}
  out["authenticated"] = bool(entry)
  out["authKind"] = str(entry.get("auth_mode") or "device-auth") if entry else ""
  out["quotaNote"] = "Quota available via /usage in Grok Build"
  return out


PROBES = {
  "kimi": probe_kimi,
  "grok": probe_grok,
}


def main():
  pid = sys.argv[1] if len(sys.argv) > 1 else ""
  probe = PROBES.get(pid)
  if probe is None:
    print(json.dumps({"id": pid, "error": "unknown provider"}, separators=(",", ":")))
    return 1
  try:
    result = probe()
  except Exception as exc:  # isolate failures per provider
    result = base(pid, pid)
    result["error"] = str(exc)[:200]
  print(json.dumps(result, separators=(",", ":")))
  return 0


if __name__ == "__main__":
  sys.exit(main())
