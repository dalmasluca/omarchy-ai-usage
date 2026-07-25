#!/usr/bin/env python3
"""Official Grok Build credit quota for dalmasluca.ai-usage.

Calls the same endpoint the CLI's /usage command fetches (source:
gork-build crates/codegen/xai-grok-shell/src/extensions/billing.rs):

    GET {base}/billing?format=credits      (base: https://cli-chat-proxy.grok.com/v1)

with the grok.com session token from $GROK_HOME|~/.grok/auth.json. When the
token is expired it is refreshed through the CLI's own OAuth2 flow (POST
{oidc_issuer}/oauth2/token, grant_type=refresh_token) and the rotated token
is written back atomically under the CLI's advisory auth.json.lock flock, so
the CLI and this script never invalidate each other's refresh token.

Privacy: tokens are held in memory only. They are never printed, logged,
cached on disk or stored anywhere else.

Output contract matches kimi_usage.py (one JSON line, always exit 0):

    {"available": bool, "fetchedAt": <ms>, "plan": "",
     "metrics": [{"label": "Weekly credits", "percent": 0.10, "resetsAt": "<ISO>"}],
     "error": ""}
"""
import fcntl
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

DEFAULT_PROXY_BASE = "https://cli-chat-proxy.grok.com/v1"
DEFAULT_TOKEN_ENDPOINT = "https://auth.x.ai/oauth2/token"
TOKEN_HEADER = "xai-grok-cli"          # GrokComConfig::default().token_header
CLIENT_VERSION = "0.2.101"             # x-grok-client-version, informational
USER_AGENT = "reqwest/0.12.9"          # auth host sits behind Cloudflare UA filtering
REFRESH_SKEW_S = 120
TIMEOUT_S = 10
LOCK_TIMEOUT_S = 5


def grok_home():
  return Path(os.environ.get("GROK_HOME") or (Path.home() / ".grok"))


def proxy_base():
  return (os.environ.get("_CLI_CHAT_PROXY_BASE_URL") or DEFAULT_PROXY_BASE).rstrip("/")


def http_json(url, data=None, headers=None):
  body = urllib.parse.urlencode(data).encode() if data is not None else None
  hdrs = {"User-Agent": USER_AGENT, "Accept": "application/json"}
  hdrs.update(headers or {})
  req = urllib.request.Request(url, data=body, headers=hdrs)
  with urllib.request.urlopen(req, timeout=TIMEOUT_S) as res:
    return json.loads(res.read())


def load_auth():
  """(entry_key, entry) for the first auth.json entry holding a token."""
  try:
    store = json.loads((grok_home() / "auth.json").read_text())
  except Exception:
    return None, None
  if not isinstance(store, dict):
    return None, None
  for key, entry in store.items():
    if isinstance(entry, dict) and entry.get("key"):
      return key, entry
  return None, None


def token_expired(entry):
  raw = str(entry.get("expires_at") or "")
  try:
    exp = datetime.fromisoformat(raw.replace("Z", "+00:00"))
  except ValueError:
    return True
  if exp.tzinfo is None:
    exp = exp.replace(tzinfo=timezone.utc)
  return (exp - datetime.now(timezone.utc)).total_seconds() < REFRESH_SKEW_S


def refresh_entry(entry):
  issuer = str(entry.get("oidc_issuer") or "").rstrip("/")
  url = (issuer + "/oauth2/token") if issuer else DEFAULT_TOKEN_ENDPOINT
  form = {"grant_type": "refresh_token", "refresh_token": entry.get("refresh_token") or ""}
  if entry.get("oidc_client_id"):
    form["client_id"] = entry["oidc_client_id"]
  for k in ("principal_type", "principal_id"):  # sent by the CLI when present
    if entry.get(k):
      form[k] = entry[k]
  tok = http_json(url, data=form)
  if not tok.get("access_token"):
    raise RuntimeError("token refresh returned no access_token")
  entry["key"] = tok["access_token"]
  if tok.get("refresh_token"):  # rotates; absent means "keep current"
    entry["refresh_token"] = tok["refresh_token"]
  expires_in = int(tok.get("expires_in") or 3600)
  entry["expires_at"] = (datetime.now(timezone.utc) + timedelta(seconds=expires_in)).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
  return entry


def refresh_under_lock(entry_key, current, force=False):
  """Refresh + persist under the CLI's advisory flock so a concurrent CLI
  refresh wins instead of both sides rotating the (single-use) refresh token.
  Returns the freshest entry available."""
  home = grok_home()
  lock_file = open(home / "auth.json.lock", "a+")
  deadline = time.time() + LOCK_TIMEOUT_S
  locked = False
  while time.time() < deadline:
    try:
      fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
      locked = True
      break
    except OSError:
      time.sleep(0.1)
  try:
    if not locked:
      # CLI holds the lock (likely refreshing): reuse its result.
      _, reloaded = load_auth()
      return reloaded or current
    path = home / "auth.json"
    try:
      store = json.loads(path.read_text())
    except Exception:
      store = {}
    fresh = store.get(entry_key)
    if not (isinstance(fresh, dict) and fresh.get("key")):
      fresh = current
    if not force and not token_expired(fresh):
      return fresh  # the CLI refreshed while we waited
    fresh = refresh_entry(fresh)
    store[entry_key] = fresh
    tmp = path.with_suffix(".json.tmp.%d" % os.getpid())
    try:
      tmp.write_text(json.dumps(store, indent=2))
      os.chmod(tmp, 0o600)  # contains tokens: never leave a 0644 tmp behind
      os.replace(tmp, path)
    except Exception:
      try:
        tmp.unlink()
      except OSError:
        pass
      raise
    return fresh
  finally:
    if locked:
      fcntl.flock(lock_file, fcntl.LOCK_UN)
    lock_file.close()


def billing_headers(entry):
  return {
    "Authorization": "Bearer " + entry["key"],
    "X-XAI-Token-Auth": TOKEN_HEADER,
    "x-userid": str(entry.get("user_id") or ""),
    "x-grok-client-version": CLIENT_VERSION,
  }


def fetch_billing(entry):
  try:
    return http_json(proxy_base() + "/billing?format=credits", headers=billing_headers(entry))
  except urllib.error.HTTPError as exc:
    if exc.code != 401:
      raise
    return None  # caller refreshes and retries once


def iso_utc(value):
  """RFC3339 -> compact UTC ISO that JS Date parses cleanly."""
  raw = str(value or "")
  if not raw:
    return ""
  try:
    dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
  except ValueError:
    return raw
  if dt.tzinfo is None:
    dt = dt.replace(tzinfo=timezone.utc)
  return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


PERIOD_LABELS = {"USAGE_PERIOD_TYPE_WEEKLY": "Weekly credits", "USAGE_PERIOD_TYPE_MONTHLY": "Monthly credits"}


def normalize(payload):
  """billing?format=credits payload -> metrics list (fractions 0..1)."""
  metrics = []
  config = (payload or {}).get("config") if isinstance(payload, dict) else None
  if not isinstance(config, dict):
    return metrics
  period = config.get("currentPeriod") if isinstance(config.get("currentPeriod"), dict) else {}
  pct = config.get("creditUsagePercent")
  if pct is None:  # deprecated legacy shape
    limit = (config.get("monthlyLimit") or {}).get("val") or 0
    used = (config.get("used") or {}).get("val") or 0
    pct = (used / limit * 100.0) if limit > 0 else None
  if pct is not None:
    metrics.append({
      "label": PERIOD_LABELS.get(str(period.get("type") or ""), "Credits"),
      "percent": max(0.0, min(1.0, float(pct) / 100.0)),
      "resetsAt": iso_utc(period.get("end") or config.get("billingPeriodEnd")),
    })
  # Per-product breakdown: only when it adds information beyond the pool row.
  products = config.get("productUsage") if isinstance(config.get("productUsage"), list) else []
  if len(products) > 1 or (products and products[0].get("usagePercent") != pct):
    for item in products:
      if not isinstance(item, dict) or item.get("usagePercent") is None:
        continue
      metrics.append({
        "label": str(item.get("product") or "Product"),
        "percent": max(0.0, min(1.0, float(item["usagePercent"]) / 100.0)),
        "resetsAt": "",
      })
  cap = (config.get("onDemandCap") or {}).get("val") or 0
  if cap > 0:  # pay-as-you-go headroom on top of the included pool
    used = (config.get("onDemandUsed") or {}).get("val") or 0
    metrics.append({"label": "On-demand cap", "percent": max(0.0, min(1.0, used / cap)), "resetsAt": ""})
  return metrics


def self_check():
  real = {"config": {
    "currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY",
                      "start": "2026-07-21T02:33:55.961189+00:00",
                      "end": "2026-07-28T02:33:55.961189+00:00"},
    "creditUsagePercent": 10.0,
    "onDemandCap": {"val": 0}, "onDemandUsed": {"val": 0},
    "productUsage": [{"product": "GrokChat", "usagePercent": 10.0}],
    "isUnifiedBillingUser": True,
  }}
  metrics = normalize(real)
  assert [m["label"] for m in metrics] == ["Weekly credits"], metrics  # single product == pool: no dup
  assert metrics[0]["percent"] == 0.10 and metrics[0]["resetsAt"] == "2026-07-28T02:33:55Z", metrics
  multi = {"config": {"creditUsagePercent": 40.0,
                      "productUsage": [{"product": "GrokChat", "usagePercent": 30.0},
                                       {"product": "GrokBuild", "usagePercent": 55.0}],
                      "onDemandCap": {"val": 5000}, "onDemandUsed": {"val": 1250}}}
  metrics = normalize(multi)
  assert [m["label"] for m in metrics] == ["Credits", "GrokChat", "GrokBuild", "On-demand cap"], metrics
  assert metrics[-1]["percent"] == 0.25 and metrics[0]["resetsAt"] == ""
  legacy = {"config": {"monthlyLimit": {"val": 1000}, "used": {"val": 250},
                       "billingPeriodEnd": "2026-08-01T00:00:00Z"}}
  metrics = normalize(legacy)
  assert metrics[0]["percent"] == 0.25 and metrics[0]["resetsAt"] == "2026-08-01T00:00:00Z"
  assert normalize({}) == [] and normalize(None) == []


def main():
  if "--self-check" in sys.argv[1:]:
    self_check()
    print("grok_usage.py self-check passed")
    return 0
  out = {"available": False, "fetchedAt": 0, "plan": "", "metrics": [], "error": ""}
  try:
    entry_key, entry = load_auth()
    if not entry:
      out["error"] = "not logged in (run: grok login)"
    else:
      if token_expired(entry):
        entry = refresh_under_lock(entry_key, entry)
      payload = fetch_billing(entry)
      if payload is None:  # 401: force refresh, retry once
        entry = refresh_under_lock(entry_key, entry, force=True)
        payload = fetch_billing(entry)
        if payload is None:
          raise RuntimeError("authorization failed (try: grok login)")
      metrics = normalize(payload)
      out["available"] = bool(metrics)
      out["metrics"] = metrics
      if not metrics:
        out["error"] = "billing endpoint returned no usage"
  except Exception as exc:
    message = str(exc)[:200]
    if isinstance(exc, urllib.error.HTTPError) and exc.code in (401, 403):
      message = "authorization failed (try: grok login)"
    out["error"] = message
  out["fetchedAt"] = int(time.time() * 1000)
  print(json.dumps(out, separators=(",", ":")))
  return 0


if __name__ == "__main__":
  sys.exit(main())
