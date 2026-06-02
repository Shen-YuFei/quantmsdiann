# Version-dependent precursor q-value default (DIA-NN)

**Date:** 2026-06-02
**Status:** Design — approved approach, pending spec review

## Problem

DIA-NN's recommended **precursor-level** q-value (FDR) threshold changed across
versions. Older versions (through 2.3.2) are run at a 1% precursor q-value;
DIA-NN **2.5+** is recommended to run at a 5% precursor q-value. In this
pipeline the precursor q-value is a single static default:

```
precursor_qvalue = 0.01   // nextflow.config
```

It is applied in two places:

- `modules/local/diann/final_quantification/main.nf` → `--qvalue $params.precursor_qvalue`
  (DIA-NN main-report precursor threshold)
- `modules/local/diann/diann_msstats/main.nf` → `--qvalue_threshold $params.precursor_qvalue`
  (precursor q-value used when converting the report to MSstats input)

A fixed 0.01 means DIA-NN 2.5+ runs are not using the recommended 5% precursor
threshold, and a user must remember to set it per version.

## Scope

In scope:

- Make the **precursor-level** q-value default depend on `params.diann_version`.
- This is **only precursor-level filtering** — the `--qvalue` flag and the
  MSstats precursor `--qvalue_threshold`, which both already read
  `precursor_qvalue`. Both continue to follow the same (now version-aware) value.

Out of scope (unchanged):

- Matrix-level thresholds `matrix_qvalue` (0.01) and `matrix_spec_q` (0.05),
  which control the protein/gene matrices independently.
- The QPX export q-value (`matrix_qvalue`).
- Any change to how DIA-NN computes or reports q-values.

## Version → precursor q-value mapping

| `diann_version` | resolved `precursor_qvalue` |
| --------------- | --------------------------- |
| `< 2.5` (1.8.1, 2.1.0, 2.2.0, 2.3.2) | `0.01` (1%) |
| `>= 2.5` (2.5.0 and later) | `0.05` (5%) |

Boundary expressed as `VersionUtils.versionLessThan(diann_version, '2.5')`.

An explicit `--precursor_qvalue <value>` always wins, regardless of version.

## Design (Approach A: runtime resolver)

Mirror the existing `VersionUtils.isNativeRawMode(params)` pattern: a `null`
default means "auto / resolve by version", an explicit value overrides, and the
resolution lives in one place.

### 1. `nextflow.config`

Change the default from `0.01` to `null` and document the auto behavior:

```groovy
precursor_qvalue        = null   // --qvalue precursor q-value; null = auto by
                                 // diann_version (<2.5 -> 0.01, >=2.5 -> 0.05).
                                 // Set explicitly to override.
```

### 2. `lib/VersionUtils.groovy`

Add a resolver:

```groovy
/**
 * Resolve the precursor-level q-value (DIA-NN --qvalue / MSstats
 * --qvalue_threshold) for the configured DIA-NN version.
 *
 * Explicit params.precursor_qvalue always wins. Otherwise DIA-NN's
 * version-dependent recommendation applies: 1% (0.01) for versions before
 * 2.5, 5% (0.05) for 2.5 and later.
 *
 * @param params Nextflow params map (needs diann_version, precursor_qvalue)
 * @return the q-value as a Number/String suitable for the DIA-NN flag
 */
static resolvePrecursorQvalue(params) {
    if (params.precursor_qvalue != null) return params.precursor_qvalue
    def version = params.diann_version?.toString() ?: '1.8.1'
    return versionLessThan(version, '2.5') ? 0.01 : 0.05
}
```

### 3. `nextflow_schema.json`

The current entry is `{"type": "number", "default": 0.01}`. Since the param
default becomes `null` ("auto"):

- Allow null: set `"type": ["number", "null"]` and drop the `"default"` (or set
  it to `null`), so nf-schema validation accepts the unset/auto state.
- Update `description`/`help_text` to: precursor-level q-value; default is
  auto by `diann_version` (`< 2.5` → 0.01, `>= 2.5` → 0.05); set explicitly to
  override.

### 4. Consuming modules

In both module `script:` blocks, resolve once and interpolate the local:

- `modules/local/diann/final_quantification/main.nf`
  ```groovy
  def precursor_qvalue = VersionUtils.resolvePrecursorQvalue(params)
  ...
  --qvalue ${precursor_qvalue} \
  ```
- `modules/local/diann/diann_msstats/main.nf`
  ```groovy
  def precursor_qvalue = VersionUtils.resolvePrecursorQvalue(params)
  ...
  --qvalue_threshold ${precursor_qvalue} \
  ```

`VersionUtils` is auto-loaded from `lib/`, so no import is needed (consistent
with current usage in these modules).

## Behavior / data flow

1. User runs e.g. `-profile diann_v2_5_0` (sets `diann_version = '2.5.0'`) or
   `--diann_version 2.5.0`, and does **not** set `--precursor_qvalue`.
2. Each consuming module calls `resolvePrecursorQvalue(params)` →
   `precursor_qvalue == null` → `versionLessThan('2.5.0','2.5')` is false → `0.05`.
3. For 1.8.1 / 2.1.0 / 2.2.0 / 2.3.2 the same path yields `0.01`.
4. If the user passes `--precursor_qvalue 0.02`, the resolver returns `0.02` for
   any version.

## Error handling / edge cases

- `diann_version` unset: resolver falls back to `'1.8.1'` (same default used by
  `isNativeRawMode`), giving `0.01`.
- Non-numeric / malformed version: `VersionUtils.compare` already treats
  non-integer components as `0`, so it degrades gracefully (no exception).
- `precursor_qvalue` explicitly `0` or `0.0`: treated as an explicit override
  (not null), so it is used as-is.

## Testing

- **Unit (VersionUtils):** if a groovy/spock test harness exists for `lib/`,
  add cases: 1.8.1→0.01, 2.3.2→0.01, 2.5.0→0.05, 2.6→0.05, explicit override
  wins, null/blank version→0.01. Otherwise document expected values here and
  rely on the integration profiles below.
- **Integration:** existing `test_dia` (default version 1.8.1) must still emit
  `--qvalue 0.01`. Add/confirm a `test_dia_2_2_0` / `test_latest_dia` (2.5.0)
  path resolves `--qvalue 0.05`. Verify by inspecting the DIA-NN command line in
  the `.command.sh` of `final_quantification` for each version.
- **Regression:** confirm `diann_msstats` uses the same resolved value and that
  matrix thresholds are unchanged.

## Documentation

- Update `docs/parameters.md` (or the schema description for `precursor_qvalue`)
  to state the default is auto/version-dependent with the mapping above.
- Note the change in `CHANGELOG.md` under the current dev section.

## Files touched

- `nextflow.config` (default → null + comment)
- `lib/VersionUtils.groovy` (add `resolvePrecursorQvalue`)
- `modules/local/diann/final_quantification/main.nf`
- `modules/local/diann/diann_msstats/main.nf`
- `nextflow_schema.json` / `docs/parameters.md` (description)
- `CHANGELOG.md`
