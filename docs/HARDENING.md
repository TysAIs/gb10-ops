# GB10 node hardening and kernel policy

Apply identically on every GB10 node. Verify after each step.

## Kernel: the 7.0.0-1019-nvidia-64k qualified baseline (Nov 2026)

The standard kernel is `7.0.0-1019-nvidia-64k` on DGX OS 7.6, on ALL
nodes: 64 KiB pages (`getconf PAGESIZE` = 65536), driver 580.178.04,
`kho=off` on the command line as shipped by DGX OS packaging. This is
the qualified baseline for the current serving profile: it was
deployed as a uniform set and verified per node (kernel, page size,
swap, caps, fabric) in Nov 2026.

- `6.17.0-1032-nvidia` stays installed on every node as the
  known-good rollback. Kernel rollback = re-pin the GRUB default to
  its explicit entry and reboot; nothing else changes.
- Do **NOT** take `7.0.0-1024`: idle resets, freezes, and bootloops
  reported, and it carries no qualification. Never boot it.
- Historical note: the stock `7.0.0-1019` 4 KiB kernel carried
  NCCL/RoCE regression reports (`ibv_reg_mr_iova2` ENOMEM) in Sep
  2026, which is why this standard pinned 6.17 through Oct 2026. The
  qualified path is the -64k variant; the pin lifted only for it,
  only as a uniform deployment.
- **All nodes in a cluster run the same kernel, page size, and
  memory-saver state.** A cross-node mismatch is an error state.
- Never install `doca-ofed` or the dkms MFT package (`kernel-mft-dkms`):
  it shadows the inbox mlx5 driver and breaks the ConnectX-7.
- Install the qualified set (exact pinned packages) and pin the boot
  default explicitly:

```bash
uname -r        # expect 7.0.0-1019-nvidia-64k
getconf PAGESIZE  # expect 65536
# Boot default: the explicit -64k entry, never "saved". Do not hand-edit;
# the script writes /etc/default/grub and regenerates grub.cfg safely.
bash deploy/apply-grub-default.sh <node1> [<node2> ...]
```

(The old apt-mark holds on the 6.17.0-1032 packages are obsolete as a
policy: 1032 is retained as an installed fallback, not defended
against updates.)

## Memory saver state

The serving profile's qualified baseline includes a UVM leaf-packing
memory saver (`uvm_pack_sysmem_leaf_tables=Y`). DGX OS 7.6 ships no
OEM saver — the stock 580 driver's UVM has no such parameter — so the
implementation is the serving recipe's own DKMS module
(`dgx-spark-memory-saver`), signed with a locally generated MOK key
(a node's own key, generated on that node) and enrolled at a console
reboot. Enrollment is a physical console step by design; there is no
SSH path and none should be improvised. Whatever state a site runs,
it must be identical on every node.

## Display modeset

Modeset stays OFF via the OEM override package
`nvidia-drm-options-modeset0` (`options nvidia-drm modeset=0` in
`/etc/modprobe.d/zz-nvidia-drm-override.conf`, which sorts after and
overrides the stock `modeset=1`). Keep the package; do not purge it.
See README "Display driver modeset".

## Boot default: an explicit entry, never `saved`

`GRUB_DEFAULT` must name the target kernel entry explicitly on every
node:

```
GRUB_DEFAULT="Advanced options for DGX OS GNU/Linux>DGX OS GNU/Linux, with Linux 7.0.0-1019-nvidia-64k"
```

Never leave `GRUB_DEFAULT=saved`. With `saved`, the real boot target
lives in `/boot/grub/grubenv` (`saved_entry=`), so one `grub-set-default`,
one `grub-reboot`, or one maintainer script changes which kernel a node
boots while `/etc/default/grub` still looks correct. An explicit string
is declarative: it is greppable, diffable across the fleet, and it
cannot drift behind your back. `GRUB_SAVEDEFAULT` should likewise stay
unset.

Apply and verify with the deploy script (idempotent, config-only, no
reboot; `--check` is read-only and needs no privilege):

```bash
bash deploy/apply-grub-default.sh --check node1 node2   # expect "verdict ALIGNED"
bash deploy/apply-grub-default.sh node1 node2           # writes /etc/default/grub, regenerates grub.cfg
```

It refuses to touch anything unless the target kernel image is present,
the generated menu really contains that entry, and `grub-script-check`
accepts the result. It regenerates into a root-owned temp file and only
then installs it, so a failed `grub-mkconfig` can never leave a
truncated `grub.cfg` on a node whose `GRUB_TIMEOUT=0` gives you no menu
to recover from. The new default takes effect at the next natural boot,
so serving is never interrupted by the change.

Verification is two reads, and the second is the one people skip:

```bash
grep GRUB_DEFAULT /etc/default/grub
sudo grep -E '^\s*set default=' /boot/grub/grub.cfg | grep -v next_entry
```

The `grep -v next_entry` matters: `grub.cfg` also contains
`set default="${next_entry}"` for the one-shot `grub-reboot` override.
That is not the persistent default, and reading it as one makes a
correct node look wrong.

Two traps cost real time here:

- `fs.protected_regular` (set by default) stops root from
  O_CREAT-truncating a file another user created in a sticky `/tmp`, so
  `sudo grub-mkconfig -o /tmp/x` dies with `cannot create /tmp/x:
  Permission denied` even though it is running as root. Create the temp
  file as root, or keep it outside `/tmp`.
- `sudo` is passwordless on some nodes and not on others. A non-root
  `--check` still proves the `/etc/default/grub` half; cross-checking
  `grub.cfg` (mode 600 root) needs privilege. Report which half you
  actually read instead of implying both.


## CVE-2026-98432 mitigations (the makeshift protections)

CVE-2026-98432 is a remote code execution bug in IPv4 TCP option
handling. It is **unpatched on every GB10 kernel**, and the 6.17 line
is end-of-life, so no kernel update fixes it today. Until a future
kernel carries the fix, configuration mitigations are the answer.
Apply them identically on every node, on any kernel. GB10 nodes
should be LAN/tailnet-only (not internet-exposed), so treat this as
cheap insurance, not an emergency.

Three pieces, each doing a different job:

| Mitigation | What it blocks | What it costs you |
|---|---|---|
| nftables drop of LSRR/SSRR IP options | The CVE's vulnerable path: TCP packets carrying source-route options | Nothing. LSRR/SSRR are dead options; no legitimate traffic uses them |
| `net.mptcp.enabled=0` | MPTCP as extra TCP attack surface | MPTCP itself. Nothing in a GB10 cluster uses it |
| `user.max_user_namespaces=0` | Unprivileged user namespaces, a known local privilege-escalation path on Ubuntu 24.04 | Rootless containers (rootless Docker/Podman) and bubblewrap-style sandboxes stop working |

### Apply

`/etc/sysctl.d/99-gb10-hardening.conf`:

```
user.max_user_namespaces=0
net.mptcp.enabled=0
```

`/etc/nftables.d/gb10filter.nft`:

```
table inet gb10filter {
    chain input {
        type filter hook input priority filter; policy accept;
        ip option lsrr exists drop
        ip option ssrr exists drop
    }
}
```

Load both now, and make the firewall table survive reboot. The
persistence step is the one people miss: loading the table by hand
does not bring it back after a reboot. The include line plus the
enabled `nftables` service does.

```bash
sudo sysctl --system
sudo nft -c -f /etc/nftables.d/gb10filter.nft && sudo nft -f /etc/nftables.d/gb10filter.nft
grep -q 'gb10filter' /etc/nftables.conf || echo 'include "/etc/nftables.d/gb10filter.nft"' | sudo tee -a /etc/nftables.conf
sudo systemctl enable nftables
```

### Verify

```bash
sysctl user.max_user_namespaces net.mptcp.enabled   # expect 0 and 0
sudo nft list table inet gb10filter                  # both drop rules present
systemctl is-enabled nftables                        # enabled: the table returns after reboot
# Then confirm SSH / tailnet / RDMA still work.
```

### After a future kernel update: what to revert, what to keep

When a newer kernel is eventually adopted (see the kernel section
above), do not bulk-revert these. Go piece by piece:

- **Keep the nftables drop.** It costs nothing and stays useful as
  defense in depth even on a patched kernel.
- **Keep MPTCP disabled** unless you deliberately adopt MPTCP.
- **`user.max_user_namespaces=0` is the judgment call.** It is the
  only piece with a real usability cost. Revert it only when both
  are true: the running kernel is confirmed to carry the
  user-namespace fix, and you actually need rootless containers or
  sandboxing on the node. To revert: delete the line from
  `/etc/sysctl.d/99-gb10-hardening.conf` and reboot (or apply live
  with `sudo sysctl -w user.max_user_namespaces=2147483647`, the
  usual kernel default).

Updating DGX OS by itself is not a reason to revert anything. Check
the kernel you actually booted (`uname -r`) and whether it carries
the fixes.

## Also in the node standard

- Headless: default target `multi-user.target`, display stack off
  (`docs/DGX-OS-7.6-HEADLESS.md`).
- GPU clock lock 2200 MHz (`deploy/apply-2200.sh`,
  `gb10-clock-cap.service`); CPU cap 2808 MHz (`deploy/apply-2808.sh`,
  `gb10-cpu-cap.service`).
- Kernel: `7.0.0-1019-nvidia-64k` qualified baseline (above);
  display modeset off via the OEM override package (above).
