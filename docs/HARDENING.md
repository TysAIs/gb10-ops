# GB10 node hardening and kernel policy

Apply identically on every GB10 node. Verify after each step.

## Kernel: pin 6.17.0-1032-nvidia on ALL nodes

- Do **NOT** take `7.0.0-1019` (DGX OS 7.6): NCCL/RoCE regression
  (`ibv_reg_mr_iova2` ENOMEM, GPU work 1.5–2.4x slower). Do **NOT**
  take `7.0.0-1024`: idle resets, freezes, and bootloops reported.
- **All nodes in a cluster run the same kernel.** Mixed kernels taint
  any NCCL/RoCE measurement.
- Never install `doca-ofed` or the dkms MFT package (`kernel-mft-dkms`)
  — it shadows the inbox mlx5 driver and breaks the ConnectX-7.
- Pin it:

```bash
uname -r   # expect 6.17.0-1032-nvidia
sudo apt-mark hold linux-image-6.17.0-1032-nvidia \
  linux-headers-6.17.0-1032-nvidia linux-modules-nvidia-580-open-6.17.0-1032-nvidia
# Set GRUB_DEFAULT to the 1032 entry in /etc/default/grub, then:
sudo update-grub
```

Keep a newer kernel installed as a GRUB fallback until the node is
proven; test-boot with `grub-reboot` before changing the default.

## CVE-2026-98432 mitigations

CVE-2026-98432 (IPv4 TCP) is **unpatched on every GB10 kernel** — the
6.17 line is EOL — so configuration mitigation is the answer, applied
identically on any kernel. Nodes are LAN/tailnet-only (not
internet-exposed): this is cheap insurance, not an emergency. The
sysctls also close a public Ubuntu 24.04 root LPE
(`user.max_user_namespaces=0`) and shrink TCP attack surface
(`net.mptcp.enabled=0`; nothing here uses MPTCP).

`/etc/sysctl.d/99-gb10-hardening.conf`:

```
user.max_user_namespaces=0
net.mptcp.enabled=0
```

`/etc/nftables.d/gb10filter.nft` — drops TCP packets carrying LSRR/SSRR
IP options (the vulnerable path):

```
table inet gb10filter {
    chain input {
        type filter hook input priority filter; policy accept;
        ip option lsrr exists drop
        ip option ssrr exists drop
    }
}
```

Apply and verify:

```bash
sudo sysctl --system
sysctl user.max_user_namespaces net.mptcp.enabled   # expect 0 and 0
sudo nft -c -f /etc/nftables.d/gb10filter.nft && sudo nft -f /etc/nftables.d/gb10filter.nft
sudo nft list table inet gb10filter
# Then confirm SSH / tailnet / RDMA still work.
```

## Also in the node standard

- Headless: default target `multi-user.target`, display stack off
  (`docs/DGX-OS-7.6-HEADLESS.md`).
- GPU clock lock 2200 MHz (`deploy/apply-2200.sh`,
  `gb10-clock-cap.service`); CPU cap 2808 MHz (`deploy/apply-2808.sh`,
  `gb10-cpu-cap.service`).
