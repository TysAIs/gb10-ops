# GB10 node hardening and kernel policy

Apply identically on every GB10 node. Verify after each step.

## Kernel: don't update to the latest kernel yet

The standard kernel is `6.17.0-1032-nvidia`, pinned on ALL nodes.
The newest kernels are known-bad:

- Do **NOT** take `7.0.0-1019` (DGX OS 7.6): NCCL/RoCE regression
  (`ibv_reg_mr_iova2` ENOMEM, GPU work 1.5–2.4x slower). Do **NOT**
  take `7.0.0-1024`: idle resets, freezes, and bootloops reported.
- The hold lifts when a newer kernel proves stable (no crash loop,
  no NCCL/RoCE regression). Until then, stay pinned.
- **All nodes in a cluster run the same kernel.** Mixed kernels taint
  any NCCL/RoCE measurement.
- Never install `doca-ofed` or the dkms MFT package (`kernel-mft-dkms`):
  it shadows the inbox mlx5 driver and breaks the ConnectX-7.
- Pin it:

```bash
uname -r   # expect 6.17.0-1032-nvidia
sudo apt-mark hold linux-image-6.17.0-1032-nvidia \
  linux-headers-6.17.0-1032-nvidia linux-modules-nvidia-580-open-6.17.0-1032-nvidia
# In /etc/default/grub, set GRUB_DEFAULT to the 1032 entry (exact
# string from the reference fleet; confirm yours with
# `grep "6.17.0-1032" /boot/grub/grub.cfg | grep -m1 menuentry`):
#   GRUB_DEFAULT="Advanced options for DGX OS GNU/Linux>DGX OS GNU/Linux, with Linux 6.17.0-1032-nvidia"
sudo update-grub
```

Keep a newer kernel installed as a GRUB fallback until the node is
proven; test-boot with `grub-reboot` before changing the default.

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
