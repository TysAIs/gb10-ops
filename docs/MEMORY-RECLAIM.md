# Headless memory: what the Nov 2026 field report changes (2026-11-16)

Source: Christopher Owen, "If you're running headless anyway, recover the
memory and reduce the memory fragmentation", X article, published
2026-11-16 04:06 MST. He runs four GB10 nodes as one inference cluster and
reports what his team turned off, plus the memory-fragmentation work in
their next serving release. Numbers below are his unless a row says they
were measured on our nodes.

This page exists because two of the article's items are setup-standard
material for any GB10 owner, and the rest is serving-recipe material that
this repo documents but does not implement. Read it as: what we already
do, what we should add, and what deliberately stays out.

## 1. What this standard already does

Verified read-only on our four nodes on 2026-11-16 (`deploy/carveout-gate.sh`
and plain reads; no changes made).

| Article item | Our state |
|---|---|
| Boot to `multi-user.target`, no display manager | `systemctl get-default` = `multi-user.target`; `gdm` inactive on all four |
| Disable `dgx-dashboard`, `dgx-dashboard-admin` | disabled/inactive on all four |
| Disable `snapd` (and socket/seeded/repair timer) | disabled; inactive on all four since 2026-11-16 (one node was disabled-but-running until both units were stopped) |
| Disable `cups`, `cups-browsed` | masked on all four |
| Disable `bluetooth` | disabled or masked on all four |
| Disable `fwupd-refresh.timer` | disabled/inactive on all four |
| Keep `fwupd` installed (EC/UEFI/ConnectX-7/NVMe firmware) | installed; `fwupd.service` active |
| Display modeset off | `modeset` = `N`, OEM override package present on all four |

So the service-slimming list is not a change for us: `docs/DGX-OS-7.6-HEADLESS.md`
has required it since the headless standard was written. One small drift
is worth closing (that disabled-but-running `snapd`), but it is not a
memory finding.

The article's framing is still useful for a reader deciding whether to go
headless: on unified memory a desktop session competes directly with the
weights, and on a 1M-token prefill his head node sits within about 3 GiB
of its guard. Same arithmetic on a GB10 whose model already holds most of
the pool.

## 2. What is worth adopting

### `vm.watermark_boost_factor = 0` (adopt as standard)

The kernel's default lets a watermark boost hide memory that
`MemAvailable` would otherwise count: Owen measures "up to 0.87 GiB". Our
nodes read `15000` (the default) on all four, so we are carrying that
hidden margin today.

```
# /etc/sysctl.d/90-watermark-boost.conf
vm.watermark_boost_factor = 0
```

```
sudo sysctl --system
sysctl vm.watermark_boost_factor      # expect 0
```

Cost: the boost exists so that a burst of high-order allocations has
slack. Upstream buys that slack back with a pre-launch defrag in its
engine recipe, but that defrag is §3 work we do not ship today, so the
slack is simply gone until someone measures what it was worth.
Reversible, and the revert is not "delete the file": no stock file sets
this key, so removing the drop-in leaves the live value where it was —
`deploy/apply.sh --rollback` restores the value it recorded before
applying.

**Status: applied on the reference fleet 2026-11-16.** The drop-in is
present on all four nodes, `sysctl --system` exited 0, and the live value
reads back `0` everywhere. The article's motivation was that the boost
hides memory; what the four nodes actually showed is that
`MemAvailable` did not move beyond noise (−96/+104/−11/+78 MiB), because
the knob governs reclaim slack for high-order bursts rather than the
available-memory estimate. The benefit remains **unmeasured**, and the
cost is unmeasured too. Verify with
`sysctl -n vm.watermark_boost_factor` (expect `0`); keep it uniform,
because a mixed value is a cross-node difference in reported available
memory, which is exactly what makes capacity conversations go wrong.

### Drop `splash` from the kernel command line (adopt as cleanup)

Every one of the reference nodes carried `quiet splash
plymouth.ignore-serial-consoles plymouth.use-simpledrm` in
`/proc/cmdline`. On a node nobody plugs a monitor into, that is a
framebuffer setup for an audience of nobody, and it hides boot text from
the one console that matters (`ttyS0`).

**Status: staged 2026-11-16, not yet in effect.** On DGX OS the
authoritative file is the vendor drop-in `/etc/default/grub.d/menu.cfg`,
not `/etc/default/grub`; `splash` was removed there and `update-grub`
regenerated the menu on all four nodes, whose generated `grub.cfg` now has
zero `splash` occurrences. The live `/proc/cmdline` still carries it until
the next planned boot, because this standard does not reboot nodes. Verify
after that boot with `grep -c splash /proc/cmdline` (expect `0`). Cosmetic
hygiene, not a memory claim.

### `buddyinfo` as a first-class check (adopt into verification)

`free -h` says how much memory is free. It does not say what shape it is
in, and on unified memory the GPU can only use large physically
contiguous blocks. `/proc/buddyinfo` is the shape.

Measured on our fleet on 2026-11-16, with the serving stack up (each node
holding ~89 GiB of model memory):

| Node | MemAvailable | Largest free block |
|---|---|---|
| node 1 | 17.6 GiB | 128 MiB |
| node 2 | 20.3 GiB | 512 MiB |
| node 3 | 20.1 GiB | 256 MiB |
| node 4 | 20.2 GiB | 512 MiB |

The largest contiguous block is 0.5–4% of the free memory on every node.
That is the same shape Owen reports (18.5 GiB free, largest block 256 MiB
on his node), and it is the reason a launch that needs a big contiguous
window can fail on a node that "has plenty of free memory". Report the
largest block, not just the total, whenever you reason about whether a
model will fit. `deploy/carveout-gate.sh` prints it.

### Not adopted: removing GNOME packages

The article's nodes have no GNOME installed at all. Ours still carry the
desktop metapackages (14 `gnome-shell`/`gnome-session`/`ubuntu-desktop`
entries on a spot-checked node). Purging them is an `apt` change against
DGX OS packaging on a serving node, and it buys disk, not RAM: a stopped
desktop's packages are not resident. Left as a site choice, not a
standard step.

## 3. What belongs to the serving recipe

These are the article's own next-release items. They are `spark-ds41f`
(our serving recipe) work, not setup work: this repo documents them and
does not reimplement them.

| Item | Number from the article | Where it belongs |
|---|---|---|
| Defrag before launch: `sync; echo 3 > drop_caches; echo 1 > compact_memory` with the engine stopped | free memory in blocks of 2 MiB or more went from ~25 GiB to ~80 GiB on a stopped node; "most of what a reboot buys you" | recipe launcher, on by default with an off switch |
| A load-time "sponge" that holds the small blocks so weights land in whole large blocks | with the defrag and cache-aware hot-thread placement, boot-to-boot spread in step time fell 0.76% → 0.06% across eight single-node boots; 44/44 cluster boots clean | recipe loader |
| `TORCH_DIST_USE_NCCL2=0` | 0.9 GiB of the 1.42 GiB a torch upgrade had cost, on torch 2.16 | recipe image — **not applicable to us today**: our engine runs torch 2.13.0+cu130, whose process-group code already creates communicators lazily. Re-test only if the image moves to 2.16+ |
| Host-heap trimming (mimalloc) | 748 of 768 MiB synthetic, 66 MiB in real serving, +77 s boot → rejected upstream | out of scope |

The defrag line is the one an owner can run today, with the engine
stopped, on any node. It is a recipe-startup action, so it stays out of
this standard's scripts: running it under a live engine would drop the
page cache out from under a serving model.

## 4. Verify

```bash
sysctl vm.watermark_boost_factor                       # 0 after the step
grep -c splash /proc/cmdline                           # 0 after the next boot
awk '{n=$0; sub(/^Node[ ]+[0-9]+, zone[ ]+[A-Za-z0-9_]+[ ]+/,"",n); \
      k=split(n,c,/[ ]+/); top=-1; \
      for(i=1;i<=k;i++) if(c[i]+0>0) top=i-1; \
      if(top>=0) printf "%s largest block %d MiB\n", $0, (2^top)*$(getconf PAGESIZE)/1048576}' \
    /proc/buddyinfo
```

The same largest-block figure is reported by
`bash deploy/carveout-gate.sh <node>` (read-only), beside the carveout
checks.

## Sources

- Christopher Owen, X article "If you're running headless anyway, recover
  the memory and reduce the memory fragmentation", 2026-11-16 04:06 MST.
  Figures quoted above: 850 MiB dashboard update-check peak, 0.87 GiB
  hidden by the watermark boost, 1.69 GiB recovered from 512 MiB-block
  weight steering plus one 19,586-allocation arena, compaction ≤1.5 GiB
  with step time unmoved, ~30 running services per node, and the
  next-release items in §3.
- Our fleet: read-only capture, 2026-11-16, all four nodes.
