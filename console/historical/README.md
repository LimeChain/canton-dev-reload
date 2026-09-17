Historical console scripts — NOT reproducible.

These three back the "Approach 1" section of RESULTS.md (the compatible-version-bump results). They
load DARs from /private/tmp that no longer exist:

  upgrade-test.canton  /private/tmp/mirrors-101-compatible.dar
                       /private/tmp/mirrors-101-incompatible.dar
  forcebump.canton     /private/tmp/mirrors-101-incompatible.dar
  upg2.canton          /private/tmp/mirrors-102-incompatible.dar

No build recipe in this repository produces them: variants/ holds only Mirrors.v1/v2, which differ
by one line and both carry version 1.0.0, so neither can produce a 1.0.1 or 1.0.2 package.

The results they produced are recorded in RESULTS.md and are believed correct, but they cannot
currently be re-run. Restoring them needs tracked variant sources plus a version override in the
build step. Until then the Approach 1 results are historical, not reproducible, and are labelled as
such in RESULTS.md.

purge-pg.canton is also not reproducible as shipped. It needs a Postgres-backed sandbox, and
nothing here starts one: scripts/00-sandbox.sh hardcodes canton/sandbox.conf, and
canton/sandbox-pg.conf additionally requires a local postgres:16 with four separate databases that
no script or compose file creates. The repair.purge result recorded in RESULTS.md was obtained by
hand against such a sandbox and has no committed log.

Note /private/tmp in the three upgrade scripts is the macOS-canonical form of /tmp — it was the
author's scratch directory, not a path with any meaning.

Everything under console/ outside this directory is reproducible — see evidence/INDEX.md.
