# Staged apply-plan: carveout lending and headless memory (2026-11-16)

Status, 2026-11-16 19:35 MST. This was a plan; it is now applied in the
stages it describes, on the maintainer's four-node reference fleet:

- **Stage 1: applied and verified on all four nodes.**
  `vm.watermark_boost_factor` reads back `0` with a persistent drop-in on
  every node; `snapd.service` and `snapd.socket` are inactive/disabled on
  every node (one node had them disabled-but-running); `splash` is removed
  from the vendor GRUB drop-in and the regenerated `grub.cfg` on all four,
  and the live command line still carries it until the next planned boot.
- **Stage 2: applied and verified on all four nodes.** `attic.service`
  enabled+active with `NRestarts=0`; status reads `state: ready`,
  `validated: true`, `size_mib: 2044`, `lent_mib: 0` everywhere; 2816 KB
  RSS, 0.1–0.3 % CPU; no serving container was restarted.
- **Stage 3: not applied.** Unchanged from the analysis below: gated on
  serving-recipe work in another repository, with a scratch-engine test
  protocol in `docs/ENGINE-CONSUMPTION-DESIGN.md`. It is 0 usable tokens
  today.

Nothing outside stages 1 and 2 was changed: no engine, no recipe, no
container, no kernel, no firmware, no reboot. The procedure for any node
count, including the rollback, is `AGENT-APPLY.md`; this document is the
analysis and the record of what that procedure did here.

## 0. Baseline (read-only, 2026-11-16)

Captured with reads only; no privilege beyond `sudo cat` on two
world-unreadable parameters. Four columns because that is the reference
fleet, not because anything below needs four nodes: every step is per node
and the runbook (`AGENT-APPLY.md`) is identical for one node or eight.

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

## 2. Stage 1 — standard hygiene (applied 2026-11-16, all four nodes)

Each step is independent and can be dropped. What each one did on the
reference fleet is stated with it; the procedure is in `AGENT-APPLY.md`
steps 6 and 10.

**1a. `vm.watermark_boost_factor = 0`.** Writes
`/etc/sysctl.d/90-watermark-boost.conf`, `sysctl --system`, re-read the
value. Applied on all four: the drop-in is present, `sysctl --system`
exited 0, and the live value reads back `0` on every node.

What it is worth is **not measured on these nodes**, and the honest record
is that the plan's own expectation did not materialise: `MemAvailable`
moved −96/+104/−11/+78 MiB across the four, which is noise. The knob's
job is the reclaim/compaction slack for high-order bursts, not the
available-memory estimate; what removing that slack costs is the step
upstream buys back with a pre-launch defrag in its engine recipe, which we
do not ship (see `docs/MEMORY-RECLAIM.md` §3). Keep it uniform: a mixed
value makes cross-node capacity comparisons wrong.

Revert: removing the drop-in and running `sysctl --system` does **not**
restore the previous value — no stock file sets this key, so the live
kernel would keep `0` until a reboot. `deploy/apply.sh --rollback` writes
back the value it recorded before applying (`15000` on every node here),
which is the only exact inverse.

**1b. Stop the disabled-but-running `snapd`.** `systemctl stop
snapd.service snapd.socket`. Both units are disabled, so neither returns at
boot; stopping only the service is not enough where the socket is also
active, because it would socket-activate the service again. Applied on all
four; only one node actually had both units active. No reboot.

**1c. Drop `splash` and the plymouth arguments from the kernel command
line.** On DGX OS the authoritative source is not `/etc/default/grub` but
the vendor drop-in `/etc/default/grub.d/menu.cfg`; it was edited to drop
`splash`, `update-grub` regenerated the menu on all four, and the generated
`grub.cfg` now has zero `splash` occurrences. The live `/proc/cmdline`
still carries it, because no node was rebooted: this becomes true at the
next planned boot. Cosmetic; it is a GRUB edit, not a live change.

**1d. Add the largest-free-block figure to routine checks.** Done as
documentation and a read: `deploy/carveout-gate.sh` prints
`largest-free-block-mib`, and `docs/MEMORY-RECLAIM.md` §4 has the
one-liner. No change to any node.

Nothing in stage 1 requires a reboot except 1c, and 1c waits for one.

## 3. Stage 2 — the daemon alone (applied 2026-11-16, all four nodes)

This is the only step that touches a node, and it adds a daemon, not a
capability: nothing consumes the carveout until stage 3, so serving cannot
change. It was applied canary first, then the remaining nodes, each one
gated immediately before its install.

1. `bash deploy/carveout-gate.sh <node>` — printed `verdict ELIGIBLE` with
   zero `blocked` lines on every node; the only warning was `splash` still
   on the live command line, which is stage 1c.
2. Upstream's read-only preflight (`install.sh --check`) passed with the
   driver validated for heap mode.
3. Install: spark-attic 0.1.2, verified release checksum, driver
   `580.178.04` validated on the node before the unit was enabled.
4. Verified, all reads, on all four nodes: `state: ready`,
   `validated: true`, `size_mib: 2044`, `lent_mib: 0`, `clients: 0`;
   `attic.service` enabled+active, `NRestarts=0`; 2816 KB RSS and
   0.1–0.3 % CPU; the serving container was `Up 2 days` before and after
   with no restart, and the serving endpoint answered 200 at the same
   latency as before the install.
5. Soak: the daemon idles at `lent_mib 0`. It is not a soak of lending,
   because nothing has been lent.

One caveat worth carrying: `spark-attic doctor` intermittently reports
`libcuda.so.1` missing on a node where it resolves and dlopens correctly.
The cause is upstream's installer running under `set -o pipefail`, where
`ldconfig -p | grep -q` turns grep's early exit into a SIGPIPE failure.
`status.json` is the daemon's own state and is authoritative;
`deploy/apply.sh` treats a doctor failure as a warning for that reason.

Stop after stage 2 if the purpose was only to prove the gate: an installed
atticd that nobody borrows from costs a small resident daemon and nothing
else. Uninstall (§6) if even that is unwanted.

## 4. Stage 3 — engine consumption: blocked on recipe work, not on this plan

**Status: not applied anywhere. Nothing consumes the carveout today
(`lent_mib: 0` on every node).** This stage stays gated.

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
# Removing the drop-in is not enough: no stock file sets this key, so the
# live kernel keeps 0 until a reboot. Restore the recorded value explicitly.
sudo rm -f /etc/sysctl.d/90-watermark-boost.conf
sudo sysctl -w vm.watermark_boost_factor=15000      # 15000 is the stock default here

# splash (stage 1c)
# re-add it in /etc/default/grub and regenerate at the next planned boot
```

There is no kernel module to unload, no firmware setting to undo, and no
reboot anywhere in this plan except the natural one that carries a GRUB
edit.

## 7. What this plan does not do

- It does not change any node by itself: the procedure in `AGENT-APPLY.md`
  did, and §2 and §3 above are the record of that.
- It does not change the serving recipe, the model, the engine flags or
  the fabric.
- It does not claim a speed-up: upstream measured decode within noise and
  we would start from zero usable capacity anyway.
- It does not adopt the recipe-release items in `docs/MEMORY-RECLAIM.md` §3
  (defrag before launch, the load-time sponge, `TORCH_DIST_USE_NCCL2=0`).
  Those are recipe changes; they are tracked there, and the last one does
  not apply to our current torch 2.13 image.

## Credits

The optional component this plan stages is not ours:

- **spark-attic** — author **bertholomus**, source
  https://github.com/bertholomus/spark-attic, license **Apache-2.0 OR MIT**
  (`LICENSE-APACHE`, `LICENSE-MIT` upstream). Release 0.1.2 is the pinned
  installer this repo calls; nothing of it is vendored here.
- The headless-memory findings in stage 1 are **Christopher Owen
  (christopherowen)**, X article 2026-11-16, quoted with attribution in
  `docs/MEMORY-RECLAIM.md`.

Anything this repo installs, it credits in the same place it documents it.

