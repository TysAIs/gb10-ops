# The display carveout as extra CUDA memory (spark-attic), analysed 2026-11-16

An optional, gated component. It is **not** part of the setup standard: a
node that never installs it is a node that follows the standard exactly.
This repository gates it (`deploy/carveout-gate.sh`, read-only) and
installs it only as stage 2 (`deploy/apply.sh`) on a node the gate calls
ELIGIBLE.

**Status, 2026-11-16: installed and running on all four reference nodes**
(spark-attic 0.1.2, heap mode): `state: ready`, `validated: true`,
`size_mib: 2044`, `lent_mib: 0`, unit enabled+active with zero restarts,
2816 KB RSS, 0.1–0.3 % CPU, serving container not restarted. Nothing
consumes the carveout — engine consumption is stage 3 in
`docs/APPLY-PLAN-2026-11.md` and is **not applied**.

**Credits.** spark-attic is upstream work: author **bertholomus**, source
https://github.com/bertholomus/spark-attic, license **Apache-2.0 OR MIT**
(`LICENSE-APACHE` and `LICENSE-MIT` in that repository). Nothing of it is
vendored here: the installer is fetched from the pinned release.

Source: `bertholomus/spark-attic`, release 0.1.2, read 2026-11-16. All
figures in "Measured upstream" are theirs. The TensorFold and vLLM rows
were measured on an ASUS Ascent GX10 with stock DGX OS 7.6.0, kernel
`7.0.0-1024-nvidia-64k`, driver `580.178.04`, atticd in heap mode with a
node-validated shim. SGLang has **not** run on DGX OS yet: that row is an
earlier run on kernel `7.0.0-1019-nvidia-64k` on Kindling Spark OS 0.9.5,
so its speed is comparable only to its own off arm, not to the vLLM row.
Every "measured on our nodes" figure is a read-only capture on 2026-11-16.

## What it is

The NVIDIA driver sets aside about 2 GiB of a GB10's memory for a display.
On a box that drives no display, that memory sits outside the kernel's
System RAM, so `MemAvailable` never counts it and nothing can use it.
`atticd`, a small root daemon, lends it to CUDA programs in 2 MiB slices
through RM's own heap: each slice is an ordinary RM allocation exported as
a file descriptor and imported by CUDA, so RM counts every holder and a
lent slice stays out of every other allocation until the last holder lets
go — including after atticd itself dies. On driver 580.178.04 RM keeps
2 MiB of the region for itself and atticd lends the rest, 2,044 of
2,046 MiB.

Nothing here is a firmware setting, a kernel module or a kernel patch. A
process borrows, and the memory comes back when it lets go or exits. No
reboot.

It refuses to lend while a display is in use (a non-`nvidia-persistenced`
holder of `/dev/nvidia-modeset`, a graphics process, or a connected DRM
connector) and re-checks every 2 s, holding the verdict until the signals
read idle for several ticks. One limit worth knowing: it re-checks before
each new lend, not mid-lend — memory already lent stays lent until its
holder exits.

## Measured upstream

| Engine | Arm | KV pool (tokens) | Replies at temp 0 | Decode |
|---|---|---|---|---|
| TensorFold, Qwen3.8 Flash Next, bf16 KV, 262,144-token window (DGX OS, `7.0.0-1024-nvidia-64k`) | off | 224,256 | baseline | 45.6 tok/s (1 stream) |
| | attic | 293,376 (+69,120) | identical 8/8, 3/3 at temp 1.0 | 45.1 tok/s, within the two off runs |
| vLLM, Qwen3-1.7B, pinned 150,000-token budget (DGX OS, `7.0.0-1024-nvidia-64k`) | off | 150,000 | baseline | 52.2 tok/s (1 stream) |
| | kv | 168,688 (+18,688) | identical 8/8 | 51.9 tok/s |
| SGLang, same shape (Kindling Spark OS, `7.0.0-1019-nvidia-64k`) | off | 150,000 | baseline | 50.5 tok/s |
| | kv | 168,688 (+18,688) | identical 8/8 | 50.3 tok/s |

In the vLLM and SGLang runs the arms add exactly what atticd lent
(2,044 MiB); the TensorFold run put 2,032 MiB of it into keys and values.
Every speed difference sits inside the run-to-run spread of that row's own
off arms, so the honest statement is: more capacity, no decode speed change
either way. The SGLang row is a different kernel and a different host, so
it says nothing about vLLM's speed and vice versa.

Idle `MemAvailable` is unchanged by lending — the memory was never in
System RAM. (Their optional `vm.min_free_kbytes` file is a separate,
unrelated reclaim on the 64 KiB-page kernel: it sets 45,560 without
NVIDIA's transparent-hugepage rule. Our nodes read 45,166, so installing
it would move the value by 394 kB — not "nothing", though the difference
is immaterial for the reclaim it describes.)

## What applies to any GB10 owner, and what is specific

Applies to any owner:

- The mechanism is per driver, not per model: the part that talks to the
  driver is rebuilt from NVIDIA's open kernel modules at the exact tag of
  the driver the node runs, and enabled only if it passes on that node.
- It needs a headless box — which is what this standard already builds.
- It does not touch clocks, power, the kernel or the fabric.

Specific, and not to be generalised:

- The numbers are one machine, one kernel, one driver, one engine version
  per arm. The engine matrix is narrow: vLLM 0.24.0 / 0.31.0 / 0.32.0
  through the two KV-allocation shapes the plugin knows, and SGLang
  0.5.14 / 0.5.21 / 0.5.23 for the standard MHA KV pool only — its row
  excludes MLA, sliding window, Mamba, FP4 KV, memory saver, PD
  disaggregation and speculative decoding.
- Of the seven driver shims shipped, exactly one (`580.178.04`, heap
  mode) is validated on a node. The others are built, not proven.
- Tested kernels: `7.0.0-1019-nvidia-64k`, `7.0.0-1024-nvidia` and
  `7.0.0-1024-nvidia-64k` on DGX OS 7.6.0.

## Conflicts and non-conflicts with this standard

**Real conflict — the UEFI reclaim step.** `docs/DGX-OS-7.6-HEADLESS.md`
offers UEFI *Display Reserved Memory → Auto*, which drops the carveout to
0.5 GB on a headless node and hands ~1.5 GB back to System RAM, where
anything can use it. Lending needs that memory to stay reserved and gives
it to CUDA only. A node does one or the other:

| Choice | Who gets the memory | Best when |
|---|---|---|
| UEFI → Auto (~1.5 GB back) | the kernel: page cache, host processes, weights that live in System RAM | you have no engine that can place anything in the carveout |
| Leave UEFI at 2 GB, lend it | CUDA device memory, KV cache or named weights only | your engine has a supported placement |

Do not do both and expect 2 GB: with Auto set there is very little left to
lend. Pick per site, write it down, and keep it uniform across a cluster.

**Not a conflict — "headless reclaims ZERO reserved RAM".** That line in
the headless doc stays true: atticd does not return the carveout to
System RAM, it lends it to CUDA. The two statements describe different
destinations for the same memory.

**Not a conflict — modeset off.** Our standard keeps `modeset=0`, and
spark-attic is tested on exactly that. This is worth stating because the
*recipe's own* carveout path is the opposite: `spark-ds41f`'s
`SPARK_DS41F_DISPLAY_CARVEOUT_WEIGHTS` requires `modeset=Y` and refuses to
start otherwise, which is one reason this standard does not run it.

**Not a conflict — the 2200 MHz cap and the pinned kernel.** No clocks, no
power path, no kernel module. The driver shim is tied to the driver
version, not the kernel version.

**A new gate you gain for free.** After a driver update atticd lends
nothing until the new driver is built and validated on that node
(`attic-update.sh`), says why in its status file, and starts lending again
on success. That is the same fail-closed shape this repo already wants
from kernel changes.

**One lender per node.** The installer's preflight refuses to run while
another lender is listening, but it only watches the sockets named in
`ATTIC_OTHER_SOCKETS`, and that list is empty by default: out of the box
the check sees nothing, and the preflight says so in one warning line —
that is not a pass. If the node runs Kindling's `dispramd`, set the list
to `/run/dispram/dispram.sock` before installing (that is the socket
`deploy/carveout-gate.sh` watches too). Two lenders on one node would
fight over RM's heap. Our fleet has none installed (verified 2026-11-16).

## How it fails, and the asymmetry that matters

Daemon side, it fails closed. It lends nothing until the running driver
has an artifact VALIDATED for the requested mode; the installer validates
before enabling the unit, and refuses to enable it otherwise. Status is
readable without a key (`/run/spark-attic/status.json`): `state` =
`refusing`, `why` says which check failed, `size_mib` 0.

Engine side, read this before enabling a plugin: *before* it raises the KV
budget the plugin fails open — an unknown shape, no daemon, nothing free
turns the placement off with one log line and the engine runs as if the
plugin were absent. *After* it has raised the budget, it cannot fail open:
giving the carveout back would leave the engine allocating above what it
measured, so the plugin raises instead and **the engine does not come up
until it is started with `SPARK_ATTIC_PLACE=off`.**
The mitigation is upstream's own: run `attic-preflight.py` in the engine
image first, which exercises the same write the hooks do, so that a shape
mismatch is caught before a server start is spent on it.

One operational false alarm, observed on the reference fleet while
installing 0.1.2: `spark-attic doctor` occasionally reports
`libcuda.so.1 is missing` on a node where the library resolves and
dlopens correctly. The cause is upstream's `install.sh` running under
`set -o pipefail`, where `ldconfig -p | grep -q` makes grep exit early on
the first match and turns the SIGPIPE into a pipeline failure. It is a
cosmetic CLI false negative; `/run/spark-attic/status.json` is the
daemon's own state and is authoritative. `deploy/apply.sh` therefore
verifies against `status.json` and reports a doctor failure as a warning
rather than failing a healthy node.

## Verdict for our fleet (2026-11-16)

Gate: `bash deploy/carveout-gate.sh <node>` — read-only, no install, no
privilege, prints one key/value line per check.

| Check | Result on all four nodes |
|---|---|
| aarch64, GB10 present | yes |
| kernel | `7.0.0-1019-nvidia-64k` — inside upstream's tested matrix |
| driver | `580.178.04` — the one node-validated driver, heap mode |
| headless (no display manager, no modeset holder, `modeset=N`) | yes |
| another lender | none |
| verdict | **ELIGIBLE** (one warning: `splash` still on the command line) |

So the *daemon* would lend on our nodes today. Upstream's tested kernel
matrix covers our kernel, and our driver is the single validated one —
better than the premise this analysis started from (DGX OS 7.2.3 /
kernel 6.17.0-1032), which the fleet left behind when it moved to the
7.0.0-1019-64k baseline. The remaining variable is DGX OS *userland*
version (upstream tested 7.6.0); our nodes run Ubuntu 24.04.x either way,
and atticd reads only `/proc`, `/sys` and the NVIDIA device nodes.

What that does **not** buy: our serving stack cannot take the memory yet.
The live engine is vLLM 0.29.1rc1.dev187 with a custom TILELANG attention
backend, MLA KV and dspark speculative decoding — outside the engine
matrix above (0.24/0.31/0.32, standard MHA, no speculative decoding) and
outside anything upstream source-checked. Its `allocate_kv_cache`
signature does match the 0.32 shape, which is the dangerous middle:
the plugin would recognise enough to raise the budget and then hit the
loud path if the placement does not hold. And the container has no
attic socket or key mounted at all, so the plugin cannot reach the daemon
until the recipe changes.

See `docs/APPLY-PLAN-2026-11.md` for the staged plan, the arithmetic of
what 2 GiB per node would be worth to that serving shape, and the
rollback.
