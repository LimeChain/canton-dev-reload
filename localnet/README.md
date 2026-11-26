# LocalNet runs (coordinated purge reload)

Scripts for the `LN*` rows in `evidence/INDEX.md` and `docs/test-plan-multinode-purge.md`.

Prerequisite: a CN QuickStart checkout at `.qs/quickstart`, pinned to commit `8b898ed`
(Splice 0.6.11), Docker running, and at least 8 GB free disk:

    git clone https://github.com/digital-asset/cn-quickstart .qs && git -C .qs checkout 8b898ed

- `ln-run.sh <script.canton>` runs a console script (prefixed with `ln-lib.canton`) in a Canton 0.6.11
  container on the `localnet` Docker network.
- `ln-timing.sh` is the alternating reload-vs-restart runner (LN3). `LN_CONFIRM_S=5 LN_REACT_S=5` gives
  the dev-tuned variant. It refuses to run on battery unless `LN_ALLOW_BATTERY=1`.
- `ln-ln5.sh` runs the long rate-0 hold, Splice side effects and the one-sided purge control (LN4, LN6).
- `ln-ln7.sh` runs a reload on a fresh LocalNet and checks commitments after the next 30-minute tick (LN5).
- `ln-logcap.yaml` caps container logs; the SV app's sequencing-parameter trigger is very noisy.

Console state and outputs go to `localnet/state/` (gitignored).
