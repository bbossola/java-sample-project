# java-sample-project

A QA sample project demonstrating Meterian dependency scanning and automated
remediation. It is a demo repository, not production code: the dependencies and
branches exist to exercise the scanner, not to build anything useful.

## Layout

- `pom.xml` — a deliberately minimal Maven project
- `scripts/meterian-autofix.sh` — clone → autofix → branch → push → optional PR
- `src/` — a token class so the project compiles

## Branches

- `master` — clean, up-to-date dependencies. Running the autofix script against
  it should report "nothing to fix" and exit 0. Useful as the no-op test case.
- `vulnerable-demo` — carries deliberately vulnerable dependencies
  (commons-collections 3.2.1, jackson-databind 2.9.8, log4j-core 2.17.0). This
  is the branch to demo the autofix script against. Do not "fix" these
  dependencies on this branch; being vulnerable is its entire purpose.

## Decisions

**Fixes are detected from `git status`, never from the client's exit code.**
The Meterian client exits non-zero whenever the security score is below the
minimum threshold, which is exactly the situation where it has just applied
fixes. Verified against `vulnerable-demo`: the default `safe` strategy exits 1
having fixed one dependency, `conservative+vulns` exits 0 having fixed three.
Branching on either exit code value gets one of those cases wrong. If you are
tempted to "simplify" the script by checking `$?`, this is why you should not.

**Preflight checks run before any work.** Missing tools, an unset
`METERIAN_API_TOKEN`, and an unauthenticated `gh` are all caught up front, so
the script never scans for several minutes and only then discovers it cannot
push or open the PR.

**Pull requests are opt-in and require `gh`.** The script's default output is a
pushed branch, which works against any remote — GitHub, GitLab, Bitbucket,
internal. `--pull-request` adds `gh pr create` and hard-fails if `gh` is absent
or unauthenticated, rather than silently degrading.

**The script refuses to push onto the source branch.** If `--fix-branch`
resolves to the branch that was cloned, it aborts. Autofix output always lands
on a separate branch for review.

**The client's cosmetic XML damage is left alone.** Its rewriter joins the
`<?xml ...?>` declaration onto the `<project>` line and strips the trailing
newline. Post-processing that would mean the script edits manifests behind the
client's back; the noise in the diff is the lesser evil.

**The CI workflow was removed deliberately.** There was a `on: push` GitHub
Action running a Meterian scan on every branch. It was dropped so the autofix
script is the only thing invoking the client — a scan firing on every push made
demo runs confusing. Do not re-add it without asking.

**Demos use `conservative+vulns`, not `aggressive`.** All three vulnerable
demo dependencies are fixed by minor bumps, so `conservative` and `aggressive`
produce byte-identical output and the same 0 → 100 score. Recommending
`aggressive` where `conservative` suffices tells customers to accept major
version upgrades for nothing. Escalate strategy only when the weaker one
demonstrably leaves vulnerabilities unfixed.

## Conventions

- The script targets bash with `set -euo pipefail`; keep it dependency-free
  beyond `git`, `java`, `mvn`, `curl` (and `gh` for `--pull-request` only).
- Verify changes to the script by actually running it against `vulnerable-demo`
  with `--dry-run`, not just by reading it. The interesting behaviour is in how
  the client and git interact, which no amount of inspection reveals.
