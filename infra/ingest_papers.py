#!/usr/bin/env python3
"""Ingest the research papers into a Foundry IQ knowledge base (Azure AI Search).

Creates a FILE knowledge source (managed PDF extraction + chunking + embedding —
no storage account needed), uploads every PDF in ../papers, then builds a
knowledge base that plans and synthesizes cited answers with an Azure OpenAI
model. The knowledge base exposes an MCP endpoint the agent calls:

    {SEARCH_ENDPOINT}/knowledgebases/{KB}/mcp?api-version=2026-05-01-preview

Keyless: the Search service managed identity has Cognitive Services User on the
Azure OpenAI account (embeddings + synthesis). Your az-login identity needs
Search Service Contributor + Search Index Data Contributor on the Search service.

Reads config from ../.env (see .env.example).
"""
from __future__ import annotations

import os
import re
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

API = "2026-05-01-preview"
TENANT = os.environ.get("AZURE_TENANT_ID", "16b3c013-d300-468d-ac64-7eda0820b6d3")
SEARCH = os.environ["SEARCH_ENDPOINT"].rstrip("/")
AOAI = os.environ["EMBEDDING_ENDPOINT"].rstrip("/")
EMBED = os.environ.get("EMBEDDING_MODEL", "text-embedding-3-large")
MODEL = os.environ.get("CHAT_MODEL", "gpt-4.1-mini")
KS = os.environ.get("KNOWLEDGE_SOURCE", "research-papers-source")
KB = os.environ.get("KNOWLEDGE_BASE", "research-papers-kb")
PAPERS = Path(__file__).resolve().parent.parent / "papers"

tok = AzureCliCredential(tenant_id=TENANT, process_timeout=60).get_token("https://search.azure.com/.default").token
H = {"Authorization": f"Bearer {tok}"}


def main() -> int:
    # 1) File knowledge source with keyless Azure OpenAI embeddings.
    ks_body = {
        "name": KS,
        "kind": "file",
        "description": "Research papers library (uploaded PDFs) on Transformers, DeepSeek, GPT-4, and related LLM work.",
        "fileParameters": {
            "ingestionParameters": {
                "contentExtractionMode": "minimal",
                "embeddingModel": {
                    "kind": "azureOpenAI",
                    "azureOpenAIParameters": {"resourceUri": AOAI, "deploymentId": EMBED, "modelName": EMBED},
                },
            }
        },
    }
    r = httpx.put(f"{SEARCH}/knowledgesources/{KS}?api-version={API}",
                  headers={**H, "Content-Type": "application/json"}, json=ks_body, timeout=60)
    r.raise_for_status()
    print(f"knowledge source ready: {KS}")

    # 2) Upload each PDF (synchronous — extract + chunk + embed happen before it returns).
    #    Skip files already ingested cleanly; retry the embedding-rate 429s with backoff.
    existing = {}
    try:
        for f in httpx.get(f"{SEARCH}/knowledgesources/{KS}/files?api-version={API}", headers=H, timeout=60).json()["value"]:
            existing[f["fileName"]] = f.get("errorMessage")
    except Exception:
        pass

    pdfs = sorted(PAPERS.glob("*.pdf"))
    if not pdfs:
        print(f"ERROR: no PDFs in {PAPERS}", file=sys.stderr); return 1
    print(f"uploading {len(pdfs)} PDFs ...")
    for p in pdfs:
        if p.name in existing and not existing[p.name]:
            print(f"  = {p.name} already ingested — skip")
            continue
        body = p.read_bytes()
        for attempt in range(1, 7):  # embeddings on S0 rate-limit large PDFs; back off and retry
            try:
                up = httpx.post(f"{SEARCH}/knowledgesources/{KS}/files?api-version={API}",
                                headers={**H, "Content-Type": "application/octet-stream",
                                         "Content-Disposition": f'attachment; filename="{p.name}"'},
                                content=body, timeout=600)
            except httpx.HTTPError as exc:  # transient reset/read error mid-upload — retry
                print(f"  ~ {p.name} network error (attempt {attempt}): {type(exc).__name__} — retrying")
                time.sleep(10)
                continue
            if up.status_code in (200, 201):
                print(f"  - {p.name} -> {up.json().get('fileId')}")
                break
            txt = up.text
            m = re.search(r"retry after (\d+) second", txt)
            if up.status_code == 429 or "429" in txt or "TooManyRequests" in txt:
                wait = int(m.group(1)) + 5 if m else 30
                print(f"  ~ {p.name} 429 (attempt {attempt}) — waiting {wait}s")
                time.sleep(wait)
                continue
            if up.status_code >= 500 and attempt < 3:
                print(f"  ~ {p.name} {up.status_code} (attempt {attempt}) — retrying")
                time.sleep(10)
                continue
            print(f"  ! {p.name} -> {up.status_code}: {txt[:300]}", file=sys.stderr)
            break

    # 3) Confirm every file processed.
    files = httpx.get(f"{SEARCH}/knowledgesources/{KS}/files?api-version={API}", headers=H, timeout=60).json()["value"]
    for f in files:
        print(f"  ingested {f['fileName']:<50} error={f.get('errorMessage')}")

    # 4) Knowledge base — plans + synthesizes cited answers over the source.
    kb_body = {
        "name": KB,
        "description": "Research knowledge base grounded on the uploaded LLM papers.",
        "knowledgeSources": [{"name": KS}],
        "models": [{"kind": "azureOpenAI",
                    "azureOpenAIParameters": {"resourceUri": AOAI, "deploymentId": MODEL, "modelName": MODEL}}],
        "outputMode": "answerSynthesis",
        "retrievalReasoningEffort": {"kind": "low"},
        "retrievalInstructions": "Answer from the research papers. Always cite the source paper for each claim.",
    }
    r = httpx.put(f"{SEARCH}/knowledgebases/{KB}?api-version={API}",
                  headers={**H, "Content-Type": "application/json"}, json=kb_body, timeout=60)
    r.raise_for_status()
    print(f"\nknowledge base ready: {KB}")
    print(f"MCP endpoint: {SEARCH}/knowledgebases/{KB}/mcp?api-version={API}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
