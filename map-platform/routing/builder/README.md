# Planet builder

These scripts build the whole-planet bicycle graph on a temporary Google Cloud
VM, from the download to the elevation gate, with nobody watching. The
[refresh runbook](../refresh-runbook.md#build-on-an-ephemeral-vm) has the
procedure. This page says what each piece does and how it fails.

The planet builds of 2026-11-24 to 2026-11-26 were run from scripts written
by hand on the builder and deleted with it. Each failure of those runs has a
guard here (see [Past failures](#past-failures-and-what-covers-them)).

## What runs where

| File | Runs on | What it does |
|---|---|---|
| `provision.sh` | where `gcloud` is signed in | Prints, and with `--create` runs, the commands for the job's network, firewall rule and VM. `--host-key` reads the VM's SSH host key from its serial console. |
| `teardown.sh` | the same place | Prints, and with `--delete` runs, the deletion, then fails unless nothing is left. |
| `setup.sh` | the builder, piped over SSH | Masks package upgrades, installs packages, stripes the local SSDs, checks out the tools at one commit, writes `builder.env`, installs the chain. |
| `install-chain.sh` | the builder | Installs the systemd units and, with `--start`, starts the chain. |
| `units/` | the builder | One unit per stage, the result unit and the sampler. |
| `run_stage.py` | the builder | Runs one stage and records its state. |
| `stages/` | the builder | The stage scripts. |
| `chain_state.py` | the builder | Reads the stages' markers, prints the chain's state, writes `export/result.json`. |
| `qualification.py` | the builder | Judges one archive's probes. |
| `sampler.sh` | the builder | Scratch and memory use every 30 seconds, with their peaks. |
| `authorize-export-key.sh` | the builder | Lets one SSH key read `export/` with rsync and nothing else. |
| `builder_status.py` | the map VPS, or a laptop | Asks the builder for the chain's state. |
| `rehearse.sh`, `rehearse.py` | any machine with Docker | Runs the chain on one city sample, without systemd or a builder. |
| [`elevation-cache-proposal.md`](elevation-cache-proposal.md) | | A proposal to keep elevation tiles between builds. Not decided. |

Every path on the builder is absolute and below `/srv/bicino-routing-scratch`:

- `builder.env`: the run's settings, read by systemd and by the scripts.
- `tools/repo/`: the tools, checked out at the run's commit.
- `input/`, `elevation-raw/`, `elevation/`, `audit/`, `build/planet-ungraded/`, `build/planet-graded/`: the work.
- `export/`: everything the VPS may read. `result.json`, `chain/` (markers), `logs/` (one log per stage and the sampler's series), `evidence/` (probe reports, the gate report, manifests), and `ungraded/` and `graded/` (each archive's manifest and a hard link to the archive).

## The chain

```text
images ──┬─ inputs ─────────────────────┬─ qualify-ungraded ─┐
         ├─ elevation ─┐                │                    │
download ┼─────────────┴─ build-graded ─┼─ qualify-graded ───┴─ gate ─ result
         └─ build-ungraded ─────────────┘
```

| Stage | Work | Time on a `c4-highmem-24-lssd` |
|---|---|---|
| `images` | Pull the pinned Valhalla and map-platform images. | 1 min |
| `download` | Download the planet, check its published MD5, record its SHA-256. | 35 min |
| `inputs` | Download the pinned Natural Earth layers and write the audit's inventory. | 1 min |
| `elevation` | Write the raw Copernicus tiles, then open them. Runs `build_elevation.py` up to four times: each run resumes from the receipts. | 2 h 20 min |
| `build-ungraded` | `build_graph.py --coverage planet`. | 3 h 25 min alone, 4 h 50 min beside the graded build |
| `build-graded` | The same with `--elevation`. | 4 h 50 min |
| `qualify-ungraded`, `qualify-graded` | Smoke probes, cross-border probes, the territory audit and the profile probe, with no network. | under 1 min each |
| `gate` | Serve both archives and run `compare_elevation.py` over every city. | 1 min |
| `result` | Write `export/result.json` and link the archives into `export/`. | seconds |

The times are from the 2026-11-25 and 2026-11-26 builds. The whole chain
takes about 7.5 hours. Without `--opening-radius` the run builds only the
ungraded planet, the graph production serves: `elevation`, `build-graded`,
`qualify-graded` and `gate` are skipped, and it takes about 4 hours.

A stage starts when every stage it needs is done or skipped. systemd orders
the units and starts independent stages together; `run_stage.py` enforces the
rule itself, so it also holds when a unit is started by hand.

Each stage's state is in `export/chain/STAGE.json`:

```json
{"stage": "elevation", "state": "failed", "attempt": 1,
 "startedAt": "2026-11-26T05:44:11Z", "finishedAt": "2026-11-26T06:21:38Z", "seconds": 2247,
 "exitStatus": 1, "reason": "the stage script exited with status 1",
 "log": "logs/elevation.log", "logTail": ["..."]}
```

`state` is `running`, `done`, `skipped` or `failed`. While a stage runs, its
wrapper holds a lock. A marker that says `running` without the lock is
reported as `interrupted`: the wrapper was killed, or the machine restarted.

The chain's state is one of:

| State | Meaning |
|---|---|
| `not-started` | No stage has a marker. |
| `running` | A stage is running, or the next is about to start. |
| `failed` | A stage failed or was interrupted. Stages that need it are `blocked` and never start. A stage that does not need it and was already running finishes its own work, so that a retry has less to do. |
| `stalled` | Nothing is running, nothing failed, and stages are still waiting for more than two minutes. systemd is not driving the chain. |
| `complete` | Every stage is done or skipped. `verdict` is the gate's answer: `met`, `missed`, or `not-run` for an ungraded build. |

A gate that misses a target is a complete chain with the verdict `missed`,
not a failed stage. The gate stage fails only when the comparison could not
be made.

`export/result.json` is rewritten at every change, so it always holds the
current state. Once the chain ends it also holds both archive manifests, both
elevation manifests, each archive's qualification summary and the gate
summary, with `"final": true`.

## Ask where a build stands

```sh
python3 builder_status.py --ssh-config /root/.ssh/bicino-valhalla-JOB.d/config
python3 builder_status.py --via root@VPS --ssh-config /root/.ssh/bicino-valhalla-JOB.d/config --wait
```

The first form runs on the VPS, the second on a laptop. It prints the chain's
state and one line per stage, and exits with:

| Exit | Meaning |
|---|---|
| 0 | Complete, and the gate met its targets or was not run. |
| 3 | Running. |
| 4 | Complete, and the gate missed a target. |
| 5 | A stage failed, or the chain stalled. |
| 6 | Not started. |
| 7 | No usable answer: SSH failed, timed out, or returned something else. |

The builder needs nobody watching, so a watcher only observes. It must never
take silence for progress: exit 7 prints `chain: UNREACHABLE, not known to be
running` and whatever SSH said, for example the link of a Tailscale
re-authentication. `--wait` polls while the chain is running and stops at the
first other answer, including exit 7. Run it again once the connection works.

## When a stage fails

1. Read the stage's line in the status and its log, `export/logs/STAGE.log`.
2. Fix the cause.
3. Start the chain again: `sudo systemctl start --no-block bicino-planet-result.service`.

A restart runs the failed stage and everything that was waiting for it.
Finished stages are not run again. The download resumes, the elevation stage
continues from its receipts, and a graph build starts over after removing
what the failed attempt left.

To run a finished stage again, delete its marker and restart its unit:

```sh
rm /srv/bicino-routing-scratch/export/chain/gate.json
sudo systemctl restart bicino-planet-gate.service
```

Do not restart the unit of a stage while another stage that needs it is
running, and do not edit the tools under `tools/repo/`: the result names the
commit they came from.

## Past failures and what covers them

| What happened | What covers it now |
|---|---|
| 2026-11-25: a laptop loop that waited for the builds threw away SSH's errors and read every empty reply as "still running". The VPS was asking for a Tailscale re-authentication. The builder sat idle for about 8 hours. | The builder runs every stage itself. `builder_status.py` exits 7 on anything but a well-formed answer. |
| A desktop session restart dropped every watcher in the middle of a build. | Nothing on the builder depends on a session. The gate and the result follow the builds without one. |
| 2026-11-26: 38 minutes after boot, Ubuntu's `apt-daily-upgrade` upgraded packages and `needrestart` restarted the build units. The scripts ran again from their first lines: one build failed on its existing directory, and the elevation run collided with its own container. | `setup.sh` masks the apt timers and services before it installs anything, and `install-chain.sh` refuses to start otherwise. `needrestart` only lists services. A finished stage is never run again, and a stage removes its leftover containers and unfinished build before it starts. |
| 2026-11-25: `build_elevation.py` stopped when the third round of one run lost a worker to the 15-minute cell deadline, and waited for someone to run it again. | The elevation stage runs it up to four times. |
| 2026-11-25: Docker took `build/planet-no-elevation/valhalla_tiles.tar` for a volume name and refused it. | Every path comes from `config.sh`, which rejects a relative scratch path. A test checks every mount. |
| The hand-written qualification and gate scripts waited up to 180 seconds for Valhalla and then went on whether it answered or not. This never fired. | The wait fails the stage when Valhalla does not answer. |
| Every run: the gate ran last, by hand, after about 7.5 hours. | The gate is a stage. On city samples it can run before a planet is built (see [Rehearse](#rehearse-on-a-city-sample)). |
| Every run: the elevation tiles were rebuilt, about 2 h 20 min, from data that does not change. | Not solved. See the [proposal](elevation-cache-proposal.md). |

## Rehearse on a city sample

```sh
map-platform/routing/builder/rehearse.sh --root /absolute/scratch --city Berlin --radius 200
```

This runs the real chain on one city of `elevation-probes.json`: its
Geofabrik extract instead of the planet, the elevation cells around its box,
two sample graphs, the smoke probes on its own legs and the gate on that city.
`rehearse.py` stands in for systemd. It reads the unit files, orders them by
their `After=` lines and runs each `ExecStart` as written. `--kill-stage
build-graded` kills that stage once, as a systemd timeout would, and starts
the chain again.

On 2026-11-26 Berlin at 200 m took 6.5 minutes on a laptop and gave the
result of the 2026-11-25 Berlin sample: 8 routes, the longest 1.1% longer,
targets met. It used 0.7 GB below the scratch directory; a city with a larger
extract needs more. In a second run the graded build was killed after 45
seconds. The stage was recorded as failed, its Valhalla container was
removed, and the restarted chain rebuilt the graph and finished.

The same day the seven tower cities ran at 400 m, 2 to 15 minutes each,
most of it the download of the extract. New York's sample missed the gate on
the leg the planet build missed it on (see
[Tower-city samples](../refresh-runbook.md#tower-city-samples)). A run
without `--radius` built only the ungraded sample and ended `complete` with
the gate `not-run`.

The rehearsal leaves out what needs a planet: the territory audit, the
cross-border probes and the profile probe. Its units run one after another.
Its result file says `"sample": true`. It is never release evidence.

- An extract already at `ROOT/input/` with the published size is not
  downloaded again.
- Run one rehearsal at a time on a Docker host. The containers' names and
  stage labels do not carry the scratch directory, so a second run would
  remove the first one's containers.
- Without `--map-platform-image` the pinned image is pulled, about 2 GB.

## Not verified on a real builder

These scripts were written on 2026-11-26 without a builder. The stage scripts,
the wrapper, the markers, the result file and the unit files' order ran in
the rehearsal, in Ubuntu 24.04 containers. What only a real builder can show:

- **systemd itself.** That `Wants=` and `After=` start independent stages
  together and the result unit last, that `ExecStopPost=` gets
  `SERVICE_RESULT` after a timeout, and that `TimeoutStartSec=` values fit.
- **`setup.sh`.** Masking the apt units on a fresh image, the wait for a
  running upgrade, the RAID 0 over the four local SSDs. Its commit checkout
  was tested against GitHub. The RAID commands are those of the 2026-11-26
  builder.
- **`provision.sh` and `teardown.sh` against Google Cloud.** Their commands
  are those that created and deleted the 2026-11-25 and 2026-11-26 builders.
  Tests ran them against a stand-in `gcloud`.
- **`authorize-export-key.sh`.** The `bicino-export` user, the path of
  `rrsync` on Ubuntu 24.04, and a pull through it by `stage_graph.py`.
- **`sampler.sh` and `inputs`, the qualification stage's cross-border, audit
  and profile checks at planet size**, and all planet-scale times, disk and
  memory. The sampler is not part of the rehearsal.
- **`builder_status.py` over real SSH**, through the VPS and with a Tailscale
  re-authentication pending. Tests fed it those replies.

On the first real build, start the chain and stay for the first ten minutes:
`images`, `download`, `inputs` and `elevation` should all be running or done,
and `systemctl list-jobs` should show the later stages waiting.
