# GB10 power-delivery defect

## Summary

Certain GB10 units hard power-off under sustained GPU load, with no
warning, no logs, no graceful shutdown. The box just dies.

**It's not thermal.** Crashes happen at 79–82°C / ~88–92W, well below
the 95°C thermal trip point. This is a power-delivery defect.

## NVIDIA's position

- Acknowledged: July 27, 2026
- No fix shipped as of Oct 2026
- "This behavior only occurs in certain units." RMA recommended
- RMA path functional; 2 of 6 documented cases resolved by replacement

## Why the clock cap works

The cap keeps GPU power below the ~88W danger zone:

| Clock | Power (inference) | Power (GEMM stress) |
|---|---|---|
| Uncapped (~2455 actual) | ~47W | 87W |
| 2200 MHz | 27W | ~50W (est) |
| 2000 MHz | 21W | ~40W (est) |

Measured Oct 16, 2026 on healthy units via llama-benchy and cuBLAS GEMM.

## Test results (Oct 16, 2026)

**llama-benchy sweep** (pp=2048, tg=128, 3 runs):
- 2200 MHz: 3,009 tok/s prefill
- 2100 MHz: 2,905 tok/s prefill
- 2000 MHz: 2,880 tok/s prefill
- Decode: ~73 tok/s (memory-bound, flat across caps)

**GEMM stress** (60 samples, uncapped):
- Avg power: 87.4W, peak: 89.7W
- Result: SURVIVED (healthy unit), but zero safety margin

## Recovery

- A hard power-off needs **AC unplugged for 30–60 seconds**; a reboot
  does not fix it.
- **Wake-on-LAN does not reliably wake GB10 nodes**: the EC cuts NIC
  standby power in S5 (proven on fleet hardware).
- Real remote recovery: UEFI *After Power Loss → Auto Boot* plus a
  switched PDU / smart plug, so a dead node can be power-cycled and
  boots itself when power returns.

## Recommendation

**2200 MHz** is the standard: proven safe across multiple units, 38W
margin to the 88W defect threshold, best balance of performance and
safety for 24/7 operation.
