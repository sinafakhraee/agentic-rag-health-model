# Research papers (knowledge base source)

The demo grounds its answers in the research papers below. **The PDFs are not
redistributed in this repository** — each paper keeps its own copyright and license, and
three of the five are under the arXiv *non‑exclusive* license, which grants distribution
rights to arXiv only (not to third parties). So you **download them yourself** into this
folder before running `infra/ingest_papers.py` (which ingests every `*.pdf` here).

## Papers, sources, and licenses

| Paper | Authors | Source | License |
|---|---|---|---|
| Attention Is All You Need | Vaswani et al. | [arXiv:1706.03762](https://arxiv.org/abs/1706.03762) · [PDF](https://arxiv.org/pdf/1706.03762) | [arXiv non‑exclusive](http://arxiv.org/licenses/nonexclusive-distrib/1.0/) |
| GPT‑4 Technical Report | OpenAI (Achiam et al.) | [arXiv:2303.08774](https://arxiv.org/abs/2303.08774) · [PDF](https://arxiv.org/pdf/2303.08774) | [arXiv non‑exclusive](http://arxiv.org/licenses/nonexclusive-distrib/1.0/) |
| Mapping the Increasing Use of LLMs in Scientific Papers | Liang et al. | [arXiv:2404.01268](https://arxiv.org/abs/2404.01268) · [PDF](https://arxiv.org/pdf/2404.01268) | [CC BY‑NC‑ND 4.0](https://creativecommons.org/licenses/by-nc-nd/4.0/) |
| DeepSeek‑V3 Technical Report | DeepSeek‑AI | [arXiv:2412.19437](https://arxiv.org/abs/2412.19437) · [PDF](https://arxiv.org/pdf/2412.19437) | [arXiv non‑exclusive](http://arxiv.org/licenses/nonexclusive-distrib/1.0/) |
| Hierarchical Reasoning Model | Wang et al. | [arXiv:2506.21734](https://arxiv.org/abs/2506.21734) · [PDF](https://arxiv.org/pdf/2506.21734) | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |

Attribution and reuse are governed by each paper's license above. Under the arXiv
non‑exclusive license, redistributing the PDF is not permitted — link to arXiv instead.
CC BY‑NC‑ND 4.0 permits verbatim, non‑commercial redistribution with attribution and **no
derivatives**; CC BY 4.0 permits redistribution and derivatives with attribution.

> The GPT‑4 report (`2303.08774`) is large and currently fails managed ingestion; the demo
> runs fine on the other four. It's listed for completeness — downloading it is optional.

## Download (PowerShell)

```powershell
$ids = '1706.03762','2303.08774','2404.01268','2412.19437','2506.21734'
foreach ($id in $ids) {
  Invoke-WebRequest "https://arxiv.org/pdf/$id" -OutFile "$id.pdf"
}
```

## Download (bash)

```bash
for id in 1706.03762 2303.08774 2404.01268 2412.19437 2506.21734; do
  curl -L "https://arxiv.org/pdf/$id" -o "$id.pdf"
done
```

Then run `python infra/ingest_papers.py` from the repo root.
