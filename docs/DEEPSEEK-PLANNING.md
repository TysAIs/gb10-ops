# DeepSeek Planning — gated on quad verification

**Do not start this until the quad verification checklist in
docs/QUAD-STACK.md passes for all 4 nodes.**

## Mia AI lab full-weights recipe (research only, Oct 2026)
- Recipe: `MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks`
  (EAQ 2.9 bpw, TensorFold TP=2). This is **not** the BLACKFOLD lane from
  the earlier A/B test, and **not** the ABLIT overlay (leave `ABLIT=0`;
  ABLIT=1 pulls a gated overlay the stock numbers do not cover).
- It is a **2-Spark** recipe, not a 4-node recipe: ~99 GiB weights per
  Spark, requires >=112 GiB MemAvailable per node (checkout
  `scripts/config.sh`; README says 109 — trust the checkout file).
- Full official 1017 weights are ~510 GB and do not fit on 2 Sparks
  unquantized; the 2.9 bpw EXL3 pack is what makes TP=2 fit.
- For a 4-node quad, this recipe as-is would be two TP=2 pairs behind
  one endpoint, or a separate 4-node plan. That decision comes **after**
  the quad verification gate passes. No weights are downloaded here.
