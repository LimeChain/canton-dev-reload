# PQS fixtures

Prebuilt DARs used by the PQS rows. They are tracked, unlike the rest of the repo's build output,
because the rows compare package ids against `fixtures.tsv`, and a rebuild with another SDK would
change them. Built with `sdk-version: 3.5.5`.

| DARs | Built by | What differs |
|---|---|---|
| `A-g1`..`A-g4` | `build.sh` | `mirrors` 1.0.0, field `value` as Text, Int, Bool, Decimal: four breaking generations with the same name and version |
| `B-g1`..`B-g4` | `build.sh` | the same four types as 1.0.0..1.0.3: the reviewer's version bumps |
| `C-g2`, `C-g3` | `build-compat.sh` | `mirrors` 1.0.1 and 1.0.2, adding optional fields and a `Bump` choice: compatible (SCU) upgrades of `A-g1` |
| `items-v1` | the repo's `artifacts/items-v1.dar`, copied | an unrelated `items` package that is never reloaded; its contracts must survive every prune |
| `T-g1`, `T-g2`, `iface-api` | `dpm build` in `src/T-g1`, `src/T-g2`, `src/iface-api` | `things` (Text, then Int) implementing `LabelledApi:Labelled` from `iface-api`, which is never reloaded |

`src/` holds the exact sources each DAR was built from. `build.sh` rewrites `fixtures.tsv` from
scratch, so after running it run `build-compat.sh` and add the `T` rows back.
