# GB10 node hardening and kernel policy

## Kernel: hold 6.17.0-1032-nvidia on ALL cluster nodes

- Do NOT take 7.0.0-1019 (DGX OS 7.6) or 7.0.0-1024: NCCL/RoCE regression
  (ibv_reg_mr_iova2 ENOMEM, GPU work 1.5-2.4x slower) on 1019; idle resets,
  freezes and bootloops reported on 1024.
- ALL nodes in a cluster must run the SAME kernel. Mixed kernels taint any
  NCCL/RoCE measurement.
- Never install doca-ofed or kernel-mft-dkms (shadows inbox mlx5, breaks CX7).
- Pin: GRUB_DEFAULT to the 1032 entry + apt-mark hold linux-image/headers/
  linux-modules-nvidia-580-open for 6.17.0-1032-nvidia. Keep the newer kernel
  installed as a GRUB fallback until the fleet is proven; test-boot with
  grub-reboot before changing the default.

## CVE-2026-98432 (IPv4 TCP, unpatched upstream as of 2026-11-01)

No Spark kernel has the fix yet, and the 6.17 line is EOL, so mitigation is
configuration, applied identically on any kernel:

- sysctl user.max_user_namespaces=0  (also closes a public Ubuntu 24.04 root LPE)
- sysctl net.mptcp.enabled=0        (shrinks TCP attack surface; nothing here uses MPTCP)
- Optional nftables input rule dropping TCP packets with IP options
  (the vulnerable path): add an inet filter table, policy accept, one rule:
  ip option type 94 drop (LSRR/SSRR class). Test SSH/Tailscale/RDMA after applying.

Persist sysctls in /etc/sysctl.d/99-gb10-hardening.conf.
Nodes are LAN/tailnet-only (not internet-exposed): this is cheap insurance,
not an emergency.

## Also in the node standard

- /etc/nvidia/cx7-hotplug-enabled must not exist (blocks 200G training).
- Default target multi-user.target (headless). UEFI Dynamic Display Reserved
  Memory (Esc/Del at boot) reclaims ~1.5-2 GB on headless nodes.
- GPU clock lock 2200 MHz (deploy/apply-2200.sh), persisted by gb10-clock-cap.service.
