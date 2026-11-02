# Quad GB10 stack — verified fleet state (2026-11-02)

Four GB10 nodes (2x DGX Spark + 2x Acer Veriton GN100) on a MikroTik CRS812 fabric.
All nodes are inference nodes only; all harness/admin work runs from the host (AREO).

## Nodes

| Node | Tailnet | Kernel | Fabric A (rocep1s0f1) | Fabric B (roceP2p1s0f1) | Link |
|---|---|---|---|---|---|
| node1 | 203.0.113.11 | 6.17.0-1032-nvidia | 192.0.2.11/24 | 198.51.100.11/24 | 200G |
| node2 | 203.0.113.12 | 6.17.0-1032-nvidia | 192.0.2.12/24 | 198.51.100.12/24 | 100G (see note) |
| node3 (node3) | 203.0.113.13 | 6.17.0-1032-nvidia | 192.0.2.13/24 | 198.51.100.13/24 | 200G |
| node4 (node4) | 203.0.113.14 | 6.17.0-1032-nvidia | 192.0.2.14/24 | 198.51.100.14/24 | 200G |

Node2 note: its CX7 disables the port on any 200G train attempt and self-recovers
at forced 100G. Kernel and CX7 firmware (28.50.1002) match node1 exactly.
Remaining suspects: the switch cage/cable path (marginal at 200G PAM4) or CX7 NVRAM
port config. Discriminator: swap cables at the switch end (node2 <-> node3) -
if the refusal follows the port, it is cage/cable; if it follows the node, NVRAM.

## Fabric facts

- One cable per node into the f1 cage = the full physical link. The two ~100G halves
  seen by the host (rocep1s0f1 + roceP2p1s0f1) are twins of the SAME cabled port.
- Full rate needs BOTH twins addressed on DIFFERENT subnets (above) and
  NCCL_IB_HCA=rocep1s0f1,roceP2p1s0f1.
- Verified: per-twin ib_write_bw ~13.0 GB/s (~104 Gb/s) node1<->node3;
  jumbo frames end to end (ping -M do -s 8972 clean); full ping mesh.
- CX7 hotplug flag: /etc/nvidia/cx7-hotplug-enabled must NOT exist, or the 200G
  lanes will not train. Remove it (root) - no reboot needed on healthy nodes.
- Switch (CRS812, RouterOS 7.25): fabric ports forced, auto-negotiation=no.
  200G ports: speed=200G-baseCR4 fec-mode=fec91. Node2 port: 100G-baseCR4 fec auto.
  All fabric ports mtu=9000 l2mtu=9216.
- WARNING: on this switch with Amphenol DACs, any port re-init can fail module
  auto-init (status auto-init-failed). Recovery: force speed=100G-baseCR4
  fec-mode=auto, which re-trains reliably; then step back up.
- Keep fabric ports in the single default bridge (a second bridge collapses RDMA).
  Note the default bridge also carries the LAN, so unconfigured fabric NICs can
  pull LAN DHCP - always set fabric IPs statically (netplan 40-cx7.yaml per node).
- Start lossy (no PFC/ECN): a 6-node GB10 fabric measured ~196 Gb/s/node lossy.

## Node standard (applied 2026-11-02, see HARDENING.md)

- Kernel pinned 6.17.0-1032-nvidia on every node (GRUB default + apt-mark hold).
- GPU locked 0,2200 via gb10-clock-cap.service. clocks.max still reads 3003 under
  lock on GB10 - verify under load: BF16 GEMM pins SM at ~2190 MHz.
- Headless: default target multi-user; display stack off.
- Twin MTU 9000; IPs per table above.
