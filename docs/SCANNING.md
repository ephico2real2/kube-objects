# Scanning: what CI blocks on, and what we track

Two different jobs, deliberately using two different thresholds.

| | CI gate | local scan |
|---|---|---|
| script | `.github/workflows/publish-image.yaml` | `ci_scripts/scan-local.sh` |
| blocks on | **fixable CRITICAL/HIGH** | nothing — reports only |
| records | SARIF to the Security tab | dated markdown in `trivy-local-scan/` |
| question it answers | may this be published? | what have we chosen to defer? |

## Why the gate ignores unfixed findings

The UBI base carries thousands of findings with no upstream fix. A gate that blocked on those could
never pass, and a gate that can never pass gets switched off. So it blocks only on what a rebuild can
actually close: `--ignore-unfixed --severity CRITICAL,HIGH`.

That is the right call for a release gate and the wrong call for planning, which is what the local scan
is for.

## Local scan

```sh
docker/build.sh                       # build first
ci_scripts/scan-local.sh              # scan and record
ci_scripts/scan-local.sh <image:tag>  # or scan a specific image
```

Writes `trivy-local-scan/<date>-<version>-g<sha>.md` plus the raw gate and full JSON alongside it. The
report carries the exact commands used, so any number in it can be reproduced.

**Read the FIXABLE column, not the total.** An unfixable finding cannot be closed by any rebuild, so it
is noise for planning. A fixable MEDIUM is a decision someone made to defer — and a deferral nobody
writes down is work nobody does.

**Keep the files.** The dated history is the point: when a previously-unfixable finding gains an
upstream fix, it moves into the fixable column on the next scan, and the diff between two dated reports
is the only thing that shows it. Do not clean the folder out.

## Keep local and CI on the same trivy

CI pins the trivy **binary** to a version (`version:` on the trivy-action step; the action's own default
lags). `scan-local.sh` prints both and warns when they differ. A different scanner version legitimately
produces different counts, and chasing a diff that turns out to be a version difference wastes an
afternoon.

```sh
brew upgrade trivy
```
