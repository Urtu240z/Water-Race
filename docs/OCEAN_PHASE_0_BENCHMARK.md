# Ocean3D Phase 0 CPU benchmark

`benchmark_ocean_phase_0.tscn` establishes a reproducible CPU baseline for the
current Ocean3D implementation. It does not change Ocean3D, its shaders, water
physics, or graphics-quality behavior.

## Scope

The runner measures the existing API directly:

- `sample_height()`
- `sample_normal()`
- `sample_water()` with a reused `WaterSample3D`
- Four-query physics workloads representing one JetSki
- Sixteen-query physics workloads representing four JetSkis

Interaction scaling is isolated for:

- Ripples: 0, 6, and 12
- Navigable directional wake segments: 0, 4, 8, and 16
- Event waves: 0, 2, and 4
- Calm zones: 0, 2, and 4
- Combined typical and combined maximum snapshots

Every interaction case uses deterministic near and far paths. A long empty
control is measured immediately before and after every scenario. Each control
contains blocks of 256 consecutive `sample_water()` calls, making the stability
decision far less sensitive to a single scheduler migration than the real
four-query workloads.

Landing-impact arrays are not included in CPU query scaling. Their dedicated
state is evaluated by the water shader; the corresponding authoritative CPU
effect enters through the ripples created by a landing. Landing expiration and
uniform submission are still included in the maintenance measurements.

The maintenance section reports CPU submission or logic cost for expiration,
directional-bound reconstruction, and the existing uniform-push methods. It is
not a GPU-time measurement and it does not imply that every measured push runs
once per frame.

## Running it

From the `game` directory, run the scene directly with the intended Godot 4.7
binary:

```powershell
& "C:\path\to\Godot_v4.7.1-stable_win64_console.exe" `
  --headless `
  --path . `
  --log-file "C:\absolute\writable\path\ocean_phase_0.log" `
  "res://dev/benchmarks/benchmark_ocean_phase_0.tscn"
```

For a fast harness check rather than an accepted baseline, add:

```text
-- --quick
```

An optional sustained CPU preconditioning pass is available with:

```text
-- --precondition
```

Preconditioning is not enabled by default because it can increase variation on
thermally constrained hardware. The stability gate is the authority.

## Output

CSV and JSON reports are written to:

```text
res://.godot/ocean_benchmarks/
```

Each report records the Git revision and dirty state, Godot version, processor,
graphics profile, renderer, physics frequency, image layout, command line,
iteration counts, and benchmark methodology.

Throughput percentiles are per-chunk averages. Physics workload percentiles are
complete four- or sixteen-query observations. Those real workloads are retained
unchanged because they represent one and four JetSkis.

The JSON stores all long controls separately and embeds the immediately
adjacent before/after control values in each scenario row. The CSV contains the
same controls plus these local-normalization columns:

- Empty median immediately before and after the scenario
- Their local reference average and relative drift
- Scenario median per query divided by that local empty reference, where the
  measured metric is `sample_water()` or a 4/16-query water workload

## Stability gate

Completing the runner and obtaining valid fixture counts produces:

```text
OCEAN_PHASE_0_BENCHMARK=PASS
```

That does not automatically make the timing data acceptable. An accepted run
must also produce:

```text
OCEAN_PHASE_0_STABLE=true
```

The stability gate uses only the medians of the long empty controls and requires
them to remain within a 25% relative spread. The four- and sixteen-query
workloads never decide whether a session is stable. Their linearity ratios are
still stored as diagnostics.

If the gate fails, keep the report as diagnostic evidence but do not compare it
against later optimizations. Do not loosen the 25% threshold merely to obtain a
passing result; investigate the long-control data and the local before/after
drift first.

## Deliberately separate work

The following remain separate because this runner cannot measure them
authoritatively:

- GPU deformation, foam, SSR, underwater, and directional-segment A/B captures
- Gold City boat-traffic source collection and local wake maintenance
- LOW/MEDIUM/HIGH visual and behavioral consistency
- Candidate raw-buffer, unified-query, or batch-query implementations

Use the existing Gold City traffic-wake benchmark for the current boat path and
manual controlled captures for GPU Phase 0D.
