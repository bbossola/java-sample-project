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
having fixed one vulnerability, `conservative` exits 0 having fixed all three.
Branching on either exit code value gets one of those cases wrong. If you are
tempted to "simplify" the script by checking `$?`, this is why you should not.

**A hard client error is fatal; a failed quality gate is not.** Exit codes 1-7
are a bitmask of failed gates (1 security, 2 stability, 4 licensing) and are the
normal outcome once autofix has changed something. Negative codes are hard
errors and reach the shell as 256+code -- 255 is "no authorisation found". The
first version of the script treated every non-zero code alike, so an on-premises
run with a rejected token printed "nothing to fix" and exited 0. A broken scan
reported as a clean repository is the worst failure mode this script has; keep
the classification in `client_error` and never widen it back.

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

**The cached client jar is refreshed on every run.** `resolve_client` does a
conditional GET (`curl -z` plus `-R`) rather than downloading only when the file
is absent. The first version of this script cached forever, and the demo was
consequently run with a jar nine months stale — which produced a reformatted
`pom.xml` and a README note claiming the client mangles XML. It does not: the
client applies fixes as targeted text edits from 1.2.41 onwards. Never
reintroduce a download-if-missing cache; a security scanner pinned to an old
build is worse than a slow one.

**The CI workflow was removed deliberately.** There was a `on: push` GitHub
Action running a Meterian scan on every branch. It was dropped so the autofix
script is the only thing invoking the client — a scan firing on every push made
demo runs confusing. Do not re-add it without asking.

**Demos use bare `conservative`.** All three vulnerable demo dependencies are
fixed by minor bumps, so `aggressive` fixes nothing extra and only invites major
upgrades — escalate strategy only when the weaker one demonstrably leaves
vulnerabilities unfixed. The reach is deliberately omitted: bare `conservative`
also refreshes merely-outdated dependencies (it bumps commons-lang3 3.18.0 →
3.20.0, stability 97 → 100), which was accepted as the friendlier default over
the narrower `conservative+vulns`. Use `+vulns` when a diff limited strictly to
CVE fixes matters more than brevity.

**The client download URL is configurable, and the cache is keyed by host.**
Dedicated and on-premises instances serve their own pre-configured jar; there is
no env var that repoints the public client at a private server. `METERIAN_CLI_URL`
selects it and the cache lives in `~/.meterian/<host>/`, so a user who works
against both a private instance and the public cloud cannot end up scanning with
the wrong client. Tokens are per-instance too and are not interchangeable.

## Conventions

- The script targets bash with `set -euo pipefail`; keep it dependency-free
  beyond `git`, `java`, `mvn`, `curl` (and `gh` for `--pull-request` only).
- Verify changes to the script by actually running it against `vulnerable-demo`
  with `--dry-run`, not just by reading it. The interesting behaviour is in how
  the client and git interact, which no amount of inspection reveals.
