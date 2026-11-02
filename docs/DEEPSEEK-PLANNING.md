# Serving-recipe notes: DeepSeek (example, not the standard)

Serving recipes are **not** part of the gb10-ops setup standard: any
recipe works on a node once the standard (caps, pinned kernel,
headless, hardening, fabric) is applied and verified. These notes
record one worked example so the sizing mistakes aren't repeated.
Check numbers against the recipe checkout you actually use: recipe
READMEs and their config files have disagreed before; trust the
checkout.

## Mia AI lab DeepSeek V4.1 Flash recipes (Oct–Nov 2026)

Two distinct shapes exist; do not mix their instructions:

- **2-node recipe** (`DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks`): EAQ
  2.9 bpw EXL3 pack, TensorFold TP=2, ~99 GiB weights per node,
  requires ≥112 GiB MemAvailable per node (per its `scripts/config.sh`).
  Full official 1017 weights are ~510 GB and do not fit 2 nodes
  unquantized; the EXL3 pack is what makes TP=2 fit.
- **4-node TensorFold recipe**: runs one instance across 4 nodes. This
  is the shape a 4-node fleet used live (Nov 2, 2026, as a worked
  example; endpoint, context, and stream settings are fleet choices,
  not standard).

Lane overlays (e.g. ABLIT) are recipe-specific options with their own
gated downloads and sidecar files: enable one only as a whole lane,
per that recipe's checkout. Don't combine numbers from different
lanes.

## Serving gotcha: Hugging Face cache on NFS

`huggingface_hub` 1.27 stores its token inside `~/.cache/huggingface`
and hardens that directory to mode 700, which breaks NFS-exported
cache reads under `root_squash`. Keep credentials out of NFS-exported
trees, and keep the exported cache directory traversable (755) while
a recipe serves from it.
