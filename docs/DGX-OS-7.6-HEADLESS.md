# Headless GB10 on DGX OS 7.6

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

## Kernel on 7.6: the -64k qualified baseline

DGX OS 7.6's qualified kernel for this standard is
`7.0.0-1019-nvidia-64k` (64 KiB pages), deployed uniformly and
verified per node in Nov 2026; `6.17.0-1032-nvidia` stays installed
as the rollback. `7.0.0-1024` remains forbidden (idle resets /
bootloops, unqualified). The full policy, including why the old
4 KiB 1019 warnings no longer gate the -64k variant, is in
`docs/HARDENING.md`.

7.6's *Dynamic* Display Reserved Memory (automatic carveout shrink)
is a 7.6 feature; the manual UEFI setting above gets the same
reclaim without depending on it.

## Firmware (per node)

```bash
fwupdmgr get-updates
fwupdmgr update   # stages updates; a reboot activates them
```

- Track the EC firmware version with `fwupdmgr get-devices`. A
  staged update ("Needs reboot") is not an applied update; verify
  versions after rebooting.
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
