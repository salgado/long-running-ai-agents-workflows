#!/usr/bin/env python3
"""
Restore agents, skills, and workflows from the backup/ folder
into an Elastic Cloud instance.

Usage:
    pip install requests python-dotenv
    python scripts/restore.py

Required environment variables (or .env file in the repo root):
    KIBANA_ENDPOINT   https://your-project.kb.region.gcp.elastic.cloud
    ELASTIC_API_KEY   your-api-key
"""

import json
import os
import sys
from pathlib import Path

import requests
from dotenv import load_dotenv

# Load .env from repo root (one level up from scripts/)
load_dotenv(Path(__file__).parent.parent / ".env")

KIBANA_ENDPOINT = os.getenv("KIBANA_ENDPOINT", "").rstrip("/")
API_KEY = os.getenv("ELASTIC_API_KEY", "")

if not KIBANA_ENDPOINT or not API_KEY:
    print("Error: KIBANA_ENDPOINT and ELASTIC_API_KEY must be set.")
    print("Create a .env file in the repo root or export the variables.")
    sys.exit(1)

HEADERS = {
    "Authorization": f"ApiKey {API_KEY}",
    "Content-Type": "application/json",
    "kbn-xsrf": "true",
}

BACKUP_DIR = Path(__file__).parent.parent / "backup"

SKIP_SKILL_IDS = {
    "visualization-creation", "graph-creation", "discover-data-analysis",
    "search.catalog-ecommerce", "search.elasticsearch-onboarding",
    "search.keyword-search", "search.rag-chatbot", "search.use-case-library",
    "search.vector-hybrid-search", "dashboard-management", "workflow-authoring",
    "cases-management", "cases-analytics", "skill-management",
    "agent-builder-traces", "streams-management",
    "search.elasticsearch-tutorial", "search.use-case-library",
}

SKIP_AGENT_NAMES = {"Elastic AI Agent"}

SERVER_FIELDS = {
    "created_at", "updated_at", "createdAt", "updatedAt", "version",
    "@timestamp", "readonly", "type", "visibility", "experimental",
    "createdBy", "lastUpdatedBy", "valid", "lastUpdatedAt", "history",
    "definition",
}

# For workflows only — id is auto-assigned on creation
WORKFLOW_SERVER_FIELDS = SERVER_FIELDS | {"id"}


def clean(obj):
    return {k: v for k, v in obj.items() if k not in SERVER_FIELDS}


# ── Skills ────────────────────────────────────────────────────────────────────

def restore_skills():
    backup_file = BACKUP_DIR / "save_skills.json"
    if not backup_file.exists():
        print("  save_skills.json not found, skipping.")
        return

    skills = json.loads(backup_file.read_text()).get("skills", [])
    existing = {
        s["id"] for s in
        requests.get(f"{KIBANA_ENDPOINT}/api/agent_builder/skills", headers=HEADERS)
        .raise_for_status() or
        requests.get(f"{KIBANA_ENDPOINT}/api/agent_builder/skills", headers=HEADERS)
        .json().get("results", [])
        if "id" in s
    }

    # Re-fetch properly
    resp = requests.get(f"{KIBANA_ENDPOINT}/api/agent_builder/skills", headers=HEADERS)
    resp.raise_for_status()
    data = resp.json()
    existing = {s["id"] for s in (data if isinstance(data, list) else data.get("results", data.get("skills", [])))}

    created = updated = skipped = 0
    for skill in skills:
        sid = skill.get("id", "")
        if sid in SKIP_SKILL_IDS:
            skipped += 1
            continue
        payload = {k: v for k, v in clean(skill).items() if k != "id"}
        try:
            if sid in existing:
                requests.put(f"{KIBANA_ENDPOINT}/api/agent_builder/skills/{sid}", headers=HEADERS, json=payload).raise_for_status()
                print(f"  updated  {sid}")
                updated += 1
            else:
                requests.post(f"{KIBANA_ENDPOINT}/api/agent_builder/skills", headers=HEADERS, json={"id": sid, **payload}).raise_for_status()
                print(f"  created  {sid}")
                created += 1
        except requests.HTTPError as e:
            print(f"  failed   {sid}: {e.response.status_code}")
    print(f"  Skills: created={created}, updated={updated}, skipped={skipped}")


# ── Agents ─────────────────────────────────────────────────────────────────────

def restore_agents():
    backup_file = BACKUP_DIR / "save_agents.json"
    if not backup_file.exists():
        print("  save_agents.json not found, skipping.")
        return

    agents = json.loads(backup_file.read_text()).get("agents", [])

    resp = requests.get(f"{KIBANA_ENDPOINT}/api/agent_builder/agents", headers=HEADERS)
    resp.raise_for_status()
    data = resp.json()
    existing = {a["id"]: a for a in (data if isinstance(data, list) else data.get("results", data.get("agents", [])))}

    created = updated = skipped = 0
    for agent in agents:
        aid = agent.get("id", "")
        name = agent.get("name", "")
        if name in SKIP_AGENT_NAMES:
            skipped += 1
            continue
        payload = clean(agent)
        payload.pop("access_control", None)
        payload.pop("permissions", None)
        try:
            if aid in existing:
                requests.put(f"{KIBANA_ENDPOINT}/api/agent_builder/agents/{aid}", headers=HEADERS, json=payload).raise_for_status()
                print(f"  updated  {name}")
                updated += 1
            else:
                requests.post(f"{KIBANA_ENDPOINT}/api/agent_builder/agents", headers=HEADERS, json=payload).raise_for_status()
                print(f"  created  {name}")
                created += 1
        except requests.HTTPError as e:
            print(f"  failed   {name}: {e.response.status_code}")
    print(f"  Agents: created={created}, updated={updated}, skipped={skipped}")


# ── Workflows ──────────────────────────────────────────────────────────────────

def restore_workflows():
    backup_file = BACKUP_DIR / "save_workflows.json"
    if not backup_file.exists():
        print("  save_workflows.json not found, skipping.")
        return

    workflows = json.loads(backup_file.read_text()).get("workflows", [])

    resp = requests.get(f"{KIBANA_ENDPOINT}/api/workflows", headers=HEADERS, params={"page": 1, "size": 100})
    resp.raise_for_status()
    existing_names = {w["name"] for w in resp.json().get("results", [])}

    created = skipped = 0
    for workflow in workflows:
        name = workflow.get("name", "")
        if name in existing_names:
            print(f"  skipped  {name}")
            skipped += 1
            continue
        payload = {k: v for k, v in workflow.items() if k not in WORKFLOW_SERVER_FIELDS}
        try:
            requests.post(f"{KIBANA_ENDPOINT}/api/workflows", headers=HEADERS, json={"workflows": [payload]}).raise_for_status()
            print(f"  created  {name}")
            created += 1
        except requests.HTTPError as e:
            print(f"  failed   {name}: {e.response.status_code}")
    print(f"  Workflows: created={created}, skipped={skipped}")


# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    print(f"Restoring to: {KIBANA_ENDPOINT}\n")

    print("=" * 50)
    print("  Restoring Skills...")
    print("=" * 50)
    restore_skills()

    print("\n" + "=" * 50)
    print("  Restoring Agents...")
    print("=" * 50)
    restore_agents()

    print("\n" + "=" * 50)
    print("  Restoring Workflows...")
    print("=" * 50)
    restore_workflows()

    print("\n" + "=" * 50)
    print("  Done.")
    print("=" * 50)
    print("\nNext step: create the alerting rule in Kibana.")
    print("See README.md for instructions.")


if __name__ == "__main__":
    main()
