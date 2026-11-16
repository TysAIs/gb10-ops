# Staged apply-plan: carveout lending and headless memory (2026-11-16)

Status: **plan only. Nothing in this document has been applied to any
node.** No config change, no install, no restart, no engine action. The
nodes are read-only territory until the owner of the cluster says go,
stage by stage. Analysis behind this plan: `docs/DISPLAY-CARVEOUT.md` and
`docs/MEMORY-RECLAIM.md`.

## 0. Baseline (read-only, 2026-11-16)

Captured with reads only; no privilege beyond `sudo cat` on two
world-unreadable parameters.

| | node 1 | node 2 | node 3 | node 4 |
|---|---|---|---|---|
| kernel | 7.0.0-1019-nvidia-64k | same | same | same |
| page size | 65536 | 65536 | 65536 | 65536 |
| driver | 580.178.04 | same | same | same |
| modeset | N | N | N | N |
| default target | multi-user.target | same | same | same |
| MemAvailable while serving | 17.6 GiB | 20.3 GiB | 20.1 GiB | 20.2 GiB |
| largest free block | 128 MiB | 512 MiB | 256 MiB | 512 MiB |
| `vm.watermark_boost_factor` | 15000 | 15000 | 15000 | 15000 |
| `vm.min_free_kbytes` | 45166 | 45166 | 45166 | 45166 |
| carveout gate verdict | ELIGIBLE | ELIGIBLE | ELIGIBLE | ELIGIBLE |

The plan this analysis was asked for assumed DGX OS 7.2.3 with kernel
6.17.0-1032. That is no longer the fleet: all four nodes have been on the
qualified `7.0.0-1019-nvidia-64k` baseline since Nov 2026, which is inside
spark-attic's tested kernel matrix, and they run the one driver upstream
validated. The compatibility question therefore moved from "kernel" to
"engine", which is where the verdict below lands.

## 1. What would have to be true for atticd to lend here

All six hold on all four nodes today:

1. aarch64 GB10, systemd, driver loaded.
2. Driver has a shim built for its exact tag **and** that shim passed the
   node check — `580.178.04`, heap mode, the only combination upstream
   has proven.
3. Kernel inside the tested matrix — `7.0.0-1019-nvidia-64k` is.
4. No display in use: no display manager, nothing but
   `nvidia-persistenced` holding `/dev/nvidia-modeset`, `modeset=N`.
5. No other carveout lender on the node — none installed.
6. The installer's own preflight passes (disk, key, socket, arch).

If any of 2–4 stops holding the answer is "lends nothing", not "lends
something wrong": atticd only lends on a VALIDATED artifact for the
running driver, the installer refuses to enable the unit when validation
fails, and `/run/spark-attic/status.json` then reads `state: refusing`
with the reason in `why`. The one thing that is *not* fail-closed is the
engine plugin after it has raised the KV budget (§4, risk R1).

## 2. Stage 1 — standard hygiene (reversible; serving impact unmeasured on our nodes)

Each step is independent and can be dropped.

**1a. `vm.watermark_boost_factor = 0`.** Write
`/etc/sysctl.d/90-watermark-boost.conf`, `sysctl --system`, re-read
`MemAvailable` on the canary node. Expected: more reported available
memory, no other change. What it costs is **not measured on our nodes**:
the boost exists so a burst of high-order allocations has slack, and
upstream buys that slack back with a pre-launch defrag in its engine
recipe — a step we do not ship (see `docs/MEMORY-RECLAIM.md` §3). Gate:
canary node only, and if it shows no difference and no regression over
24 h of serving, apply to the other three the same day — uniform or not
at all, because a mixed value makes cross-node capacity comparisons
wrong. Revert: delete the file, `sysctl --system` (or reboot).

**1b. Stop the disabled-but-running `snapd`** on the node where it is
enabled=disabled, active=running: `systemctl stop snapd.service
snapd.socket`. Both units are disabled, so neither comes back at boot;
stopping only the service is not enough, because on that node
`snapd.socket` is also active and would socket-activate the service
again. No reboot.

**1c. Drop `splash` and the plymouth arguments** from the kernel command
line at the next planned boot (a GRUB edit, per `docs/HARDENING.md`).
Cosmetic; do it with the next kernel-default change rather than as its
own reboot.

**1d. Add the largest-free-block figure to routine checks.** Use
`deploy/carveout-gate.sh` (read-only) or the one-liner in
`docs/MEMORY-RECLAIM.md` §4. No change to the node.

Nothing in stage 1 requires a reboot except 1c, and 1c can wait for one.

## 3. Stage 2 — the daemon alone, on one canary node

This is the only step that touches a node, and it adds a daemon, not a
capability: nothing consumes the carveout until stage 3, so serving cannot
change.

1. `bash deploy/carveout-gate.sh <canary>` — must print `verdict ELIGIBLE`
   and no `blocked` line.
2. `curl -fsSL https://github.com/bertholomus/spark-attic/releases/download/v0.1.2/install.sh | sudo bash -s -- --check`
   — upstream's read-only preflight; writes nothing.
3. Install with the same command without `--check`. The installer verifies
   the release checksum, validates the running driver on the node, and
   enables the unit only if that passed.
4. Verify, all reads:
   - `spark-attic status` — `state: ready`, `size_mib: 2044`,
     `validated: true`, `driver: 580.178.04`.
   - `cat /run/spark-attic/status.json` — `lent_mib: 0` (nothing has
     borrowed).
   - `spark-attic doctor` — exit 0.
   - serving still answers on its endpoint, unchanged.
5. Soak 24–48 h: daemon CPU near zero, RSS small, `lent_mib` still 0,
   no `refusing` transition, serving metrics unchanged.

Stop here if the purpose was only to prove the gate: an installed atticd
that nobody borrows from costs a small resident daemon and nothing else.
Uninstall (§6) if even that is unwanted.

## 4. Stage 3 — engine consumption: blocked on recipe work, not on this plan

**Do not do this stage as an experiment on the serving cluster.** It needs
changes to the serving recipe, which is a different repository and a
different owner, and it needs a scheduled window.

Why it is blocked today:

- The live engine is vLLM 0.29.1rc1.dev187 (`af1c01499`) with a custom
  TILELANG attention backend, MLA KV and dspark speculative decoding.
  spark-attic's plugins are proven on vLLM 0.24.0 / 0.31.0 / 0.32.0 for the
  standard MHA KV pool and explicitly excluding speculative decoding.
- The engine's `allocate_kv_cache(kv_cache_config, device, layout,
  kernel_block_sizes)` signature does match the shape upstream calls
  0.32, and its `KVCacheTensor` carries the fields that shape reads. That
  is exactly the risky state: the plugin would recognise enough to raise
  the KV budget and then, on a placement failure it cannot undo, refuse to
  start — so a trial costs a container that will not come up until it is
  restarted with `SPARK_ATTIC_PLACE=off`.
- The serving container mounts neither `/run/spark-attic` nor the key, so
  the plugin cannot reach the daemon at all until the recipe adds the
  mounts and the Python package.
- The recipe already has its own carveout path
  (`SPARK_DS41F_DISPLAY_CARVEOUT_WEIGHTS`), which is TP3-only and requires
  `modeset=Y`. This cluster runs TP4 ring with it at `0`. Adding a second,
  incompatible carveout consumer to the same node is the "one lender"
  problem in a different costume — settle which mechanism the recipe
  standardises on before enabling either.

Prerequisites if it is ever scheduled: upstream's `attic-preflight.py`
run inside the recipe image (it exercises the same write the hooks do);
a scratch single-node engine — not the 4-node serving stack — started with
`SPARK_ATTIC_PLACE=kv`, its startup log showing the
`+2044 MiB display carveout` line and a larger KV pool; identical weights
and prompt set with `SPARK_ATTIC_PLACE=off` compared at temperature 0; and
a window the cluster owner has agreed to.

### What the memory would be worth, arithmetically

From the live engine's own startup log (2026-11-15, unchanged since):

- KV budget per node: `kv_cache_memory_bytes` = 11,274,289,152 B = 10.5 GiB.
- KV capacity: 11,547,894 tokens; 976.3 bytes per token per node;
  `max_model_len` 1,048,576; `max_num_seqs` 32.
- Concurrency ceiling at full 1M-token requests: 11.01×.

If 2 GiB of carveout per node were usable on all four nodes, the pool
would become 10.5 + 2 = 12.5 GiB per node:

| | today | with +2 GiB/node, uniform |
|---|---|---|
| KV budget per node | 10.5 GiB | 12.5 GiB |
| KV capacity | 11,547,894 tokens | 13,747,493 tokens (+2,199,599, +19.0%) |
| 1M-token requests in flight | 11.01× | 13.11× |

Three honest riders on that table:

- **It only counts if it is uniform.** A tensor-parallel group sizes one KV
  pool for every rank; extra capacity on one node is not capacity the group
  can use. Partial deployment gains nothing, which is why stage 2 is a
  single node but stage 3 is all-or-nothing.
- **It is headroom, not throughput.** Observed KV occupancy under real
  traffic is 0.5–5.6% of the pool. Nothing about decode speed, TTFT or
  prefix-cache behaviour changes; the gain is the ceiling on long-context
  concurrency, which matters on the day 12 requests each want a
  million-token window and not before.
- **It is not reachable today.** Until stage 3 clears, the honest expected
  gain of this plan is 0 tokens.

## 5. Risks

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| R1 | An engine that raised its KV budget then fails to place it will not start, and needs a restart with `SPARK_ATTIC_PLACE=off` | high on a serving node | preflight in the image first; scratch engine before the cluster; the failure is loud, not silent |
| R2 | The RM heap interface is not a stable ABI. A shim that passes validation but misreads a structure could corrupt memory | high, low probability | upstream builds per driver tag with warnings as errors and validates by writing/reading whole slices on the node; we never build our own |
| R3 | A driver update silently stops lending (by design) | low, capacity only | atticd says so in `status.json`; re-run `attic-update.sh` after a driver change; add a status read to node checks |
| R4 | Someone sets UEFI Display Reserved Memory to Auto later, shrinking the carveout under the lender | medium | `docs/DISPLAY-CARVEOUT.md`: pick one path per site, write it down, keep it uniform |
| R5 | A second carveout consumer appears (recipe's TP3 path, `dispramd`) | medium | one lender per node; the gate blocks on a second lender socket |
| R6 | A root daemon is added to a serving node | low | upstream unit is sandboxed (no new privileges, read-only filesystem, AF_UNIX only); root is required by the RM client and is documented |
| R7 | Expectations run ahead of capability: memory an engine cannot use | medium | stage 3 states the 0-token default; capacity arithmetic is in this doc so nobody quotes 19% as if it were throughput |

Not a risk: host memory pressure. The carveout was never in System RAM, so
lending cannot change `MemAvailable` or host OOM behaviour.

## 6. Rollback

Every step is reversible without a reboot and without a firmware or kernel
change:

```bash
# engine (stage 3): start it without the carveout
SPARK_ATTIC_PLACE=off            # then restart the engine

# daemon (stage 2)
sudo systemctl disable --now attic.service
sudo spark-attic uninstall       # keeps the key and logs; --purge removes them
# memory a live process still holds returns when that process exits

# watermark boost (stage 1a)
sudo rm /etc/sysctl.d/90-watermark-boost.conf && sudo sysctl --system

# splash (stage 1c)
# re-add it in /etc/default/grub and regenerate at the next planned boot
```

There is no kernel module to unload, no firmware setting to undo, and no
reboot anywhere in this plan except the natural one that carries a GRUB
edit.

## 7. What this plan does not do

- It does not change any node by itself.
- It does not change the serving recipe, the model, the engine flags or
  the fabric.
- It does not claim a speed-up: upstream measured decode within noise and
  we would start from zero usable capacity anyway.
- It does not adopt the recipe-release items in `docs/MEMORY-RECLAIM.md` §3
  (defrag before launch, the load-time sponge, `TORCH_DIST_USE_NCCL2=0`).
  Those are recipe changes; they are tracked there, and the last one does
  not apply to our current torch 2.13 image.
