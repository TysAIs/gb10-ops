# Quad GB10 stack — verified fleet state (2026-11-02)

Four GB10 nodes (2x DGX Spark + 2x Acer Veriton GN100) on a MikroTik CRS812 fabric.
All nodes are inference nodes only; all harness/admin work runs from the host (AREO).

## Nodes

| Node | Tailnet | Kernel | Fabric A (rocep1s0f1) | Fabric B (roceP2p1s0f1) | Link |
|---|---|---|---|---|---|
| node1 | 203.0.113.11 | 6.17.0-1032-nvidia | 192.0.2.11/24 | 198.51.100.11/24 | 200G |
| node2 | 203.0.113.12 | 6.17.0-1032-nvidia | 192.0.2.12/24 | 198.51.100.12/24 | 200G |
| node3 (node3) | 203.0.113.13 | 6.17.0-1032-nvidia | 192.0.2.13/24 | 198.51.100.13/24 | 200G |
| node4 (node4) | 203.0.113.14 | 6.17.0-1032-nvidia | 192.0.2.14/24 | 198.51.100.14/24 | 200G |

Node2 note (RESOLVED 2026-11-02): node2 long refused 200G on qsfp56-dd-1 while
its CX7, kernel, and firmware matched node1 exactly. Root cause: in dd-1 the
switch could not read the EEPROM of node2's specific cable unit (Amphenol
NJAAKK-AU06 s/n 0113030026352672) - monitor showed module-present but no
vendor/serial/checksum, and the port would not train at any speed. Triple-checked:
ALL four fleet cables are the same Amphenol NJAAKK QSFP112 400G family (N911 is
NVIDIA's retail variant of the same spec) with byte-identical SFF-8636 EEPROM
layouts (id 0x11), so it is NOT a QSFP112-vs-QSFP56 issue. The AU06 unit reads and
trains 200G in dd-2 and both native cages, and dd-1 reads an N911 unit fine: the
failure is that one cable unit in that one cage (marginal module-read path, exact
mechanism unknown). Fix: swap the two DD-cage cables so the AU06 sits in dd-2.
Final cable map (all 200G, EEPROM checksum good x4, full mesh verified):
node1 (N911 s/n APF26029111NTM) -> qsfp56-dd-1-1; node2 (AU06 s/n
0113030026352672) -> qsfp56-dd-2-1; node3 (N911 s/n APF25269118DEC) ->
qsfp56-1-1; node4 (AU06 s/n 01130300258K0286) -> qsfp56-2-1.
Diagnostic method: ethtool -m on each NIC + switch monitor sfp-vendor-serial,
matched by serial number. If a cage shows module-present with no EEPROM data,
suspect the cage/module-standard combo before the node or the cable.
A published twin of this failure exists (MikroTik forum, CRS804 thread 272832,
same 98DX7335 chip + N911 cables); MikroTik support blamed passive-DAC
compatibility and said an RMA would not necessarily change the behavior.

## Fabric facts

- One cable per node into the f1 cage = the full physical link. The two ~100G halves
  seen by the host (rocep1s0f1 + roceP2p1s0f1) are twins of the SAME cabled port.
- Full rate needs BOTH twins addressed on DIFFERENT subnets (above) and
  NCCL_IB_HCA=rocep1s0f1,roceP2p1s0f1.
- Verified: per-twin ib_write_bw ~13.0 GB/s (~104 Gb/s) node1<->node3;
  jumbo frames end to end (ping -M do -s 8972 clean); full ping mesh.
- CX7 hotplug flag: /etc/nvidia/cx7-hotplug-enabled must NOT exist, or the 200G
  lanes will not train. Remove it (root) - no reboot needed on healthy nodes.
- Switch (CRS812): RouterOS 7.26beta4 + switch-marvell 7.26beta4 + RouterBOARD
  7.26beta4 (keep all three matched; it shipped 7.25 with board firmware 7.23.4).
  Fabric ports forced, auto-negotiation=no, speed=200G-baseCR4 fec-mode=fec91,
  mtu=9000 l2mtu=9216. Config backup: quad-200g-complete-20261102 on the switch.
- NEVER disable a 400G DD port on RouterOS <=7.25: that version can corrupt the
  attached DAC's EEPROM when a DD port is disabled (fixed in 7.26beta4). Also,
  disabling or enabling any sub-interface of a DD port reconfigures the whole
  port group.
- WARNING: on this switch with Amphenol DACs, any port re-init can fail module
  auto-init (status auto-init-failed). Recovery: force speed=100G-baseCR4
  fec-mode=auto, which re-trains reliably on readable modules; then step back up.
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
