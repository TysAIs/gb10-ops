# N-node GB10 fabric — 200G clustering for any node count

How to cable, address, and verify a GB10 cluster fabric: 2 nodes, 4
nodes, or more, on any 200G switch. (File name kept from the original
4-node build; nothing here is 4-node-specific.)

Each GB10 node's ConnectX-7 port exposes **two PCIe functions** for one
cabled port. The two ~100G halves the host sees (`rocep1s0f1` +
`roceP2p1s0f1`, netdevs `enp1s0f1np1` + `enP2p1s0f1np1`) are twins of the
**same** physical link — full 200G needs **both twins addressed, on
different subnets**.

## Per-node addressing (netplan)

One `/etc/netplan/40-cx7.yaml` per node. Example for node 1 — increment
the last octet per node, same pattern on both subnets:

```yaml
network:
  version: 2
  ethernets:
    enp1s0f1np1:
      addresses: [192.0.2.11/24]   # example
      mtu: 9000
    enP2p1s0f1np1:
      addresses: [198.51.100.11/24]   # example
      mtu: 9000
```

Rules:

- Fabric IPs are **static, always** — unconfigured fabric NICs can pull
  DHCP from a LAN sharing the switch, which silently breaks RDMA.
- MTU **9000** on every node interface; switch ports at MTU 9000 /
  L2MTU **9216**.
- Keep the fabric on a single L2 segment/bridge. Start **lossy** (no
  PFC/ECN) — a 6-node GB10 fabric measured ~196 Gb/s/node lossy.

## Switch (generic, any 200G switch)

- **Update switch firmware before fabric bring-up.** On some switches,
  older firmware could corrupt a DAC's EEPROM when a 400G DD port was
  disabled, and disabling/enabling one sub-port can reconfigure the
  whole port group. Avoid disabling DD ports during bring-up.
- Fabric ports: fixed 200G (e.g. `200G-baseCR4`, FEC RS/FEC91),
  auto-negotiation off.

## NCCL / RoCE

```bash
export NCCL_IB_HCA=rocep1s0f1,roceP2p1s0f1
```

Both twins must be listed, or traffic uses only half the link.

## Verify (every node, in order)

1. **Link:** both twins up at 200G (`ethtool <netdev>` / switch port
   state shows 200G).
2. **RDMA ACTIVE:** `rdma link` — both `rocep1s0f1/1` and
   `roceP2p1s0f1/1` show `state ACTIVE physical_state LINK_UP`.
3. **Jumbo end to end:** `ping -M do -s 8972 <peer-twin-ip>` — clean,
   no fragmentation.
4. **Full mesh:** ping **every** twin IP of **every** other node —
   zero failures.
5. **Bandwidth:** per-twin `ib_write_bw` ≈ 13.0 GB/s (~104 Gb/s) per
   twin is a healthy reference point.

## Troubleshooting: port will not train at 200G — check the hotplug flag

Some GB10 nodes ship with the file `/etc/nvidia/cx7-hotplug-enabled`
present. With the flag set, a cabled ConnectX-7 port can refuse to
train at 200G no matter what the switch is set to. If a port will not
train after cabling and switch settings check out, remove the flag
and re-test before swapping any hardware:

```bash
sudo rm -f /etc/nvidia/cx7-hotplug-enabled
```

(Fleet-found, Nov 2026: removing it took a port from no-train to
200G/FEC91 with no reboot or power drain needed.)

## Troubleshooting: module present, EEPROM unread

If a switch cage shows a module present but no vendor/serial/checksum,
and the port will not train at any speed, suspect the **cage/module
combination** before the node or the cable. Isolate by swapping cables
between cages and re-testing; identify cables from both ends by serial
(`ethtool -m <netdev>` on the node, the switch's module monitor) and
match them. A cable that fails in one cage may train fine in another.

## Node standard on every fabric node

- Kernel pinned `6.17.0-1032-nvidia`, identical on all nodes
  (`docs/HARDENING.md`) — mixed kernels invalidate NCCL/RoCE results.
- GPU cap 2200 MHz (`gb10-clock-cap.service`) and CPU cap 2808 MHz
  (`gb10-cpu-cap.service`). `clocks.max` still reads 3003 under the GPU
  lock — verify under load (BF16 GEMM pins SM at ~2190 MHz).
- Headless: `multi-user.target`, display stack off.
- Twin MTU 9000, static IPs per the table pattern above.
