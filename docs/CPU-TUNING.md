# CPU tuning on GB10 — measured (node1, 2026-11-02)

GB10: 10x Cortex-X925 (hw max 3900 MHz) + 10x Cortex-A725 (hw max 2808 MHz),
one cpufreq policy per CPU. CPPC auto_select ships ON (=1); with it on,
scaling_max_freq changes are ignored by hardware. Any cap work starts with
auto_select=0 on every policy. Governor is performance stock.

## Method

All-core FP workload (gcc -O3 -march=native -fopenmp, 20 threads, fixed inner
work, 30 s runs), 3 runs per condition, peak thermal-zone temp sampled every
2 s (zones are acpitz board zones; GB10 has no CPU package sensor). Variance
within each condition <0.2%. Nodes restored to stock afterwards
(auto_select=1, caps at hardware max).

## Results

| Condition | Throughput | vs stock | Peak zone temp |
|---|---|---|---|
| A stock (auto_sel=1, uncapped) | 541.9M iter/s | - | 68.0 / 71.4 / 72.7 C (still soaking up) |
| B auto_sel=0, X925 capped 2808 MHz | 468.9M iter/s | -13.5% | 58.7 / 57.7 / 57.7 C (flat) |
| C auto_sel=0, X925 capped 2400 MHz | 440.7M iter/s | -18.7% | 56.7 C (flat) |

## Reading

- The caps buy a LOT of temperature (~15 C at 2808) and stop thermal soak
  entirely, but on a pure all-core CPU burn they cost real throughput.
  Community reports of ~-5% were prefill inside a serving stack, where the
  CPU is not the whole workload - both numbers can be true.
- 2808 (the A725 ceiling, NullBurn setting) is the sensible thermal-safety
  option for CPU-heavy agent/tokenizer loads or hot rooms. It is NOT a free
  lunch and is not the fleet default here.
- 2400 buys only ~1 C more than 2808 for another ~5% throughput - poor trade.
- E-core taskset pinning of engine host threads (forum: peak 94->72 C at no
  throughput loss) remains untested here; it needs a real serving workload,
  not a synthetic burn.
