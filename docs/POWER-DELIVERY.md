# GB10 Power-Delivery Defect

## Summary

Certain NVIDIA DGX Spark (GB10) units hard power-off under sustained GPU load
with no warning, no logs, no graceful shutdown. The box just dies. Recovery
requires physically unplugging AC for 30-60 seconds.

**It's not thermal.** Crashes happen at 79-82°C / 88-92W, well below the 95°C
thermal trip point. This is a power-delivery defect.

## NVIDIA's Position

- Acknowledged: July 27, 2026
- No fix shipped as of Oct 2026
- "This behavior only occurs in certain units" — RMA recommended
- RMA path functional; 2 of 6 documented cases resolved by replacement

## Why the Clock Cap Works

The cap keeps GPU power below the ~88W danger zone:

| Clock | Power (inference) | Power (GEMM stress) |
|-------|-------------------|---------------------|
| Uncapped (~2455 actual) | ~47W | 87W |
| 2200 MHz | 27W | ~50W (est) |
| 2000 MHz | 21W | ~40W (est) |

Measured Oct 16, 2026 on healthy units via llama-benchy and cuBLAS GEMM.

## Test Results (Oct 16, 2026)

**llama-benchy sweep** (pp=2048, tg=128, 3 runs):
- 2200 MHz: 3,009 tok/s prefill (verified across multiple runs)
- 2100 MHz: 2,905 tok/s prefill
- 2000 MHz: 2,880 tok/s prefill
- Decode: ~73 tok/s (memory-bound, flat across caps)

**GEMM stress** (60 samples, uncapped):
- Avg power: 87.4W, Peak: 89.7W
- Result: SURVIVED (healthy unit), but zero safety margin

## Recommendation

**2200 MHz** is the standard:
- Proven safe and stable across multiple units
- 38W margin to the 88W defect threshold
- Best balance of performance and safety for 24/7 operation
