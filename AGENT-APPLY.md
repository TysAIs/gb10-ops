# Apply this standard with an agent: the runbook

Any node count from 1 to 8. One GB10 is a complete installation; eight is
the same procedure repeated, and nothing below counts nodes or assumes a
switch, a fabric or a cluster.

This file is written to be executed, not read for background: every step
that runs something names the command, the output that means it worked, and
the condition that means stop. If you are an agent, follow the steps in
order and do not skip a stop condition. If you are a human, the same steps
are the checklist.

**What it applies.** Two things, in this order:

| Stage | What changes | Reversible | Needs the gate | Reboot |
|---|---|---|---|---|
| 1 | `vm.watermark_boost_factor = 0`, stop the disabled-but-running `snapd` | yes | no | no |
| 2 | upstream `atticd` (spark-attic v0.1.2): a daemon that lends the display carveout, if anything ever borrows it | yes | **yes** | no |

**What it never touches.** The kernel, the boot default, the GPU or CPU
clock caps, the fabric, the serving recipe, the engine, the model, the
container, the weights. This runbook is not the clock-cap or kernel
procedure: those are `docs/CPU-TUNING.md`, `docs/HARDENING.md` and
`deploy/apply-2200.sh` / `deploy/apply-2808.sh`.

**What it deliberately does not do: stage 3.** Nothing here makes an engine
consume the carveout. Stage 2 ends with a resident daemon that lends
nothing, and `lent_mib` is verified to be `0` at the end of every apply.
Stage 3 requires serving-recipe work in another repository and is gated on
it — see `docs/APPLY-PLAN-2026-11.md` §4 and
`docs/ENGINE-CONSUMPTION-DESIGN.md`. If a step below ever seems to need an
engine variable, you are off this runbook.

Analysis and measurements behind it: `docs/DISPLAY-CARVEOUT.md`,
`docs/MEMORY-RECLAIM.md`, `docs/APPLY-PLAN-2026-11.md`.

**Credits for the optional component.** Stage 2 installs somebody else's
daemon: **spark-attic**, author **bertholomus**, source
https://github.com/bertholomus/spark-attic, license **Apache-2.0 OR MIT**
(`LICENSE-APACHE`, `LICENSE-MIT` upstream). Nothing of it is vendored
here; the installer is fetched from the pinned 0.1.2 release. The
headless-memory findings in stage 1 are **Christopher Owen
(christopherowen)**, X article 2026-11-16, credited in
`docs/MEMORY-RECLAIM.md`.

**Reference state.** Stages 1 and 2 of this runbook have been applied and
verified on the maintainer's four-node fleet (2026-11-16): watermarks read
`0`, `snapd` stopped, `atticd` ready with `lent_mib 0`, no serving
restart. If every step below reports `noop`, your node is already in that
state. Stage 3 is not part of that state and is not part of this runbook.

---

## Step 0 — Read the two numbers you will be asked for

You need no knowledge beyond this repository, but you do need two facts
about the node you are working on:

1. The SSH target that reaches it as a login user, for example
   `gb10@node1`. The user name is your own; this repo only ever shows
   examples.
2. Whether that user may run `sudo` without a password prompt on that node.
   Step 3 checks it; a node that prompts is a stop, not something to work
   around.

**Stop if** you do not have SSH access to a node. Nothing in stage 1 or 2
is reachable any other way.

## Step 1 — Get the repository on the machine that reaches the nodes

```bash
git clone https://github.com/TysAIs/gb10-ops.git
cd gb10-ops
bash deploy/carveout-gate.sh --self-test
```

**Expect** the last line `PASS: every gate case matched`, exit code 0.

**Stop if** it prints `FAIL` or exits non-zero: the checkout is incomplete,
bash is older than 4, or your shell's `TMPDIR` is deep enough that the
self-test's unix-socket fixture exceeds the 108-character `AF_UNIX` limit
(`OSError: AF_UNIX path too long`). The third is not a repo fault and not a
gate verdict: re-run it with a short temporary directory,
`TMPDIR=/tmp bash deploy/carveout-gate.sh --self-test`, and expect the same
`PASS` line. Nothing else below can be trusted until this passes.

## Step 2 — Write the inventory

One node per line: the SSH target, then optionally the health endpoint of
whatever serves on that node.

```bash
cat > inventory.txt <<'EOF'
# One node per line: <ssh-target> [serving-health-url]
# Examples only. Substitute your own targets; never commit this file.
gb10@node1
EOF
bash deploy/apply.sh --inventory inventory.txt --check-inventory
```

Eight nodes is the same file with eight lines; add a health URL to any
line that serves an endpoint you care about:

```bash
cat > inventory.txt <<'EOF'
gb10@node1 http://node1.example:8000/health
gb10@node2 http://node2.example:8000/health
gb10@node3
gb10@node4
gb10@node5
gb10@node6
gb10@node7
gb10@node8
EOF
```

**Expect** the first line `nodes <N> mode check stage all`, then one
`node <i> <target> health <url|none>` line per node, then
`inventory ok <N> node(s)`, exit code 0.

**Stop if** it reports a duplicate node, `more than two fields`, or
`no nodes`. It warns, without stopping, when the file has more than 8
nodes: that is outside what this runbook has been exercised on, and
`--allow-any-count` silences the warning. Leave the health URL out if you
are unsure what to put there: a declared endpoint that is down fails the
verification at step 8, and an undeclared one is skipped.

## Step 3 — Prove access and privilege on every node

For each node in the inventory:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 gb10@node1 true
ssh -o BatchMode=yes -o ConnectTimeout=10 gb10@node1 sudo -n true
```

**Expect** both to exit 0 with no prompt and no output.

**Stop if** either prints `Permission denied`, asks for a password, or
`sudo -n` prints `a password is required`. Fix key access or add the
NOPASSWD rule on that node first; `deploy/apply.sh` runs `sudo -n` and will
report `node verdict SKIPPED` for that node rather than prompt.

Read-only stages (`--dry-run`, `--verify`, the gate) need neither root nor
a password; only `--apply` and `--rollback` do.

## Step 4 — Gate every node before anything else

```bash
bash deploy/carveout-gate.sh gb10@node1
```

(For eight nodes, pass them all: `bash deploy/carveout-gate.sh gb10@node1
gb10@node2 ... gb10@node8`. Each node is gated independently. The run exits
with the last node code that was not 0 — `1` if any node was blocked, `3`
only when nothing failed and a node could not be reached — so read each
node's own verdict rather than the run's exit code.)

**Expect** a block of `key value` lines — including the `warn` lines, which
are printed before the verdict — then this verdict line:

```
verdict ELIGIBLE
```

The verdict is not the last line. `next: settle every warn line above, then
rerun this gate before installing` follows it when there is a warning,
otherwise `next (a human runs these; this script changes nothing):` and the
installer's `--check` command. None of that is output from the node and none
of it changes anything: the gate is read-only. The `warn` lines themselves
are not stops either: they name things to settle before installing, such as
`splash` still on the command line or a kernel outside upstream's tested
matrix.

**Stop if** the verdict is `BLOCKED`, and act on the reason it printed:

| Blocked line says | Meaning | What to do |
|---|---|---|
| `not aarch64` / `nvidia-smi reports no GB10` | not a GB10 node | this repo does not apply to it; do not continue on that host |
| `no NVIDIA driver loaded` | driver not up | fix the driver; nothing in this repo installs it |
| `driver X ships a shim but is not node-validated` | upstream built that driver's shim but has not proven it on a node | run upstream's `attic-update.sh` to validate it there, then re-gate; or wait |
| `driver X has no shim` | no artifact for that driver | do not install; upstream has nothing for it |
| `a display manager is active` | a desktop is running | make the node headless (`docs/DGX-OS-7.6-HEADLESS.md`), then re-gate |
| `a process other than nvidia-persistenced holds /dev/nvidia-modeset` | something is using the display | stop it, or leave this node out |
| `another carveout lender socket exists (...)` | one lender per node | remove the other lender, then re-gate |

A blocked node is not a broken node. It is a node where lending is the
wrong choice today. Stage 1 does not depend on the gate, so you may still
apply stage 1 there (step 6) — `--apply --stage 2` refuses. A node you leave
that way carries stage 1 only, so it is verified with `--verify --stage 1`
(step 8), not with plain `--verify`, which expects the daemon.

## Step 5 — Dry run

```bash
bash deploy/apply.sh --inventory inventory.txt --dry-run
```

**Expect**, per node: `gate ELIGIBLE`, then `stage1 watermark pending` or
`noop`, `stage2 attic pending ...` or `noop`, `would ...` lines describing
the changes, and finally `node verdict OK` and
`RESULT: plan only, nothing changed on any node`, exit code 0.

A gate-BLOCKED node still gets a plan, and that plan still ends
`node verdict OK` — nothing was changed anywhere, so nothing failed. What
says "do not run this as written" is the run's exit code: the last line is
`RESULT: at least one node is not eligible for the full run` and the run
exits 1, while that node's block carries `gate BLOCKED` and
`gate note not ELIGIBLE: stage 1 is node hygiene and does not need the
gate; stage 2 would be refused`. Its stage 1 lines are still a real plan,
and step 6 may proceed on stage 1 alone.

One state reports a refusal without changing the exit code: a node whose
daemon is already installed and reports a borrow prints
`stage2 attic installed state ... lent_mib <n>` where a clean node prints
`stage2 attic noop ...`, and the plan appends `--apply would refuse` to that
line. That is a stop, not a noop: `--apply` refuses that node (step 7), so
the plan exits 0 but the run would not.

**Stop if** the exit code is not 0, or any node prints `gate BLOCKED`,
`node verdict BLOCKED`, `node verdict FAIL`, `node verdict SKIPPED`, or
`stage2 attic installed state`. The exit code is the reliable signal for
gate refusals; the state line is the bit it cannot carry. Go back to steps 3
and 4. `--dry-run` runs only reads and the gate.

## Step 6 — Apply stage 1

```bash
bash deploy/apply.sh --inventory inventory.txt --apply --stage 1
```

**Expect**, per node:

```
stage1 watermark applied reads 0
stage1 snapd applied service inactive socket inactive
node verdict OK
```

and on a node that is already applied:

```
stage1 watermark noop reads 0 standard-file yes
stage1 snapd noop service inactive/disabled socket inactive/disabled
```

Both are success. The final line is `RESULT: every node applied or already
applied`, exit code 0.

**Stop if** the output contains `FAIL watermark` or `FAIL snapd`. The node
is left as it was found for that step; read `docs/MEMORY-RECLAIM.md` §2
for what the step is for.

Note that stage 1 records the value it found in
`/var/lib/gb10-ops/watermark.previous` before it changes anything. That
record is what `--rollback` restores; deleting the drop-in alone does not
put a live kernel back (no stock file sets this knob), so do not "clean up"
by hand.

Stage 1c in `APPLY-PLAN-2026-11.md` — removing `splash` from the kernel
command line — is not run here on purpose: it is a GRUB edit that takes
effect at a reboot, and this runbook does not reboot nodes. (On the
maintainer's fleet it is staged in the vendor GRUB drop-in and waiting for
the next planned boot.) `--dry-run`, `--verify` and the gate all report
`splash` if it is still on the live command line.

## Step 7 — Apply stage 2 on every node you gated ELIGIBLE

```bash
bash deploy/apply.sh --inventory inventory.txt --apply --stage 2
```

This runs upstream's installer, which validates the running driver on the
node before it enables the unit. It is fetched from the pinned release, not
vendored: `ATTIC_INSTALLER` overrides the URL only if you have a reason to.

**Expect**, per node:

```
stage2 preflight: installer --check
check: driver 580.178.04 validated, heap mode
stage2 install: upstream installer
...
verify attic doctor ok
verify attic ok state ready validated true size_mib 2044 lent_mib 0 driver 580.178.04
node verdict OK
```

`lent_mib 0` is the point: the daemon is up and validated, and nothing has
borrowed from it. That is the whole of stage 2.

If the doctor line reads `verify attic doctor warn ...` instead of `ok`,
that is not a failure: upstream's installer can report a missing
`libcuda.so.1` on a node where it resolves correctly (a `pipefail` +
`grep -q` SIGPIPE false negative). `status.json` is the daemon's own state
and is what the next line reports.

**Stop if** any of these appear:

| Output | Meaning | Action |
|---|---|---|
| `FAIL attic: installer preflight failed` | upstream refused this node | leave it out; the gate said eligible but the installer's own checks are stricter |
| `FAIL attic: state 'refusing'` | the daemon is up and refusing to lend | read `why` in `/run/spark-attic/status.json`; it names the failed check |
| `FAIL attic: validated 'false'` | no validated artifact for the running driver | run upstream's `attic-update.sh` on the node, then `--apply --stage 2` again |
| `FAIL attic: lent_mib 'N'` | something already borrowed the carveout | this is not stage 2; find the consumer before continuing |
| `node verdict SKIPPED` | no `sudo -n` on that node | step 3 |

`--apply` with no `--stage` runs stage 1 then stage 2 per node, and is the
normal whole-run command once stage 1 has been seen working somewhere.

The `lent_mib` row fires on a node that is already installed too: a daemon
that reports a borrow is not "already applied", so `--apply` fails that node
rather than reporting a noop. That is deliberate — a daemon lending when
nothing should be borrowing is a consumer to find, not a clean state.

## Step 8 — Verify

```bash
bash deploy/apply.sh --inventory inventory.txt --verify
```

**Expect**, per node:

```
verify watermark ok reads 0 standard-file yes
verify snapd ok service inactive/disabled socket inactive/disabled
verify attic ok state ready validated true size_mib 2044 lent_mib 0 driver 580.178.04
verify serving ok 200                     # only when a health URL is declared
node verdict OK
```

and `RESULT: every node verified`, exit code 0. When no health URL is
declared the serving line is `verify serving skipped (no endpoint declared
in inventory)` — not a failure.

**Stop if** any line starts with `FAIL`, with one exception you must not
mistake for a fault: the four attic checks on a node you deliberately left
without stage 2 (a gate-BLOCKED node from step 4). Verify that node with
`--verify --stage 1` instead, as below. Anything else that FAILs is a stop.
Re-run `--dry-run` to see the node's current state, then `--apply` again:
every step is idempotent, and the output names the step that is not in the
expected state.

### Verifying a node that is deliberately left without stage 2

If you applied stage 1 only — the usual reason is a gate-BLOCKED node from
step 4 — plain `--verify` is the wrong check. It expects the daemon, so it
reports `FAIL attic: state 'missing'`, `validated 'missing'`,
`size_mib 'missing'` and `lent_mib 'missing'`, and exits 1; and its remedy,
`--apply` again, is refused by the gate on that node for as long as the gate
says BLOCKED. Verify the stage the node actually carries:

```bash
bash deploy/apply.sh --inventory inventory.txt --verify --stage 1
```

**Expect** `verify watermark ok reads 0 standard-file yes`,
`verify snapd ok ...`, `verdict VERIFIED`, `RESULT: every node verified`,
exit code 0. `--stage` filters `--verify` as well as `--apply` and
`--rollback`; it is not an apply-only flag. Run the plain `--verify` of the
block above on the nodes that were gated ELIGIBLE.

## Step 9 — Record what you did

Keep the output. A short record is enough, and it is what a second agent
needs to continue:

```
nodes:      <N> (<targets>)
gate:       ELIGIBLE on <N>/<N>
stage 1:    applied on <N>, noop on <N>
stage 2:    applied on <N>, noop on <N>
verify:     VERIFIED on <N>/<N>; lent_mib 0 everywhere
rollback:   not needed
```

Do not commit `inventory.txt`: it is site data, not repo data.

**Stop if** you cannot fill a line in from output this run actually printed.
The record is a copy of what you saw, not a summary from memory: a line you
are reconstructing means the step it describes was not observed.

## Step 10 — Roll back, if you need to

```bash
bash deploy/apply.sh --inventory inventory.txt --rollback
```

Reverses stage 2 first (disable and uninstall the daemon; the key and logs
are kept), then stage 1a (remove the drop-in and restore the value recorded
at apply time).

**Expect**, per node:

```
rollback attic reverted (unit disabled, daemon uninstalled; ...)
rollback watermark reverted reads 15000 (restored to the pre-apply value 15000)
node verdict OK
```

and `RESULT: every node rolled back`, exit code 0. Running it twice is
safe: the second run reports `noop` for both steps.

Not reversed, by design: the `snapd` stop. Those units are disabled at
boot, so stopping them is not a configuration change and there is nothing
to put back. If you want `snapd` running again:
`sudo systemctl enable --now snapd.socket`.

Rollback does not need the gate and works on a node that would now be
blocked.

**Stop if** a node prints `FAIL` or `node verdict SKIPPED`: rollback needs
`sudo -n` exactly as apply does. `gate BLOCKED` followed by
`node verdict OK` is the expected shape on a node that is blocked today —
rollback never asks the gate for permission.

## Step 11 — Stop here, at stage 2

You are done. Stage 2's end state is a validated daemon that lends nothing:
`lent_mib 0`, no engine change, no recipe change, no capacity claim.

Stage 3 — an engine that borrows the carveout as KV cache — is **not
available from this repository**. It needs mounts and a Python package in
the serving recipe, a scratch single-node engine, and a comparison run;
`docs/APPLY-PLAN-2026-11.md` §4 states the prerequisites and
`docs/ENGINE-CONSUMPTION-DESIGN.md` the test protocol and the no-go
verdict for the current engine. Do not improvise it from this runbook.

---

## Appendix A — expected output, exactly

Every line this runbook tells you to expect is produced by the scripts in
this repository. The vocabulary is fixed:

| Line form | Meaning |
|---|---|
| `gate ELIGIBLE` / `gate BLOCKED` | the gate's verdict for that node |
| `stage1 watermark applied reads 0` | the drop-in was written and the kernel reads back 0 |
| `stage1 watermark noop reads 0 standard-file yes` | already in the standard state; nothing written |
| `stage1 snapd applied service inactive socket inactive` | both units stopped |
| `stage1 snapd noop ...` | already stopped, or not installed |
| `stage2 attic noop state ready ... lent_mib 0` | daemon already installed and validated; no installer run |
| `stage2 attic installed state ... lent_mib <n>` | installed, but something borrowed the carveout: `--apply` refuses that node, and a plan says so instead |
| `FAIL attic: lent_mib 'N', wanted 0 ...` | a borrow exists where stage 2 leaves none; find the consumer (step 7) |
| `verify attic ok state ready validated true size_mib <n> lent_mib 0 ...` | the only acceptable stage 2 end state |
| `verify serving ok 200` | the declared health endpoint answered |
| `verdict APPLIED-OR-NOOP` | that node's stage run finished clean |
| `node verdict OK` / `BLOCKED` / `FAIL` / `SKIPPED` | per-node result |
| `RESULT: ...` | the run's overall result, followed by the exit code |

Exit codes: `0` every node clean, `1` at least one node failed or was
blocked, `2` usage error, `3` no failures but at least one node was skipped
(no ssh, or no `sudo -n`). A skipped node never hides a failure: if any node
failed or was blocked the run exits `1`, not `3`.

## Appendix B — the whole stop list on one page

1. `--self-test` did not pass.
2. An inventory error: duplicate, more than two fields, no nodes.
3. SSH or `sudo -n` prompted or failed on a node.
4. The gate printed `BLOCKED` for a node — use the table in step 4.
5. A `FAIL` line in `--dry-run`, `--apply` or `--verify` that step 7 or step 8
   does not account for. (The four attic checks on a node you deliberately
   left at stage 1 are not a fault; verify those with `--verify --stage 1`.)
6. `lent_mib` is not `0` after stage 2.
7. Anything asks you to change an engine variable, a recipe, a container
   or a kernel. That is stage 3 or another document; stop.

## Appendix C — proving the tooling without a GB10

Both scripts decide their behaviour from files, so both can be tested on a
laptop with no NVIDIA hardware and no fleet:

```bash
bash tests/carveout-gate-selftest.sh    # gate verdicts, including the lender socket
bash tests/apply-selftest.sh            # dry-run, apply, idempotency, rollback
```

**Expect** `PASS: every gate case matched` and
`PASS: every apply case matched`. These are the same checks a reviewer
runs against a change to either script; they use fixture roots under
`tests/fixtures/` and never touch a real node or the network.
