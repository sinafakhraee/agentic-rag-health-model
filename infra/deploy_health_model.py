#!/usr/bin/env python3
"""Deploy the Agentic RAG health model (infra/health-model.bicep) to the RG.

Reads every resource ID / endpoint from ../.env so .env stays the single source
of truth, then runs `az deployment group create`. Bicep emits BCP081 warnings
for the preview Microsoft.CloudHealth types — expected; the deployment succeeds.

Usage:
    python deploy_health_model.py [--no-probe] [--alert-email you@example.com]
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

try:
    from dotenv import load_dotenv
    load_dotenv(Path(__file__).resolve().parent.parent / ".env")
except Exception:
    pass

HERE = Path(__file__).resolve().parent
BICEP = HERE / "health-model.bicep"


def _req(name: str) -> str:
    v = os.environ.get(name, "").strip()
    if not v:
        print(f"ERROR: {name} missing from .env", file=sys.stderr)
        sys.exit(1)
    return v


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-probe", action="store_true", help="skip the 1-minute canary Logic App")
    ap.add_argument("--alert-email", default=os.environ.get("ALERT_EMAIL", ""), help="email for Sev1/Sev2 alerts")
    ap.add_argument("--location", default=os.environ.get("HEALTH_MODEL_LOCATION", "centralus"))
    args = ap.parse_args()

    rg = _req("HEALTH_RG")
    sub = _req("AZURE_SUBSCRIPTION_ID")

    # Probe endpoints use the openai.azure.com host + /openai/v1 base (already in .env).
    params = {
        "location": args.location,
        "healthModelName": _req("HEALTH_MODEL_NAME"),
        "apimResourceId": _req("APIM_RESOURCE_ID"),
        "aoaiPrimaryResourceId": _req("AOAI_PRIMARY_RESOURCE_ID"),
        "aoaiSecondaryResourceId": _req("AOAI_SECONDARY_RESOURCE_ID"),
        "searchResourceId": _req("SEARCH_RESOURCE_ID"),
        "mcpResourceId": _req("MCP_RESOURCE_ID"),
        "logAnalyticsWorkspaceResourceId": _req("LOG_ANALYTICS_WORKSPACE_ID"),
        "aoaiPrimaryOpenAiEndpoint": _req("AOAI_PRIMARY_OPENAI"),
        "aoaiSecondaryOpenAiEndpoint": _req("AOAI_SECONDARY_OPENAI"),
        "probeModel": os.environ.get("CHAT_MODEL", "gpt-4.1-mini"),
        "deployProbe": "false" if args.no_probe else "true",
        "alertEmail": args.alert_email,
    }
    param_args: list[str] = []
    for k, v in params.items():
        param_args += [f"{k}={v}"]

    cmd = [
        "az", "deployment", "group", "create",
        "--subscription", sub,
        "-g", rg,
        "-n", "agentic-rag-health-model",
        "--template-file", str(BICEP),
        "--parameters", *param_args,
        "-o", "json",
    ]
    print("deploying health model ...")
    print(" ", " ".join(cmd[:6]), "...")
    # az is a .cmd shim on Windows -> shell=True keeps it resolvable.
    proc = subprocess.run(cmd, shell=(os.name == "nt"))
    return proc.returncode


if __name__ == "__main__":
    raise SystemExit(main())
