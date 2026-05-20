"""
Dify Workflow Deploy Script
Usage:
  Export from UAT:  python deploy_workflow.py export --app-id <uat_app_id>
  Deploy to Prod:   python deploy_workflow.py deploy --app-id <uat_app_id>
  Both at once:     python deploy_workflow.py all --app-id <uat_app_id>
"""

import argparse
import json
import os
import sys
import yaml
import requests
from pathlib import Path

# Load .env file if present
_env_file = Path(__file__).parent / ".env"
if _env_file.exists():
    for line in _env_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())

# ── Configuration ──────────────────────────────────────────────────────────────

UAT_URL      = os.getenv("DIFY_UAT_URL",      "https://your-uat-nginx-url")
UAT_EMAIL    = os.getenv("DIFY_UAT_EMAIL",    "admin@example.com")
UAT_PASSWORD = os.getenv("DIFY_UAT_PASSWORD", "your-uat-password")

PROD_URL      = os.getenv("DIFY_PROD_URL",      "https://your-prod-nginx-url")
PROD_EMAIL    = os.getenv("DIFY_PROD_EMAIL",    "admin@example.com")
PROD_PASSWORD = os.getenv("DIFY_PROD_PASSWORD", "your-prod-password")

# UAT app_id → Prod app_id mapping
# Add entries as: "uat-app-id": "prod-app-id"
APP_ID_MAP: dict[str, str] = {
    "4747ffa0-cb7a-4293-b951-01d171d3f75c": "4747ffa0-cb7a-4293-b951-01d171d3f75c",
}

WORKFLOWS_DIR = Path(__file__).parent / "workflows"

# ── Auth ───────────────────────────────────────────────────────────────────────

def get_session(base_url: str, email: str, password: str) -> requests.Session:
    session = requests.Session()
    resp = session.post(
        f"{base_url}/console/api/login",
        json={"email": email, "password": password, "remember_me": False},
        timeout=30,
    )
    resp.raise_for_status()
    cookies = dict(session.cookies)
    access_token = cookies.get("access_token")
    csrf_token   = cookies.get("csrf_token")

    if access_token:
        session.headers.update({"Authorization": f"Bearer {access_token}"})
    if csrf_token:
        session.headers.update({"X-CSRF-Token": csrf_token})
    session.headers.update({
        "Origin": base_url,
        "Referer": f"{base_url}/",
    })
    return session

# ── List ──────────────────────────────────────────────────────────────────────

def list_apps() -> None:
    print(f"[List] Logging in to UAT: {UAT_URL}")
    session = get_session(UAT_URL, UAT_EMAIL, UAT_PASSWORD)

    resp = session.get(f"{UAT_URL}/console/api/apps?page=1&limit=50", timeout=30)
    resp.raise_for_status()
    apps = resp.json().get("data", [])
    if not apps:
        print("No apps found.")
        return
    print(f"\n{'app_id':<38} {'mode':<12} name")
    print("-" * 70)
    for app in apps:
        print(f"{app['id']:<38} {app.get('mode',''):<12} {app.get('name','')}")

# ── Export ─────────────────────────────────────────────────────────────────────

def export_workflow(uat_app_id: str) -> Path:
    print(f"[Export] Logging in to UAT: {UAT_URL}")
    session = get_session(UAT_URL, UAT_EMAIL, UAT_PASSWORD)

    print(f"[Export] Exporting app {uat_app_id}...")
    resp = session.get(
        f"{UAT_URL}/console/api/apps/{uat_app_id}/export?include_secret=false",
        timeout=30,
    )
    resp.raise_for_status()

    # Response is {"data": "<yaml_string>"} — extract the inner YAML
    body = resp.json()
    dsl_text = body.get("data") or resp.text

    WORKFLOWS_DIR.mkdir(exist_ok=True)
    out_path = WORKFLOWS_DIR / f"{uat_app_id}.yml"
    out_path.write_text(dsl_text, encoding="utf-8")
    print(f"[Export] Saved to {out_path}")
    return out_path

# ── Deploy ─────────────────────────────────────────────────────────────────────

def deploy_workflow(uat_app_id: str) -> None:
    prod_app_id = APP_ID_MAP.get(uat_app_id)
    if not prod_app_id:
        raise ValueError(
            f"No prod app_id mapping found for UAT app_id: {uat_app_id}\n"
            f"Add it to APP_ID_MAP in this script."
        )

    dsl_path = WORKFLOWS_DIR / f"{uat_app_id}.yml"
    if not dsl_path.exists():
        raise FileNotFoundError(
            f"DSL file not found: {dsl_path}\n"
            f"Run 'export' first."
        )

    dsl = yaml.safe_load(dsl_path.read_text(encoding="utf-8"))
    workflow = dsl.get("workflow", {})
    graph    = workflow.get("graph", {})
    features = workflow.get("features", {})

    if not graph:
        raise ValueError("DSL has no workflow.graph — check the exported YAML.")

    print(f"[Deploy] Logging in to Prod: {PROD_URL}")
    session = get_session(PROD_URL, PROD_EMAIL, PROD_PASSWORD)

    # Get current draft hash (required for conflict check)
    print(f"[Deploy] Fetching current draft hash for prod app {prod_app_id}...")
    draft_resp = session.get(
        f"{PROD_URL}/console/api/apps/{prod_app_id}/workflows/draft",
        timeout=30,
    )
    draft_resp.raise_for_status()
    current_hash = draft_resp.json().get("hash")
    print(f"[Deploy] Current draft hash: {current_hash}")

    # Update draft
    print(f"[Deploy] Updating draft for prod app {prod_app_id}...")
    payload = {
        "graph": graph,
        "features": features,
        "environment_variables": workflow.get("environment_variables", []),
        "conversation_variables": workflow.get("conversation_variables", []),
    }
    if current_hash:
        payload["hash"] = current_hash
    resp = session.post(
        f"{PROD_URL}/console/api/apps/{prod_app_id}/workflows/draft",
        json=payload,
        timeout=30,
    )
    if not resp.ok:
        print(f"Draft update failed ({resp.status_code}): {resp.text}")
        resp.raise_for_status()

    # Publish
    print(f"[Deploy] Publishing...")
    resp = session.post(
        f"{PROD_URL}/console/api/apps/{prod_app_id}/workflows/publish",
        timeout=30,
    )
    if not resp.ok:
        print(f"Publish failed ({resp.status_code}): {resp.text}")
        resp.raise_for_status()

    print(f"[Deploy] Done. Prod app {prod_app_id} is now updated.")

# ── CLI ────────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Dify workflow deploy tool")
    parser.add_argument("command", choices=["list", "export", "deploy", "all"],
                        help="export: save UAT DSL to file | deploy: push to prod | all: both")
    parser.add_argument("--app-id", required=False, help="UAT app_id (not required for list)")
    args = parser.parse_args()

    try:
        if args.command == "list":
            list_apps()
            return
        if args.command in ("export", "all"):
            export_workflow(args.app_id)
        if args.command in ("deploy", "all"):
            deploy_workflow(args.app_id)
    except Exception as e:
        print(f"\nError: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
