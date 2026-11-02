# CPU tuning on GB10: measured (node1, 2026-11-02)

GB10: 10x Cortex-X925 (hw max 3900 MHz) + 10x Cortex-A725 (hw max 2808 MHz),
one cpufreq policy per CPU. CPPC auto_select ships ON (=1); with it on,
scaling_max_freq changes are ignored by hardware. Any cap work starts with
auto_select=0 on every policy. Governor is performance stock.

## Standard: X925 capped at 2808 MHz (decided 2026-11-02)

Fleet standard on every GB10 node: auto_select=0 and
scaling_max_freq=2808000 on all 20 cpufreq policies (the X925s capped to
the A725 ceiling; the A725s already live there). Decided by the operator,
2026-11-02, on the A/B v2 evidence below. The cap toggles live with the
serving stack up; no engine restart is needed.

### Why: A/B v2 against the live serving stack

Paired prompts, ABBA blocks (stock, capped, capped, stock), caps toggled
live with no restart, against the 4-node TensorFold DeepSeek endpoint.
44 runs, run-to-run spread 0.1-1%:

| Workload | Stock | Capped 2808 | Delta |
|---|---|---|---|
| Prefill ~8K tok/s | 2995.1 | 2987.8 | -0.24% |
| Prefill ~32K tok/s | 3325.2 | 3323.2 | -0.06% |
| Prefill ~64K tok/s | 3357.8 | 3353.4 | -0.13% |
| Decode 1 stream tok/s | 100.49 | 100.43 | -0.06% |
| Decode 8 streams, aggregate tok/s | 196.05 | 196.10 | +0.02% |
| Decode 16 streams, aggregate tok/s | 209.66 | 209.87 | +0.10% |

Every delta is inside the run spread: any true serving cost of the cap
is under ~0.25%. (The burn test below measures something else: a pure
all-core CPU workload, where the cap costs real throughput and buys
~15 C. Serving is not CPU-bound at these levels.) Full run data: goal
workspace hidden_files/cpu-ab-v2/ (results.json, summary.md).

### Confirmation re-test (2026-11-02, later the same day)

Independent re-test with a stricter harness: unique prompts every run
(no TensorFold KV-cache reuse), TTFT measured to the first generated
token, 512-token decodes, cap toggled live on the same 4-node endpoint.

| Workload | Capped 2808 | Stock |
|---|---|---|
| Decode, ~340 tok prompt | 74.1 tok/s | 74.8 tok/s |
| Decode, ~18K context | 73.7 tok/s | 79.2 tok/s (runs spread 72-87) |
| Decode, ~67K context | 83.4 tok/s | 75.7 tok/s |
| Decode, 6 streams, per stream | 29.0 tok/s | 29.1 tok/s (aggregate 157 vs 159) |
| TTFT (short / ~18K / ~67K) | 0.35 / 5.6 / 20.4 s | identical |

The two workloads whose means differ point in opposite directions,
the signature of run-to-run noise, not a cap effect. Conclusion
unchanged: no measurable serving cost. Note the 6-stream row:
parallel agent sessions split a fixed aggregate (~29 tok/s each at
6-way), which is where interactive slowness actually comes from,
not the cap.

### Apply / verify / restore (root, per node)

```bash
BASE=/sys/devices/system/cpu/cpufreq
# Apply: auto_select OFF first, or the cap is ignored by hardware
for d in $BASE/policy*; do echo 0 > $d/auto_select; done
for d in $BASE/policy*; do echo 2808000 > $d/scaling_max_freq; done
# Verify: expect 20 and 20 (of 20 policies)
grep -l '^2808000$' $BASE/policy*/scaling_max_freq | wc -l
grep -l '^0$' $BASE/policy*/auto_select | wc -l
# Restore stock: hardware max back per policy, auto_select back ON
for d in $BASE/policy*; do cat $d/cpuinfo_max_freq > $d/scaling_max_freq; done
for d in $BASE/policy*; do echo 1 > $d/auto_select; done
```

Persistence: shipped. gb10-cpu-cap.service (oneshot, enabled at boot,
mirrors gb10-clock-cap.service) runs /usr/local/bin/gb10-cpu-cap apply:
auto_select=0 on every policy first, then scaling_max_freq=2808000 on
every policy. Install or re-apply with deploy/apply-2808.sh (it installs
the unit, starts it so the cap applies immediately, and verifies by
reading back); --uninstall restores stock. Verified 2026-11-02 on all
four nodes, including a stock-to-capped proof on node4.

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
  option for CPU-heavy agent/tokenizer loads or hot rooms. On a pure CPU
  burn it is not a free lunch (-13.5%); in serving it measures free
  (<0.25%, A/B v2 above), and it is the fleet standard as of 2026-11-02
  (see the Standard section).
- 2400 buys only ~1 C more than 2808 for another ~5% throughput - poor trade.
- E-core taskset pinning of engine host threads (forum: peak 94->72 C at no
  throughput loss) remains untested here; it needs a real serving workload,
  not a synthetic burn.
