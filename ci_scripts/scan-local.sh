#!/usr/bin/env bash
#
# Scan the locally-built image and record the result in trivy-local-scan/ so the MEDIUM backlog is
# tracked over time instead of re-discovered every pass.
#
# CANONICAL COPY, installed into all four forks as ci_scripts/scan-local.sh. Edit here, re-install.
#
# WHY THIS EXISTS SEPARATELY FROM CI. The CI gate deliberately blocks only on FIXABLE CRITICAL/HIGH —
# it has to, or the UBI base's thousands of no-fix findings would make it unpassable and everyone would
# switch it off. But "not a release blocker" is not "not a problem": a MEDIUM with a fix available is
# work we have chosen to defer, and deferred work that nobody writes down is work nobody does. These
# reports are the written-down version.
#
# WHAT IS ACTIONABLE. Read the FIXABLE column, not the total. An unfixable finding cannot be closed by
# any rebuild, so it is noise for planning; a fixable MEDIUM is a decision. When a previously-unfixable
# finding gains an upstream fix it moves into that column on the next scan, which is exactly what
# keeping dated history is for.
#
#   ci_scripts/scan-local.sh                 scan the tag build.sh would produce
#   ci_scripts/scan-local.sh <image:tag>     scan a specific image

set -euo pipefail
cd "$(dirname "$0")/.."

REPO_NAME="$(basename "$(pwd)")"
VERSION="$(tr -d '[:space:]' < VERSION)"
SHA="$(git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)"
IMAGE="${1:-ephico2real/${REPO_NAME}:${VERSION}-h1-g${SHA}}"

command -v trivy >/dev/null 2>&1 || { echo "ERROR: trivy not installed (brew install trivy)" >&2; exit 1; }
docker image inspect "${IMAGE}" >/dev/null 2>&1 || {
  echo "ERROR: ${IMAGE} not found locally. Build it first: docker/build.sh" >&2; exit 1; }

OUT_DIR="trivy-local-scan"
STAMP="$(date -u +%Y-%m-%d)"
mkdir -p "${OUT_DIR}"
BASE="${OUT_DIR}/${STAMP}-${VERSION}-g${SHA}"

# Keep the local scanner in step with CI. A different trivy version can legitimately produce a
# different finding count, and a diff that is really a scanner-version diff wastes an afternoon.
TRIVY_VER="$(trivy --version 2>/dev/null | head -1 | awk '{print $2}')"
CI_TRIVY="0.74.0"

echo "==> image:  ${IMAGE}"
echo "==> trivy:  ${TRIVY_VER}  (CI pins ${CI_TRIVY})"
[ "${TRIVY_VER}" = "${CI_TRIVY}" ] || echo "    NOTE: local and CI differ — counts may not match. brew upgrade trivy"

# THE EXACT COMMANDS ARE ECHOED AND RECORDED, so a number in a report can always be reproduced. A
# finding count with no command behind it is not evidence.
GATE_CMD="trivy image --scanners vuln --ignore-unfixed --severity CRITICAL,HIGH ${IMAGE}"
FULL_CMD="trivy image --scanners vuln --severity CRITICAL,HIGH,MEDIUM,LOW ${IMAGE}"

echo
echo "--> gate view (what CI enforces)"
echo "    ${GATE_CMD}"
trivy image --quiet --scanners vuln --ignore-unfixed --severity CRITICAL,HIGH \
  --format json -o "${BASE}-gate.json" "${IMAGE}"

echo "--> full view (everything, for the backlog)"
echo "    ${FULL_CMD}"
trivy image --quiet --scanners vuln --severity CRITICAL,HIGH,MEDIUM,LOW \
  --format json -o "${BASE}-full.json" "${IMAGE}"

REPORT="${BASE}.md" \
IMAGE="${IMAGE}" TRIVY_VER="${TRIVY_VER}" CI_TRIVY="${CI_TRIVY}" STAMP="${STAMP}" \
GATE_CMD="${GATE_CMD}" FULL_CMD="${FULL_CMD}" BASE="${BASE}" REPO_NAME="${REPO_NAME}" \
python3 - <<'PY'
import json, os, collections

base   = os.environ["BASE"]
report = os.environ["REPORT"]
gate = json.load(open(base + "-gate.json"))
full = json.load(open(base + "-full.json"))

def rows(doc):
    out = []
    for r in doc.get("Results") or []:
        for v in r.get("Vulnerabilities") or []:
            out.append({
                "sev": v["Severity"], "pkg": v["PkgName"], "id": v["VulnerabilityID"],
                "installed": v.get("InstalledVersion") or "", "fixed": v.get("FixedVersion") or "",
                "type": r.get("Type") or "", "title": (v.get("Title") or "")[:90],
            })
    return out

g, f = rows(gate), rows(full)
counts   = collections.Counter(x["sev"] for x in f)
fixable  = collections.Counter(x["sev"] for x in f if x["fixed"])

L = []
L.append("# Trivy local scan — %s\n" % os.environ["REPO_NAME"])
L.append("- **date:** %s" % os.environ["STAMP"])
L.append("- **image:** `%s`" % os.environ["IMAGE"])
L.append("- **trivy:** %s (CI pins %s)\n" % (os.environ["TRIVY_VER"], os.environ["CI_TRIVY"]))
L.append("## Commands\n")
L.append("```sh\n%s\n%s\n```\n" % (os.environ["GATE_CMD"], os.environ["FULL_CMD"]))

L.append("## Summary\n")
L.append("| severity | total | **fixable** |")
L.append("|---|---|---|")
for s in ("CRITICAL", "HIGH", "MEDIUM", "LOW"):
    L.append("| %s | %d | **%d** |" % (s, counts[s], fixable[s]))
L.append("| **all** | **%d** | **%d** |\n" % (sum(counts.values()), sum(fixable.values())))

L.append("**Gate (fixable CRITICAL/HIGH): %d — %s**\n"
         % (len(g), "PASSES" if not g else "BLOCKS, will not publish"))
if g:
    L.append("| severity | package | CVE | installed | fixed in |")
    L.append("|---|---|---|---|---|")
    for x in sorted(g, key=lambda x: (x["sev"], x["pkg"])):
        L.append("| %s | %s | %s | %s | %s |" % (x["sev"], x["pkg"], x["id"], x["installed"], x["fixed"][:40]))
    L.append("")

# The backlog: fixable MEDIUM/LOW. Deferred deliberately, listed so the deferral is a decision.
back = [x for x in f if x["sev"] in ("MEDIUM", "LOW") and x["fixed"]]
L.append("## Backlog — fixable MEDIUM/LOW (%d)\n" % len(back))
if back:
    L.append("Not release blockers, but each has a fix available, so each is a deferred decision rather")
    L.append("than an accepted risk. Group by package: one bump usually clears several.\n")
    by = collections.Counter(x["pkg"] for x in back)
    L.append("| package | findings | installed | fixed in |")
    L.append("|---|---|---|---|")
    for pkg, n in by.most_common():
        one = next(x for x in back if x["pkg"] == pkg)
        L.append("| %s | %d | %s | %s |" % (pkg, n, one["installed"], one["fixed"][:40]))
    L.append("")
else:
    L.append("None — every remaining MEDIUM/LOW has no upstream fix.\n")

nofix = sum(1 for x in f if not x["fixed"])
L.append("## Not actionable (%d)\n" % nofix)
L.append("No upstream fix exists, so no rebuild closes them. Tracked, not planned. They become")
L.append("actionable the day a fix ships — which is what the dated history in this folder is for.\n")

open(report, "w").write("\n".join(L) + "\n")
print("==> wrote %s" % report)
PY

echo
echo "==> history for this repo:"
ls -1 "${OUT_DIR}"/*.md 2>/dev/null | tail -5 | sed 's/^/    /'
