# DGX OS 7.6.0 and Headless Mode (Oct 2026)

## Current known-good baseline
- DGX OS **7.6.0**, kernel 7.0.0-1019, UEFI 1.111.17, EC **3.13.7**,
  SoC **2.158.15**, USB PD 0.5.25 (Founders Edition only; partner systems may lag).
- Serving pair caution (Oct 2026): the 7.0 kernel line was previously flagged
  for NCCL/memory regressions on the serving pair. Do not move a working
  serving node off its known-good kernel (6.17.0-1032-nvidia) without an
  explicit decision per node. Kernel choice is per-node, not repo-wide.

## Dynamic Display Reserved Memory — the headless RAM reclaim
DGX OS 7.6 (October 2026) adds **Dynamic Display Reserved Memory**, a UEFI
option that automatically shrinks the display carveout to its **512 MB
minimum when no display is connected**.
- This is the headless RAM reclaim: roughly **2-4 GB back** versus a loaded
  desktop, depending on the prior carveout.
- It is a **UEFI setting, not an SSH command** — it must be set per node in
  BIOS/UEFI, with no display attached to get the minimum carveout.
- Prerequisite for the related headless fan fix: EC 3.13.7 + SoC 2.158.15
  via `fwupdmgr`. Being on DGX OS 7.6.0 alone does not install that firmware.
- Verify after: check available system memory before/after, and confirm
  the display carveout in UEFI. Do not claim a fixed GB number for a node
  you have not measured.

## EC / firmware update path (per node)
```bash
# On the Spark, check staged/available firmware first
fwupdmgr get-updates
fwupdmgr update   # stages EC update; a reboot activates it
```
- **Do not reboot a serving node without explicit approval.** A staged
  update (Update State: Needs reboot) is not an applied update.
- October headless-fan fix: EC 3.13.7 fixes fans stopping in
  headless/appliance mode, paired with SoC 2.158.15.

## Clock cap still applies
Headless mode does not replace the clock cap. Apply **2200 MHz**
(`./deploy/apply-2200.sh`) on every Spark, headless or not, and verify
with the `nvidia-smi -lgc 0,2200` result — not with Applications Clocks
alone, which can still show a 2418 MHz default on GB10.
