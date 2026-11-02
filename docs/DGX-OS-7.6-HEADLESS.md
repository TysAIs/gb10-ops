# Headless GB10, and why you don't update to the latest kernel yet

## The headless standard

```bash
sudo systemctl set-default multi-user.target
sudo systemctl disable --now gdm3   # or your display manager
```

Verify: `systemctl get-default` → `multi-user.target`, and no display
manager running after reboot. (On DGX OS, `gdm3` is an alias for
`gdm.service`, so `systemctl is-enabled gdm3` may report `alias`; the
default target is the operative check.)

Headless also removes a known failure trigger: with the display
stack enabled on an unattended node, the `nvidia-modeset` driver can
spin a CPU at 100% indefinitely. A headless node never loads it, so
the spin cannot start. (Trigger removal, observed on fleet hardware
Oct 2026; not a guarantee against every future driver bug.)

**OS-level headless reclaims ZERO reserved RAM**, measured. Turning
off the display stack stops the desktop using RAM, but the display
carveout stays reserved until UEFI changes it.

## The real reclaim: UEFI Display Reserved Memory (optional)

Console/UEFI setup only (Esc/Del at boot), not an SSH command:

- *Display Reserved Memory* defaults to **2 GB**.
- Set it to **Auto**: with no display attached it drops to **0.5 GB**,
  roughly **1.5 GB back** per headless node.
- Verify by comparing available system memory before/after on that
  node; don't claim a fixed number for a node you haven't measured.

## Don't update to the latest kernel yet

DGX OS 7.6 ships kernel `7.0.0-1019`, which is **forbidden** in this
standard: NCCL/RoCE regression (`ibv_reg_mr_iova2` ENOMEM, GPU work
1.5–2.4x slower). Kernel `7.0.0-1024` is also forbidden (idle resets /
bootloops). The standard kernel is pinned `6.17.0-1032-nvidia` on
every node; see `docs/HARDENING.md`.

7.6's *Dynamic* Display Reserved Memory (automatic carveout shrink)
ships with that forbidden 7.6/1019 kernel. You don't need it: the
manual UEFI setting above gets the reclaim on the pinned kernel.

## Firmware (per node)

```bash
fwupdmgr get-updates
fwupdmgr update   # stages updates; a reboot activates them
```

- EC **3.13.7** fixes fans stopping in headless/appliance mode. A
  staged update ("Needs reboot") is not an applied update, verify
  versions with `fwupdmgr get-devices` after rebooting.
- **Do not reboot a serving node without explicit approval.**
- PD-controller check: in `fwupdmgr get-devices`, the USB-C PD
  controller appears as an entry named **UEFI Device Firmware** (no
  "PD" in the name; the second such entry when two are listed). It
  must not sit at factory stub `0x00000001`: a silent fwupd failure
  can leave it there. Re-running `fwupdmgr update` fixed one fleet
  unit to `0x00000519`. Always confirm the version actually changed.
  Some GB10 devices expose no PD entry to fwupd at all; then there
  is nothing to check.

## Clock caps still apply

Headless changes nothing about caps: GPU 2200 MHz
(`deploy/apply-2200.sh`) and CPU 2808 MHz (`deploy/apply-2808.sh`) on
every node, headless or not. Verify the GPU lock under load. GB10
clock reporting can still show defaults while the lock is in effect.
