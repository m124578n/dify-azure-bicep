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
    # "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx": "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy",
}

WORKFLOWS_DIR = Path(__file__).parent / "workflows"

# ── Auth ───────────────────────────────────────────────────────────────────────

def get_token(base_url: str, email: str, password: str) -> str:
    resp = requests.post(
        f"{base_url}/console/api/login",
        json={"email": email, "password": password, "remember_me": False},
        timeout=30,
    )
    resp.raise_for_status()
    body = resp.json()
    token = body.get("data", {}).get("access_token") or body.get("access_token")
    if not token:
        print(f"Login response: {json.dumps(body, indent=2)}")
        raise RuntimeError("Failed to get access_token. Check credentials or response above.")
    return token

# ── Export ─────────────────────────────────────────────────────────────────────

def export_workflow(uat_app_id: str) -> Path:
    print(f"[Export] Logging in to UAT: {UAT_URL}")
    token = get_token(UAT_URL, UAT_EMAIL, UAT_PASSWORD)

    print(f"[Export] Exporting app {uat_app_id}...")
    resp = requests.get(
        f"{UAT_URL}/console/api/apps/{uat_app_id}/export?include_secret=false",
        headers={"Authorization": f"Bearer {token}"},
        timeout=30,
    )
    resp.raise_for_status()

    WORKFLOWS_DIR.mkdir(exist_ok=True)
    out_path = WORKFLOWS_DIR / f"{uat_app_id}.yml"
    out_path.write_text(resp.text, encoding="utf-8")
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
    token = get_token(PROD_URL, PROD_EMAIL, PROD_PASSWORD)
    headers = {"Authorization": f"Bearer {token}"}

    # Update draft
    print(f"[Deploy] Updating draft for prod app {prod_app_id}...")
    resp = requests.post(
        f"{PROD_URL}/console/api/apps/{prod_app_id}/workflows/draft",
        headers=headers,
        json={"graph": graph, "features": features},
        timeout=30,
    )
    if not resp.ok:
        print(f"Draft update failed ({resp.status_code}): {resp.text}")
        resp.raise_for_status()

    # Publish
    print(f"[Deploy] Publishing...")
    resp = requests.post(
        f"{PROD_URL}/console/api/apps/{prod_app_id}/workflows/publish",
        headers=headers,
        timeout=30,
    )
    if not resp.ok:
        print(f"Publish failed ({resp.status_code}): {resp.text}")
        resp.raise_for_status()

    print(f"[Deploy] Done. Prod app {prod_app_id} is now updated.")

# ── CLI ────────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Dify workflow deploy tool")
    parser.add_argument("command", choices=["export", "deploy", "all"],
                        help="export: save UAT DSL to file | deploy: push to prod | all: both")
    parser.add_argument("--app-id", required=True, help="UAT app_id")
    args = parser.parse_args()

    try:
        if args.command in ("export", "all"):
            export_workflow(args.app_id)
        if args.command in ("deploy", "all"):
            deploy_workflow(args.app_id)
    except Exception as e:
        print(f"\nError: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
