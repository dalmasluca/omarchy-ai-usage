#!/usr/bin/env python3
"""Official Kimi Code plan quota for omarchy.ai-usage.

Calls the same endpoint the CLI's /usage slash command uses:

    GET {KIMI_CODE_BASE_URL|https://api.kimi.com/coding/v1}/usages

with the OAuth token stored by the CLI in
$KIMI_CODE_HOME|~/.kimi-code/credentials/kimi-code.json. When the token is
expired it is refreshed through the CLI's own flow (POST
{KIMI_CODE_OAUTH_HOST|https://auth.kimi.com}/api/oauth/token,
grant_type=refresh_token) and the rotated token is written back atomically
in the CLI's file format, so the CLI and this script never invalidate each
other's refresh token.

Privacy: tokens are held in memory only. They are never printed, logged,
cached on disk or stored anywhere else.

Emits one line of normalized JSON on stdout and always exits 0:

    {"available": bool, "fetchedAt": <ms>, "plan": "",
     "metrics": [{"label": "5h limit", "percent": 0.42, "resetsAt": "<ISO>"}],
     "error": ""}

`percent` is a 0..1 fraction (the contract codex_usage_scanner.py uses);
`resetsAt` is an ISO timestamp when known, else "".
"""
import json
import math
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

CLIENT_ID = "17e5f671-d194-4dfb-9706-5516cb48c098"  # kimi-code OAuth client (public, baked into the CLI)
DEFAULT_BASE_URL = "https://api.kimi.com/coding/v1"
DEFAULT_OAUTH_HOST = "https://auth.kimi.com"
REFRESH_SKEW_S = 120  # refresh a bit early, like the CLI does
TIMEOUT_S = 8


def kimi_home():
  return Path(os.environ.get("KIMI_CODE_HOME") or (Path.home() / ".kimi-code"))


def credentials_path():
  return kimi_home() / "credentials" / "kimi-code.json"


def base_url():
  return (os.environ.get("KIMI_CODE_BASE_URL") or DEFAULT_BASE_URL).rstrip("/")


def oauth_host():
  return (os.environ.get("KIMI_CODE_OAUTH_HOST") or os.environ.get("KIMI_OAUTH_HOST") or DEFAULT_OAUTH_HOST).rstrip("/")


def to_seconds(value):
  n = float(value or 0)
  return n / 1000.0 if n > 1e12 else n  # tolerate millisecond timestamps


def load_token():
  try:
    return json.loads(credentials_path().read_text())
  except Exception:
    return None


def save_token(token):
  """Atomically persist in the CLI's FileTokenStorage format (0600)."""
  path = credentials_path()
  tmp = path.with_suffix(".json.tmp.%d" % os.getpid())
  try:
    tmp.parent.mkdir(mode=0o700, exist_ok=True)
    tmp.write_text(json.dumps(token, indent=2) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
  except Exception:
    try:
      tmp.unlink()
    except OSError:
      pass
    raise


def http_json(url, data=None, headers=None):
  body = urllib.parse.urlencode(data).encode() if data is not None else None
  req = urllib.request.Request(url, data=body, headers=headers or {})
  with urllib.request.urlopen(req, timeout=TIMEOUT_S) as res:
    return json.loads(res.read())


def refresh_token(token):
  payload = http_json(oauth_host() + "/api/oauth/token", data={
    "client_id": CLIENT_ID,
    "grant_type": "refresh_token",
    "refresh_token": token.get("refresh_token") or "",
  })
  access = payload.get("access_token")
  refresh = payload.get("refresh_token")
  expires_in = float(payload.get("expires_in") or 0)
  if not access or not refresh or expires_in <= 0:
    raise RuntimeError("token refresh returned an incomplete payload")
  merged = dict(token)  # keep any extra fields the CLI may store
  merged.update({
    "access_token": access,
    "refresh_token": refresh,
    "expires_at": math.floor(time.time()) + int(expires_in),
    "scope": payload.get("scope") or token.get("scope") or "",
    "token_type": payload.get("token_type") or token.get("token_type") or "Bearer",
    "expires_in": int(expires_in),
  })
  save_token(merged)
  return merged


def ensure_fresh(token, force=False):
  if force or to_seconds(token.get("expires_at")) - time.time() < REFRESH_SKEW_S:
    return refresh_token(token)
  return token


def fetch_usages(token):
  req = urllib.request.Request(base_url() + "/usages", headers={
    "Authorization": "Bearer " + (token.get("access_token") or ""),
    "Accept": "application/json",
  })
  try:
    with urllib.request.urlopen(req, timeout=TIMEOUT_S) as res:
      return json.loads(res.read()), token
  except urllib.error.HTTPError as exc:
    if exc.code != 401:
      raise
    # The server rejected the token even if it looked fresh: refresh + retry once.
    token = refresh_token(token)
    req = urllib.request.Request(base_url() + "/usages", headers={
      "Authorization": "Bearer " + token["access_token"],
      "Accept": "application/json",
    })
    with urllib.request.urlopen(req, timeout=TIMEOUT_S) as res:
      return json.loads(res.read()), token


def to_int(value):
  try:
    return int(value)
  except (TypeError, ValueError):
    return None


def limit_label(item, detail, window, idx):
  """Same labels the CLI's /usage renders (e.g. "5h limit", "7d limit")."""
  for key in ("name", "title", "scope"):
    value = item.get(key) or detail.get(key)
    if isinstance(value, str) and value:
      return value
  duration = to_int(window.get("duration") or item.get("duration") or detail.get("duration"))
  unit = str(window.get("timeUnit") or item.get("timeUnit") or detail.get("timeUnit") or "")
  if duration is not None:
    if "MINUTE" in unit:
      return "%dh limit" % (duration // 60) if duration >= 60 and duration % 60 == 0 else "%dm limit" % duration
    if "HOUR" in unit:
      return "%dh limit" % duration
    if "DAY" in unit:
      return "%dd limit" % duration
    return "%ds limit" % duration
  return "Limit #%d" % (idx + 1)


def reset_at(detail):
  for key in ("reset_at", "resetAt", "reset_time", "resetTime"):
    value = detail.get(key)
    if isinstance(value, str) and value:
      return value
  for key in ("reset_in", "resetIn", "ttl"):
    seconds = to_int(detail.get(key))
    if seconds and seconds > 0:
      at = datetime.fromtimestamp(time.time() + seconds, timezone.utc)
      return at.replace(microsecond=0).isoformat().replace("+00:00", "Z")
  return ""


def usage_row(raw, default_label):
  if not isinstance(raw, dict):
    return None
  limit = to_int(raw.get("limit"))
  used = to_int(raw.get("used"))
  if used is None:
    remaining = to_int(raw.get("remaining"))
    if remaining is not None and limit is not None:
      used = limit - remaining
  if used is None and limit is None:
    return None
  name = raw.get("name") if isinstance(raw.get("name"), str) else raw.get("title") if isinstance(raw.get("title"), str) else default_label
  return {"label": name, "used": used or 0, "limit": limit or 0, "resetsAt": reset_at(raw)}


def to_metric(row):
  if row and row["limit"] > 0:
    return {"label": row["label"], "percent": max(0.0, min(1.0, row["used"] / row["limit"])), "resetsAt": row["resetsAt"]}
  return None


def normalize(payload):
  """Payload -> metrics list; mirrors the CLI's parseManagedUsagePayload:
  the `usage` summary row ("Weekly limit") first, then every rolling window
  in `limits[]` (5h today; 7d/30d appear here when the plan exposes them)."""
  metrics = []
  if not isinstance(payload, dict):
    return metrics, ""
  metric = to_metric(usage_row(payload.get("usage"), "Weekly limit"))
  if metric:
    metrics.append(metric)
  limits = payload.get("limits")
  if isinstance(limits, list):
    for idx, item in enumerate(limits):
      if not isinstance(item, dict):
        continue
      detail = item.get("detail") if isinstance(item.get("detail"), dict) else item
      window = item.get("window") if isinstance(item.get("window"), dict) else {}
      metric = to_metric(usage_row(detail, limit_label(item, detail, window, idx)))
      if metric:
        metrics.append(metric)
  level = ((payload.get("user") or {}).get("membership") or {}).get("level") or ""
  plan = str(level).replace("LEVEL_", "").replace("_", " ").title()
  return metrics, plan


def self_check():
  # Recorded payload shape (2026-07, plan LEVEL_INTERMEDIATE): weekly summary
  # plus one 300-minute rolling window; string numbers; resetTime ISO.
  real = {
    "user": {"membership": {"level": "LEVEL_INTERMEDIATE"}},
    "usage": {"limit": "100", "used": "100", "resetTime": "2026-07-25T15:18:36.503407Z"},
    "limits": [{"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
                "detail": {"limit": "100", "remaining": "100", "resetTime": "2026-07-24T21:18:36.503407Z"}}],
  }
  metrics, plan = normalize(real)
  assert plan == "Intermediate", plan
  assert [m["label"] for m in metrics] == ["Weekly limit", "5h limit"], metrics
  assert metrics[0]["percent"] == 1.0 and metrics[1]["percent"] == 0.0
  assert metrics[0]["resetsAt"].startswith("2026-07-25")
  # 7d/30d windows render from duration+timeUnit when the plan exposes them.
  synthetic = {"limits": [
    {"window": {"duration": 7, "timeUnit": "TIME_UNIT_DAY"}, "detail": {"limit": 1000, "used": 250}},
    {"window": {"duration": 30, "timeUnit": "TIME_UNIT_DAY"}, "detail": {"limit": 4000, "remaining": 1000, "reset_in": 3600}},
  ]}
  metrics, plan = normalize(synthetic)
  assert [m["label"] for m in metrics] == ["7d limit", "30d limit"], metrics
  assert metrics[0]["percent"] == 0.25 and metrics[1]["percent"] == 0.75
  assert metrics[1]["resetsAt"].endswith("Z") and plan == ""
  assert normalize({}) == ([], "")
  assert normalize(None) == ([], "")


def main():
  if "--self-check" in sys.argv[1:]:
    self_check()
    print("kimi_usage.py self-check passed")
    return 0
  out = {"available": False, "fetchedAt": 0, "plan": "", "metrics": [], "error": ""}
  try:
    token = load_token()
    if not token or not token.get("access_token"):
      out["error"] = "not logged in (run: kimi login)"
    else:
      token = ensure_fresh(token)
      payload, _ = fetch_usages(token)
      metrics, plan = normalize(payload)
      out["available"] = bool(metrics)
      out["metrics"] = metrics
      out["plan"] = plan
      if not metrics:
        out["error"] = "usage endpoint returned no limits"
  except Exception as exc:
    message = str(exc)[:200]
    if isinstance(exc, urllib.error.HTTPError) and exc.code == 401:
      message = "authorization failed (try: kimi login)"
    out["error"] = message
  out["fetchedAt"] = int(time.time() * 1000)
  print(json.dumps(out, separators=(",", ":")))
  return 0


if __name__ == "__main__":
  sys.exit(main())
