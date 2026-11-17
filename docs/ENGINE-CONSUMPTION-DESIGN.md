# Consuming the carveout from the serving engine: feasibility, test protocol, go/no-go

Design and research only, 2026-11-16. **Nothing in this document has been run
against a node.** No recipe, image, container, driver or engine setting was
changed to write it; every command below is for a later, separately authorised
run. The SPARKS invariant is absolute: the four GB10 nodes, their serving
container and the `spark-ds41f` recipe are untouched.

This note answers the question left open by `docs/DISPLAY-CARVEOUT.md` and
`docs/APPLY-PLAN-2026-11.md`: what would it actually take for our serving
engine to use spark-attic's lent carveout as KV cache, what would prove it,
and what is it worth.

Short answer: the engine is closer to compatible than its version number
suggests — its KV allocation matches the shape the plugin knows, function for
function — but the gain is capacity we do not currently use (0.5–5.6 % of the
pool), the closest measurement on this hardware is a 4–11 % throughput loss,
and one class of failure wedges the engine until it is restarted with the
plugin off. It is worth a scratch test, not a production enablement.

## 1. The engine, precisely

The version matrix is the wrong first question. spark-attic's vLLM support is
stated per release (0.24.0, 0.31.0, 0.32.0), but the plugin never compares
versions: it inspects the live engine's functions and dataclasses at run time
and turns itself off if it does not recognise them. What matters is whether our
engine has a shape it knows.

What is running (read-only, 2026-11-16):

| Fact | Value | Source |
|---|---|---|
| Container image | `spark-ds41f:candidate-55`, running, `RestartCount=0` | `docker inspect` on the head node |
| Base image | `vllm/vllm-openai:nightly-af1c01499…` (= vLLM 0.29.1rc1.dev187) | image label `ai.vllm.image.tag` |
| vLLM source | local-inference-lab `integration/karmic-kraken-beta` `19f2c20e`, patch head `d6d4319e`, tree `8aaae3df` | image labels |
| CUDA | 13.5.37 | image label |
| Recipe checkout | `8ac8b465` (2026-11-14, local), `config/cluster.json` modified locally | `git log`/`git status` on the head node |
| KV budget | 11,274,289,152 B (10.5 GiB) per rank, explicit `--kv-cache-memory-bytes` | live engine startup log |
| KV capacity | 11,547,894 tokens per rank (976.3 B/token), `max_model_len` 1,048,576, `max_num_seqs` 32 | live engine startup log |
| Attention | TILELANG backend for every serving kernel, sparse MLA KV, dspark speculative decoding (5 drafts) | recipe's own active-settings record |

So: not upstream vLLM, a 641-patch integration branch, a custom TileLang
attention backend, MLA rather than MHA, and speculative decoding — the last
three explicitly outside spark-attic's tested matrix.

## 2. Static check against the deployed source

I read the exact revision the image labels name (`19f2c20e`) and compared what
the plugin wraps with what is there. This is a source check, not a run; it
proves the code shape, nothing more.

| What the plugin needs | What the engine has | Result |
|---|---|---|
| `vllm.v1.worker.gpu_worker.Worker.determine_available_memory(self)` | `gpu_worker.py:631`, one parameter | match |
| `Worker.load_model(self, *, load_dummy_weights=False)` | `gpu_worker.py:542`, same parameter list | match |
| `model_loader.utils.initialize_model(vllm_config, *, prefix, model_class, model_config)` | same four parameters | match |
| `vllm.v1.worker.utils.allocate_kv_cache(kv_cache_config, device, layout, kernel_block_sizes=None)` | `utils.py:389`, exactly that signature — the shape the plugin calls "0.32" | match |
| `KVCacheTensor` fields `{size, layers, layer_stride, block_stride, offset, host_resident}` | `kv_cache_interface.py:1506`, exactly that set | match |
| No host-resident KV group (the plugin refuses those after raising the budget) | no code path in the pinned tree sets `host_resident=True`; the field is only read | cannot fire |
| All KV tensors share one backing allocation | the engine asserts it (`utils.py:405`) | precondition satisfied |
| The backing is one `torch.zeros(buf_size, dtype=torch.int8, device)` | exactly that call (`utils.py:421`) | the interception target exists |
| The runner's module-level binding is the wrapped function | `gpu_model_runner.py` imports `allocate_kv_cache` from `.utils` at module scope | the routing test has something to find |

Two things follow that are not obvious and that matter to the recipe:

1. **The pinned KV budget does not block the plugin.** With
   `--kv-cache-memory-bytes` set, the worker returns that number and skips
   profiling. The plugin wraps that function and returns the number *plus* what
   atticd lent; engine core sizes the pool from the return value
   (`v1/engine/core.py:319`). So the carveout becomes capacity *above* the pin,
   and the pin keeps its meaning as "device memory".
2. **Partial deployment buys nothing, by the engine's own code.** The
   KV-cache config builder sets every worker's block count to the smallest
   among all workers (`v1/core/kv_cache_utils.py:3079`, step 5). If atticd
   lends on three nodes and not the fourth, the pool stays at today's size and
   the three carveouts are handed back unused. Four nodes or none.

What static checking cannot settle — the two runtime facts that decide this:

- **Import order.** The routing test passes only if, inside each worker
  process, `gpu_model_runner` binds the *wrapped* `allocate_kv_cache`. Workers
  load general plugins in `WorkerWrapper.init_worker`
  (`v1/worker/worker_base.py:350`), which runs before the model runner is
  constructed — the right order — but only a run shows it. If it is wrong, the
  plugin turns itself off with one log line and the engine is unaffected.
- **The interception.** Whether the engine's `torch.zeros` is the first one
  inside the wrapped call and exactly the size the plugin computed. It is in
  the base revision; the deployed tree is patched (`d6d4319e` vs the `19f2c20e`
  I read). A grep over the 641-patch series finds no patch that changes the
  parameter lists of the four wrapped functions, allocates the KV cache another
  way, or adds host-resident groups — but that is a grep, not a run, and the
  patched tree is only proved by the in-image preflight (§4.5).

## 3. How this fails, in order of what it costs

1. **Fail-open before the budget is raised** — no atticd, nothing free, a
   shape the plugin does not know, a stale binding, an unknown `KVCacheTensor`
   field, sleep mode, a KV connector. One log line
   (`spark-attic: KV placement off: …`), the engine runs exactly as it does
   today. This is the common case and it is safe.
2. **Loud after the budget is raised** — the shape is recognised (so the budget
   grew by 2,044 MiB per rank) and the placement then fails. By design there is
   no fallback: giving the memory back would leave the engine allocating more
   than it measured. The engine does not come up until it is restarted with
   `SPARK_ATTIC_PLACE=off`. The log line is explicit:
   `… not falling back: the KV budget was already raised …`. This is the one
   failure that costs a serving outage instead of a log line, and the reason
   for a scratch run before any cluster run.
3. **Capacity asymmetry** — covered above: silent zero gain, no error.
4. **Throughput** — measured analogue on the same silicon is a 4–11 % loss
   (§5, §7); that is a cost, not a failure, but it decides the trade.
5. **Two consumers of one carveout** — enabling the recipe's own
   `SPARK_DS41F_DISPLAY_CARVEOUT_WEIGHTS` path in the same profile would give
   the 2 GiB two owners. One lender per node is the rule; pick one mechanism.

## 4. Required recipe changes

None of these is in place today, and none is made by this note. They are listed
against the file or function that would have to change, so the owner can judge
the size of the work.

**4.1 Daemon on all four nodes.** Covered by the gated install in
`docs/APPLY-PLAN-2026-11.md` stage 2, not by this repo. Required on every rank,
because of the min-across-workers rule above.

**4.2 Image: ship the client.** spark-attic 0.1.3's `python/` directory carries
the package *and* its `.dist-info` with the
`vllm.general_plugins = spark_attic.vllm_plugin:register` entry point, so no
`pip install` is needed: copy it verbatim into the image (pinned release,
sha256 verified) and put it in front of the image's existing `PYTHONPATH`.
That is a recipe build-stage change. It changes no engine code.

**4.3 Container binds: `/run/spark-attic` and `/etc/spark-attic/key:ro`.**
These have to be declared in `config/cluster.json`'s `container.mounts`, not
added with an ad-hoc `docker -v`: the recipe's `doctor` compares the live
container's `HostConfig.Binds` with the profile exactly
(`spark_ds41f/config.py`: `expected_binds` / `mount_problems`), so an
undeclared mount reads as drift, and it would not survive the next start
anyway. The serving container already mounts `/dev/dri/card0` for the recipe's
own carveout path; that is harmless while the path is off, but see 4.9.

**4.4 Environment, per shape.** `SPARK_ATTIC_PLACE=kv` (the arm) or `off` (the
control), `SPARK_ATTIC_KEY_FILE=/etc/spark-attic/key`, and the `PYTHONPATH`
prefix. The recipe has a test that only `NCCL_*`,
`SPARKNET_ROCE_ALLGATHER_MAX_BYTES` and `SPARK_DS41F_DISPLAY_CARVEOUT_WEIGHTS`
may differ between shapes
(`tests/test_recipe.py::test_only_the_cabling_and_memory_differ_between_shapes`),
so that allowlist has to be extended for a per-shape knob. Putting the knob in
the base environment instead would apply it to `tp3-triangle`, whose own
carveout path must remain the only consumer.

**4.5 Start gate: run `attic-preflight.py vllm` inside the image, per rank,
before the server.** It borrows and round-trips 64 MiB, checks the entry point
is visible, and checks the four functions' parameter lists and
`KVCacheTensor`'s fields in the patched tree — the check that §2 cannot do from
outside. Non-zero exit ⇒ do not start the arm. This is the cheapest step in the
whole plan and the only one that tests what is actually shipped.

**4.6 Post-start assertion.** Require both placement log lines:
`spark-attic: KV cache memory … = vLLM's … + N MiB display carveout` and
`spark-attic: the KV cache backing (…) holds … MiB of display carveout …`.
Either missing ⇒ the arm failed: stop it and start the control. The plugin's
own lines are the only evidence that the placement, not just the budget,
happened.

**4.7 Supervisor confinement.** If the container exits with the over-budget
line (§3.2), retry once with `SPARK_ATTIC_PLACE=off` automatically, then page.
The message is deterministic and greppable; without this, a failed experiment
becomes an outage that waits for a human.

**4.8 Doctor.** Add: `status.json` readable with `state: ready`,
`validated: true`, `size_mib > 0`, `pages: "2MB pages"`; key present and
root-only; socket present; no second lender; and the mutual exclusion in 4.9.
The recipe already has the machinery (`doctor.py` checks + fix lines).

**4.9 Modeset stays N, and the recipe's own carveout path stays off.** atticd
wants no display in use, which is our standard. `SPARK_DS41F_DISPLAY_CARVEOUT_WEIGHTS=1`
wants `modeset=Y` and would hold its own carveout allocation. They are
alternatives, not layers.

**4.10 UEFI Display Reserved Memory stays at 2 GB on all four nodes.** "Auto"
shrinks the reservation and is mutually exclusive with lending, as
`docs/DISPLAY-CARVEOUT.md` already says. Uniform across the group.

## 5. The recipe's own carveout path (TP3-only), weighed

It exists, it is not a KV path, and it is not available to our shape.

- **What it is.** Patches 0021/0026/0030: a DRM dumb buffer from the firmware
  scanout reserve, exported as a dma-buf and imported with
  `cuImportExternalMemory`, holds the embedding table and the packed output
  head — 842.5 MiB per rank, two 43,136 × 5,120 BF16 tables — freeing ~934–950
  MiB of ordinary memory per rank. The worker *refuses to start* if the
  carve-out cannot hold the weights, and the path requires `modeset=Y`.
- **Where it is enabled.** `tp3-triangle` only (`=1`). Our `tp4-ring` keeps it
  at `0`, by measurement: in the carve-out the output head lost its L2 reuse —
  2.22 ms per call against 1.73 ms in regular memory — and on sixteen streams
  the working combination is token tiles fastest with the head in regular
  memory. The carve-out mapping streams at full speed but gives no reuse, so
  only read-once tables are acceptable there.
- **What it proved, twice.** The KV variant of the same path was built and
  rejected: +42 % KV capacity, quality gate 5/5, but 8-stream decode −4 to
  −11 %, prefill −7.5 to −11 %, and its first start failed because two small
  temporary KV caches (0.2 MiB and 7.4 MiB) each took a 16 MiB carve-out slice
  and left too little for the serving pool. The weights variant passed
  acceptance: KV 575,304 → 904,074 tokens on three nodes, decode and prefill
  within noise.
- **What it means here.** Turning it on for our fleet is not a configuration
  change: it needs a three-node re-cable and `modeset=Y`, and it would still be
  the same 2 GiB. It is a worse option than installing a daemon, and it cannot
  coexist with atticd.
- **The one variant worth noting.** attic's *weights* placement would reach the
  same 842.5 MiB without `modeset=Y` and on any TP size — but with the engine's
  explicit KV budget the freed device memory does not become KV capacity by
  itself; the pin would have to be raised by ~842.5 MiB per rank deliberately
  (≈ +904,864 tokens, +7.8 %). Smaller gain, smaller blast radius, no mode
  change, no new failure path in the KV allocator.

## 6. Scratch protocol that never touches the serving cluster

**The honest constraint first.** All four GB10 nodes are ranks of the serving
TP4 group; there is no spare node. The recipe has no single-node shape (its
smallest is `tp3-triangle`), and the model does not fit on one node (weights
alone are tens of GiB per rank at TP4; the full checkpoint is far past a single
node's unified memory). Therefore a single node cannot run the serving shape at
all. What it *can* do is settle every question that does not need the model,
which is most of them.

Every step below is for a GB10 that is not one of the four, or for an hour of a
node the owner has explicitly released. No command here touches
`spark-ds41f`, its container, or any serving endpoint.

**S0 — static, no hardware (already done, re-runnable).**
The checks in §2, from raw source at the revision the image labels name. Cost:
minutes. It already says "shape recognised"; it cannot say "routing works".

**S1 — daemon on the scratch node, read-only first.**
`bash deploy/carveout-gate.sh <node>` must print `verdict ELIGIBLE`; then the
upstream installer's `--check`, then the install. Evidence:
`cat /run/spark-attic/status.json` → `state: ready`, `validated: true`,
`driver: 580.178.04`, `size_mib: 2044`, `pages: "2MB pages"`, `lent_mib: 0`.

**S2 — the image's own preflight, no engine.**
Start the recipe image on the scratch node with the two binds and the
`PYTHONPATH` prefix, and run `attic-preflight.py vllm` inside it. Pass
condition: exit 0, and the line naming the shape (`the plugin picks vLLM shape
0.32`), plus the 64 MiB borrow, the tensor round-trip and the glued-range
round-trip all `PASS`. This is the highest-value fifteen minutes in the plan:
it is the only check that runs against the patched tree inside the shipped
image.

**S3 — plumbing arm with a small model, same image.**
Serve a small model (Qwen3-1.7B-class, which the image can load) twice on the
scratch node, back to back on one boot, same pinned KV budget:

```sh
# control
SPARK_ATTIC_PLACE=off vllm serve <small-model> --kv-cache-memory-bytes <pin> ...
# arm
SPARK_ATTIC_PLACE=kv  vllm serve <small-model> --kv-cache-memory-bytes <pin> ...
```

Evidence to keep, per arm: the startup lines (KV tokens, and for the arm both
placement lines), `status.json` before/during/after, 8 fixed prompts at
temperature 0 compared byte for byte, 1 stream and 8 streams decode, and the
absence of the over-budget line. Expected: pool grows by what atticd lent
(2,044 MiB of capacity); replies identical; decode within the two control
runs' spread.

**S4 — rollback drill.** Stop the arm, restart with `SPARK_ATTIC_PLACE=off`,
confirm the pool is back to the pin, `lent_mib` returns to 0, and the service
answers. Repeat once with the daemon stopped, to see the fail-open line (no
daemon ⇒ one log line, engine unaffected).

**S5 — what a scratch cluster would add.** Everything above is one node. The
remaining questions — MLA + dspark + TILELANG under real traffic, sixteen
streams, per-rank symmetry at 10.5 GiB per rank, block-boundary arithmetic on
the production pin — need the serving shape, i.e. three or four nodes. That is
a production-window experiment, not a scratch test, and it is not part of this
note.

## 7. Exact go/no-go evidence

| Gate | Observable | Pass | Fail action |
|---|---|---|---|
| G0 static shape | §2 table, re-run against the image's revision | every wrapped signature and `KVCacheTensor` field matches | stop: version drift, re-read the plugin |
| G1 daemon | `status.json` | `ready`, `validated`, `size_mib 2044`, `pages "2MB pages"` | stop; do not install if refusing |
| G2 in-image preflight | `attic-preflight.py vllm` exit code | 0, all PASS, shape named | stop: the patched tree is not the shape the plugin knows |
| G3 arm start | engine log | both placement lines, no `not falling back` line | arm failed: start the control, file the log |
| G4 capacity | engine startup line, per rank | KV tokens = baseline + lent bytes / bytes-per-token, within one block (512 tokens) | treat as failure: the placement did not take |
| G5 semantics | fixed prompts at temperature 0 | byte-identical to the control | stop: this is a correctness regression, not a capacity trade |
| G6 performance | decode at 8 and 16 streams, prefill 32K/64K | inside the control's own run-to-run spread (±1.5 % decode, ±3 % prefill) | no-go: a capacity-only gain that costs throughput at 0.5–5.6 % occupancy is not worth it |
| G7 occupancy trigger | 7-day peak KV occupancy on the live service | > 40 %, or a documented workload needing > 11 concurrent 1M-token contexts | keep the daemon installed but unused; revisit quarterly |
| G8 rollback | restart with `SPARK_ATTIC_PLACE=off` | pool back to the pin, `lent_mib 0`, service answers | do not proceed until the rollback drill passes |

G0–G2 are cheap and decide whether a run is worth anything at all. G3–G6 only
run on the serving shape and therefore only in a window the owner has agreed
to. G7 is the decision that actually matters: it is the gate that says whether
the capacity is worth having.

## 8. What it is worth, honestly

The arithmetic, from the live engine's own startup log:

| | today | +2,044 MiB per rank, on all four |
|---|---|---|
| KV budget per rank | 10.5 GiB | 12.5 GiB |
| KV capacity | 11,547,894 tokens | 13,743,197 tokens (+2,195,303, +19.0 %) |
| full 1M-token requests in flight | 11.01 | 13.11 |

Observed KV occupancy under real traffic is **0.5–5.6 % of the pool**. The
service does not run out of KV cache; it has an order of magnitude of it spare.
A 19 % increase in a ceiling that is 94–99.5 % unused is not throughput, not
latency, and not a user-visible improvement — it is insurance for a day when a
dozen requests each want a million-token window at once.

Against that, the only measurement of this exact mechanism on this exact
hardware is the recipe's rejected KV arm: the same 2 GiB region, the same
model, +42 % capacity, and 8-stream decode −4 to −11 %, prefill −7.5 to −11 %,
with single-stream unchanged. spark-attic's own vLLM numbers are gentler
(decode within 1.3 % on a small model at 8 streams, and 0.1.3 explicitly asks
RM for GPU-cacheable blocks), so the truth is somewhere between "no cost" and
"−11 %", and only a run settles it. But the decision does not need that
precision: at today's occupancy, a capacity-only gain that costs even 2 %
throughput is a bad trade.

**Recommendation: no-go for production enablement now.** Keep the daemon
optional and uninstalled by default (as this repo already has it), record the
protocol above, and re-open when G7 fires. If the fleet ever needs a small,
safe increment instead, the weights arm (+842.5 MiB, +7.8 % capacity, read-once
tables, measured neutral) is the cheaper experiment.

## 9. Open questions for the recipe owner

- Does the recipe intend to standardise on its own DRM carveout path, or to
  accept spark-attic as the lender? One node, one mechanism.
- Is a per-shape `SPARK_ATTIC_PLACE` acceptable, or should the env contract
  change shape instead (a profile-level "carveout consumer" field)?
- Is an automatic single retry with `SPARK_ATTIC_PLACE=off` acceptable to the
  supervisor design, or should a failed arm always wait for a human?

## 10. What this note does not do

- It does not touch a node, a container, the recipe or the engine.
- It does not claim the placement works: it claims the shape matches and names
  the two runtime facts a run must settle.
- It does not re-audit spark-attic itself. The figures for upstream behaviour
  are from release 0.1.3 (current today); this repo's gate script was written
  against 0.1.2 and is being read against 0.1.3 on another card.
- It does not turn the 19 % capacity figure into a performance claim. It is
  headroom, and at 0.5–5.6 % occupancy it is headroom we do not need.
