#!/usr/bin/env python3
"""Configure the Agentic RAG APIM gateway as a load balancer over two Azure OpenAI
regions (Responses API). Idempotent — re-running updates in place.

- Enables the APIM system-assigned managed identity and grants it Cognitive
  Services User on both Azure OpenAI accounts (keyless upstream).
- Creates two circuit-breaker backends + a load-balanced pool (primary priority 1,
  secondary priority 2) + the responses-ha API + wildcard operations + the policy.
- Creates a subscription and prints its key.

Uses ARM over httpx (az rest PUT/PATCH can hang behind the proxy here). Reads config
from environment / .env; see .env.example.

Client base URL after this runs:  https://<apim>.azure-api.net/responses-ha/openai/v1
POST {base}/responses  with header  Ocp-Apim-Subscription-Key: <printed key>
"""
from __future__ import annotations

import os
import sys
import time
from pathlib import Path

import httpx
from azure.identity import AzureCliCredential

try:
    from dotenv import load_dotenv
    load_dotenv(Path(__file__).resolve().parent.parent / ".env")
except Exception:
    pass

TENANT = os.environ.get("AZURE_TENANT_ID", "16b3c013-d300-468d-ac64-7eda0820b6d3")
SUB = os.environ["AZURE_SUBSCRIPTION_ID"]
RG = os.environ.get("HEALTH_RG", "healthmodels")
APIM = os.environ.get("APIM_NAME", "agrag-gateway")
API = "agrag-responses-ha"
API_PATH = "responses-ha"
SUBID = "agrag-responses-ha-sub"
POOL = "agrag-responses-pool"
B_PRIMARY = "aoai-primary"
B_SECONDARY = "aoai-secondary"
PRIMARY_URL = os.environ.get("AOAI_PRIMARY_AISVC", "https://agrag-aoai-eastus2.services.ai.azure.com")
SECONDARY_URL = os.environ.get("AOAI_SECONDARY_AISVC", "https://agrag-aoai-westus.services.ai.azure.com")
PRIMARY_ACC = PRIMARY_URL.split("//", 1)[1].split(".", 1)[0]
SECONDARY_ACC = SECONDARY_URL.split("//", 1)[1].split(".", 1)[0]
POLICY_PATH = Path(__file__).with_name("responses-ha.policy.xml")

# Cognitive Services User — lets the APIM MI call the AOAI data plane keylessly.
COG_USER_ROLE = "a97b65f3-24c7-4388-baec-2e87135dc908"

GA = "2024-05-01"
PREVIEW = "2024-06-01-preview"
MGMT = "https://management.azure.com"
BASE = f"{MGMT}/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.ApiManagement/service/{APIM}"

cred = AzureCliCredential(tenant_id=TENANT, process_timeout=60)
H = {"Authorization": f"Bearer {cred.get_token('https://management.azure.com/.default').token}",
     "Content-Type": "application/json"}


def put(url, body, label):
    r = httpx.put(url, headers=H, json=body, timeout=120)
    ok = r.status_code < 400
    print(f"{'OK ' if ok else 'ERR'} {label}: {r.status_code}" + ("" if ok else f"  {r.text[:400]}"))
    if not ok:
        sys.exit(1)
    return r


def acct_id(name):
    return f"/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.CognitiveServices/accounts/{name}"


def breaker():
    return {"rules": [{
        "name": "respBreaker",
        "failureCondition": {
            "count": 1, "interval": "PT30S",
            "statusCodeRanges": [{"min": 429, "max": 429}, {"min": 500, "max": 504}],
            "errorReasons": ["Timeout", "BackendConnectionFailure"],
        },
        "tripDuration": "PT1M", "acceptRetryAfter": True,
    }]}


# 0) Enable APIM system-assigned identity and read its principalId.
r = httpx.patch(f"{BASE}?api-version={GA}", headers=H, json={"identity": {"type": "SystemAssigned"}}, timeout=120)
print("APIM identity PATCH:", r.status_code)
pid = None
for _ in range(20):
    g = httpx.get(f"{BASE}?api-version={GA}", headers=H, timeout=60).json()
    pid = (g.get("identity") or {}).get("principalId")
    if pid:
        break
    time.sleep(5)
if not pid:
    print("ERR: APIM managed identity principalId not available"); sys.exit(1)
print("APIM MI principalId:", pid)

# 1) Grant the APIM MI Cognitive Services User on both AOAI accounts.
import uuid
for acc in (PRIMARY_ACC, SECONDARY_ACC):
    ra_id = str(uuid.uuid4())
    url = f"{MGMT}{acct_id(acc)}/providers/Microsoft.Authorization/roleAssignments/{ra_id}?api-version=2022-04-01"
    body = {"properties": {
        "roleDefinitionId": f"/subscriptions/{SUB}/providers/Microsoft.Authorization/roleDefinitions/{COG_USER_ROLE}",
        "principalId": pid, "principalType": "ServicePrincipal"}}
    rr = httpx.put(url, headers=H, json=body, timeout=120)
    print(f"role assign {acc}: {rr.status_code}" + ("" if rr.status_code < 400 or rr.status_code == 409 else f" {rr.text[:200]}"))

# 2) Retry named value.
put(f"{BASE}/namedValues/agrag-openai-retrycount?api-version={GA}",
    {"properties": {"displayName": "agrag-openai-retrycount", "value": "2", "secret": False}},
    "namedValue agrag-openai-retrycount")

# 3) Circuit-breaker backends + pool.
put(f"{BASE}/backends/{B_PRIMARY}?api-version={PREVIEW}",
    {"properties": {"url": PRIMARY_URL, "protocol": "http", "circuitBreaker": breaker()}}, f"backend {B_PRIMARY}")
put(f"{BASE}/backends/{B_SECONDARY}?api-version={PREVIEW}",
    {"properties": {"url": SECONDARY_URL, "protocol": "http", "circuitBreaker": breaker()}}, f"backend {B_SECONDARY}")
put(f"{BASE}/backends/{POOL}?api-version={PREVIEW}",
    {"properties": {"description": "Responses HA pool primary(1)->secondary(2).", "type": "Pool",
                    "pool": {"services": [
                        {"id": f"{BASE}/backends/{B_PRIMARY}", "priority": 1, "weight": 1},
                        {"id": f"{BASE}/backends/{B_SECONDARY}", "priority": 2, "weight": 1}]}}}, f"pool {POOL}")

# 4) API + wildcard operations.
put(f"{BASE}/apis/{API}?api-version={GA}",
    {"properties": {"displayName": "Agentic RAG Responses API - HA",
                    "description": "HA gateway for the Azure OpenAI Responses API over a load-balanced pool.",
                    "path": API_PATH, "protocols": ["https"], "subscriptionRequired": True,
                    "subscriptionKeyParameterNames": {"header": "Ocp-Apim-Subscription-Key", "query": "subscription-key"}}},
    f"api {API}")
for op_id, method, name in [("post-any", "POST", "POST"), ("get-any", "GET", "GET"), ("del-any", "DELETE", "DELETE")]:
    put(f"{BASE}/apis/{API}/operations/{op_id}?api-version={GA}",
        {"properties": {"displayName": name, "method": method, "urlTemplate": "/*"}}, f"operation {op_id}")

# 5) API policy.
put(f"{BASE}/apis/{API}/policies/policy?api-version={GA}",
    {"properties": {"format": "rawxml", "value": POLICY_PATH.read_text(encoding="utf-8")}}, "api policy")

# 6) Subscription + key.
put(f"{BASE}/subscriptions/{SUBID}?api-version={GA}",
    {"properties": {"displayName": "Agentic RAG Responses HA subscription",
                    "scope": f"{BASE}/apis/{API}", "state": "active"}}, f"subscription {SUBID}")
r = httpx.post(f"{BASE}/subscriptions/{SUBID}/listSecrets?api-version={GA}", headers=H, timeout=120)
if r.status_code < 300:
    print("APIM_SUBSCRIPTION_KEY=" + r.json()["primaryKey"])
print("APIM_CONFIGURE_DONE")
