# gb10-ops

> **The DGX Spark (GB10) operations toolkit.** Tested clock caps, power-delivery
> research, deployment automation, and benchmarking methodology. Built from real
> measurements on real hardware.

## The Standard: 2200 MHz

**Apply to all Sparks:**
```bash
./deploy/apply-2200.sh
```

### Why 2200?

| Cap | Prefill | Power (inference) | Power (stress) | Margin to 88W defect |
|-----|---------|-------------------|----------------|---------------------|
| 2000 | 2,880 tok/s | 21W | ~40W (est) | 48W |
| 2100 | 2,905 tok/s | 24W | ~45W (est) | 43W |
| **2200** | **3,009 tok/s** | **27W** | **~50W (est)** | **38W** |

2200 MHz is the original tested standard. Safe, stable, and proven across
multiple units. Verification runs confirmed no meaningful performance difference
vs higher caps (within noise), so 2200 remains the recommended setting.

**Key findings (Oct 16, 2026, measured on 2x DGX Spark):**
- 2200 MHz keeps power well under the 88W defect threshold
- 38W safety margin to the power-delivery defect zone
- Uncapped survives on healthy units (87W) but with zero margin — not recommended
- Decode is memory-bound (~73 tok/s), flat across caps
- All caps 2000-2200 are safe; 2200 is the best balance of performance and safety

## The Power-Delivery Defect

GB10 units can hard power-off (no logs, instant death) at ~88W GPU draw.
NVIDIA acknowledged July 2026. It's **power-delivery, not thermal** — crashes
at 79-82°C, below the 95°C trip point.

The clock cap prevents this by keeping power below the danger zone.
See `docs/POWER-DELIVERY.md` for full research.

## Repository Structure

```
gb10-ops/
├── README.md              # This file
├── deploy/
│   └── apply-2200.sh      # One-command deployment to all Sparks
├── docs/
│   └── POWER-DELIVERY.md  # Defect research, test results, methodology
├── fan-control/
│   └── precool.sh         # Optional fan pre-cooling (requires Owen's tool)
└── tests/
    └── proper-sweep.sh    # llama-benchy clock-cap sweep script
```

## Deployment

**Quick (auto-discover Sparks on LAN):**
```bash
./deploy/apply-2200.sh
```

**Manual (specific hosts):**
```bash
./deploy/apply-2200.sh itxji@10.0.0.4 itxji@10.0.0.23
```

**What it does:**
1. Sets `nvidia-smi -lgc 0,2200` immediately
2. Installs systemd service for persistence across reboots
3. Verifies on each host

**Remove:**
```bash
./deploy/apply-2200.sh --uninstall
```

## Benchmarking

Use `llama-benchy` (not curl loops, not wall-clock division):

```bash
uvx llama-benchy \
  --base-url http://10.0.0.4:8000/v1 \
  --model Qwen/Qwen3.8-Flash-Next-Uncensored \
  --served-model-name Qwen/Qwen3.8-Flash-Next-Uncensored \
  --pp 2048 --tg 128 --exact-tg \
  --runs 3 --latency-mode generation
```

**Metrics that matter:**
- `tg` tok/s: Decode speed (memory-bound, should be flat across caps)
- `pp` tok/s: Prefill speed (compute-bound, scales with clock)
- `e2e_ttft`: Time to first content token (user-facing latency)

See `tests/proper-sweep.sh` for the full sweep script.

## Stress Testing

Verify power delivery health with dense GEMM:

```bash
# On the Spark:
git clone --depth 1 https://github.com/hoesing/spark-gpu-throttle-check
python3 spark-gpu-throttle-check.py -n 60
```

**PASS criteria:** Clocks stay above 1400 MHz, power below 75W with cap in place.

**Our results (2200 MHz cap):** 58W avg, 2281 MHz peak, PASS.

## Fan Control (Optional)

Owen's `dgx-spark-fan-control` enables pre-cooling: boost fans before heavy
jobs, return to automatic after. Useful for thermal headroom, not required
for the 2200 MHz standard.

```bash
# Install (see Owen's repo for full instructions):
# https://github.com/christopherowen/dgx-spark-fan-control

# Pre-cool before a heavy job:
./fan-control/precool.sh 8 120
```

## Safety

- **Never test uncapped** unless you can physically access the box. Hard
  power-off requires AC unplug for 30-60s to recover. Reboot does NOT fix it.
- **Always set caps on both Sparks** in TP2 setups. Mismatched caps cause issues.
- **Monitor during stress tests.** Abort if power >75W or SoC >92°C.

## Attribution

- **TysAIs**: Original research, testing methodology, "CPU is the thermal limiter"
- **agjs/gb10-clock-cap**: Benchmark rigor, soak testing methodology
- **hoesing/spark-gpu-throttle-check**: Power-delivery diagnostic
- **christopherowen/dgx-spark-fan-control**: Pre-cooling concept
- **mathieu-lacage/dgx-spark-fan-override**: EC protocol docs
- **miaai-lab/sparkLimiter**: Deployment pattern
- **eugr/llama-benchy**: Benchmarking tool

## License

MIT
