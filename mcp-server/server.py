"""Scholarly-papers MCP server (Semantic Scholar Academic Graph).

Exposes the Semantic Scholar Academic Graph as MCP tools: paper search, paper
metadata, references (papers this one cites), citations (papers that cite this
one), related-paper recommendations, author search, and an author's papers. The
agentic RAG assistant uses these tools to cross-check and expand on the answers
it grounds in the knowledge base.

Runs over stdio by default, or Streamable-HTTP when MCP_TRANSPORT=http
(for Azure Container Apps). Set SEMANTIC_SCHOLAR_API_KEY for higher rate limits.
"""
import os
import time
import threading
import httpx
from mcp.server.fastmcp import FastMCP

# json_response=True keeps tool calls fast for Foundry agents; do NOT use
# stateless_http (it forces a full MCP handshake on every call).
mcp = FastMCP("Scholarly Papers MCP", json_response=True)

GRAPH = "https://api.semanticscholar.org/graph/v1"
REC = "https://api.semanticscholar.org/recommendations/v1"
API_KEY = os.environ.get("SEMANTIC_SCHOLAR_API_KEY", "").strip()
print(f"[startup] Semantic Scholar API key: {'set' if API_KEY else 'NOT set'}", flush=True)

SEARCH_FIELDS = "title,year,venue,citationCount,externalIds,url,authors"
PAPER_FIELDS = ("title,year,venue,abstract,citationCount,influentialCitationCount,"
                "referenceCount,externalIds,url,openAccessPdf,authors,tldr")
REF_FIELDS = "title,year,externalIds,url,citationCount,authors"

# Semantic Scholar's search endpoints are slow (504) and rate-limited (~1 req/sec
# even with a key). Fail fast and self-throttle so a slow upstream never hangs the
# agent: short timeout, few attempts, and a clean {"error": ...} on failure.
_TIMEOUT = 12.0
_ATTEMPTS = 2
_MIN_INTERVAL = 1.2
_last = [0.0]
_lock = threading.Lock()


def _headers():
    h = {"Accept": "application/json"}
    if API_KEY:
        h["x-api-key"] = API_KEY
    return h


def _throttle():
    with _lock:
        gap = _MIN_INTERVAL - (time.monotonic() - _last[0])
        if gap > 0:
            time.sleep(gap)
        _last[0] = time.monotonic()


def _get(url: str, params: dict | None = None) -> dict:
    """GET a Semantic Scholar endpoint. Self-throttles to ~1 req/sec, fails fast,
    and returns parsed JSON or a clean {"error": ...} without ever hanging."""
    last = {"error": "Semantic Scholar request failed."}
    for _ in range(_ATTEMPTS):
        _throttle()
        try:
            r = httpx.get(url, params=params, headers=_headers(), timeout=_TIMEOUT, follow_redirects=True)
        except Exception as e:
            last = {"error": f"Semantic Scholar is slow/unreachable ({type(e).__name__}). Try again shortly."}
            continue
        if r.status_code == 200:
            try:
                return r.json()
            except Exception as e:
                return {"error": f"invalid JSON from Semantic Scholar: {e}"}
        if r.status_code in (429, 500, 502, 503, 504):
            last = {"error": f"Semantic Scholar is temporarily rate-limited or slow (HTTP {r.status_code}). Try again in a moment."}
            continue
        return {"error": f"Semantic Scholar HTTP {r.status_code}: {r.text[:160]}"}
    return last


def _clip(n: int, hi: int) -> int:
    try:
        n = int(n)
    except (TypeError, ValueError):
        n = 10
    return max(1, min(n, hi))


@mcp.tool()
def search_papers(query: str, limit: int = 10) -> dict:
    """Search Semantic Scholar for papers by keyword or title.

    Returns papers with title, year, venue, citation count, links (url, arXiv id),
    and authors. If the relevance-search endpoint is degraded (504/429), falls back
    to a best-title-match lookup so "find '<paper title>'" queries still resolve.
    """
    data = _get(f"{GRAPH}/paper/search",
                {"query": query, "limit": _clip(limit, 20), "fields": SEARCH_FIELDS})
    if "error" not in data and data.get("data"):
        return {"total": data.get("total"), "results": data.get("data", [])}
    m = _get(f"{GRAPH}/paper/search/match", {"query": query, "fields": SEARCH_FIELDS})
    if "error" not in m and m.get("data"):
        return {"total": len(m["data"]), "results": m["data"],
                "note": "Best title match (relevance search was unavailable)."}
    return data if "error" in data else m


@mcp.tool()
def get_paper(paper_id: str) -> dict:
    """Get one paper's details from Semantic Scholar.

    `paper_id` may be a Semantic Scholar id, `arXiv:1706.03762`, `DOI:10.xxxx`,
    `CorpusId:12345`, or a paper URL.
    """
    return _get(f"{GRAPH}/paper/{paper_id}", {"fields": PAPER_FIELDS})


@mcp.tool()
def get_paper_references(paper_id: str, limit: int = 25) -> dict:
    """List the papers a given paper CITES (its references), with titles, years, and links."""
    data = _get(f"{GRAPH}/paper/{paper_id}/references",
                {"limit": _clip(limit, 50), "fields": REF_FIELDS})
    if "error" in data:
        return data
    return {"data": [d.get("citedPaper", d) for d in data.get("data", [])]}


@mcp.tool()
def get_paper_citations(paper_id: str, limit: int = 25) -> dict:
    """List papers that CITE a given paper, with titles, years, and links."""
    data = _get(f"{GRAPH}/paper/{paper_id}/citations",
                {"limit": _clip(limit, 50), "fields": REF_FIELDS})
    if "error" in data:
        return data
    return {"data": [d.get("citingPaper", d) for d in data.get("data", [])]}


@mcp.tool()
def get_paper_recommendations(paper_id: str, limit: int = 10) -> dict:
    """Recommend related papers for a given paper id (great for literature discovery)."""
    return _get(f"{REC}/papers/forpaper/{paper_id}",
                {"limit": _clip(limit, 20), "fields": PAPER_FIELDS})


@mcp.tool()
def search_authors(query: str, limit: int = 10) -> dict:
    """Search Semantic Scholar for authors by name (returns name, affiliations, paperCount, hIndex)."""
    data = _get(f"{GRAPH}/author/search",
                {"query": query, "limit": _clip(limit, 20),
                 "fields": "name,affiliations,paperCount,citationCount,hIndex,url"})
    if "error" in data:
        return data
    return {"total": data.get("total"), "results": data.get("data", [])}


@mcp.tool()
def get_author_papers(author_id: str, limit: int = 25) -> dict:
    """List papers by a given Semantic Scholar author id."""
    data = _get(f"{GRAPH}/author/{author_id}/papers",
                {"limit": _clip(limit, 50), "fields": PAPER_FIELDS})
    if "error" in data:
        return data
    return {"data": data.get("data", [])}


@mcp.tool()
def health() -> dict:
    """Lightweight liveness probe used by the health-model canary."""
    return {"status": "ok"}


if __name__ == "__main__":
    transport = os.environ.get("MCP_TRANSPORT", "stdio").strip().lower()
    if transport in ("http", "streamable-http", "streamable_http"):
        mcp.settings.host = os.environ.get("MCP_HTTP_HOST", "0.0.0.0")
        mcp.settings.port = int(os.environ.get("MCP_HTTP_PORT", "3000"))
        try:
            mcp.settings.streamable_http_path = os.environ.get("MCP_HTTP_PATH", "/mcp")
        except Exception:
            pass
        # Behind Container Apps ingress the Host header is the public FQDN, so disable
        # the MCP SDK's DNS-rebinding (Host/Origin) protection to avoid HTTP 421.
        try:
            from mcp.server.transport_security import TransportSecuritySettings
            mcp.settings.transport_security = TransportSecuritySettings(
                enable_dns_rebinding_protection=False,
            )
        except Exception:
            pass
        mcp.run(transport="streamable-http")
    else:
        mcp.run()
