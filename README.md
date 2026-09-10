# java-sample-project

A sample Java project used to showcase the Meterian scanner.

## Automated dependency remediation

`scripts/meterian-autofix.sh` clones a repository, runs the
[Meterian thin client](https://docs.meterian.io/the-client/client) with
`--autofix`, and pushes any resulting dependency fixes on a new branch.

```bash
export METERIAN_API_TOKEN=<your token>

# fix the default branch, push the fixes on a timestamped branch
./scripts/meterian-autofix.sh git@github.com:you/your-repo.git

# fix a specific branch, allow minor version bumps, and open a pull request
./scripts/meterian-autofix.sh git@github.com:you/your-repo.git \
    --branch develop --autofix conservative --pull-request

# see what would change without pushing anything
./scripts/meterian-autofix.sh git@github.com:you/your-repo.git --dry-run
```

Run `./scripts/meterian-autofix.sh --help` for all options.

The script needs `git`, `java`, `mvn` and `curl`; `--pull-request` additionally
needs an authenticated [`gh`](https://cli.github.com). The client jar is cached
in `~/.meterian/` and refreshed whenever a newer one is published.

### Try it on this repository

This repository is set up to demonstrate the script. Its `vulnerable-demo`
branch carries three deliberately vulnerable dependencies — `commons-collections`
3.2.1, `jackson-databind` 2.9.8 and `log4j-core` 2.17.0 — which score 0 out of
100 on security.

```bash
git clone git@github.com:bbossola/java-sample-project.git
cd java-sample-project
export METERIAN_API_TOKEN=<your token>

# 1. see what would change, without touching anything
./scripts/meterian-autofix.sh git@github.com:bbossola/java-sample-project.git \
    --branch vulnerable-demo --autofix conservative --dry-run

# 2. the real thing: push the fixes on a new branch and open a pull request
./scripts/meterian-autofix.sh git@github.com:bbossola/java-sample-project.git \
    --branch vulnerable-demo --autofix conservative --pull-request
```

The second command clones the branch into a temporary directory, runs the
client, finds that `pom.xml` was changed, commits it on a new branch named
`meterian-autofix-<timestamp>`, pushes it, and prints the URL of the pull
request it opened. The security score goes from 0 to 100. Nothing is written to
your working copy — the script works entirely in its own clone.

You need push rights on the repository for step 2; fork it first and use your
own fork's URL otherwise. Step 1 needs only read access.

To see the other outcome, run it against `master`, whose dependencies are
current:

```bash
./scripts/meterian-autofix.sh git@github.com:bbossola/java-sample-project.git
```

It reports `no manifests were changed: nothing to fix` and exits 0, creating no
branch. That is the normal result on a healthy repository, and it is what makes
the script safe to run on a schedule.

### Dedicated and on-premises instances

A dedicated or on-premises Meterian instance serves its **own pre-configured
client**: there is no environment variable that repoints the public client at a
private server. Set `METERIAN_CLI_URL` to your instance's download endpoint, and
use a token issued by that instance — a meterian.com token will not authenticate
against it.

```bash
export METERIAN_CLI_URL=https://your-instance.example.com/downloads/meterian-cli.jar
export METERIAN_API_TOKEN=<a token from your instance>

./scripts/meterian-autofix.sh git@github.com:you/your-repo.git --autofix conservative
```

Jars are cached per host under `~/.meterian/<host>/`, so switching between
instances never reuses the wrong client. To check which instance a client talks
to, run it directly: `java -jar meterian-cli.jar --help` prints the server and
the account it is authorized for. If your instance uses a certificate from a
private CA, pass `--use-ssl-certificates=/path/to/cert.pem`; the client picks up
`http_proxy` and `https_proxy` on its own. See the
[dedicated instance documentation](https://docs.meterian.io/dedicated-instance/using-the-scanners/thin-client).

### Why fixes are detected from git, not from the exit code

The client exits non-zero whenever the security score is below the minimum —
which is precisely the case in which it has just applied fixes. The exit code
therefore cannot tell you whether to branch, so the script decides on
`git status --porcelain` instead.

This is not a theoretical concern. Both of these runs applied fixes:

| Invocation | Client exit code | Fixes applied |
|---|---|---|
| `--autofix` (default `safe`) | `1` | 1 of 3 — score still below minimum |
| `--autofix conservative` | `0` | all 3 — score back above minimum |

A script that branched on `exit == 0` would miss the first; one that branched on
`exit != 0` would miss the second.

Not every non-zero code is a failed gate, though. The client returns a bitmask
of 1–7 when a quality gate fails (1 security, 2 stability, 4 licensing) and a
*negative* value on a hard error — a rejected token, an unsupported project, an
unreachable server — which reaches the shell as 256 plus that value. The script
treats anything above 7 as fatal and stops, because a scan that never ran must
never be reported as "nothing to fix": in a scheduled job that reads exactly
like a clean repository. See
[controlling the exit code](https://docs.meterian.io/the-client/using-client-ci-cd/controlling-the-exit-code).

### Choosing a strategy

The default is `safe+vulns,safe+dated+no-overrides`, which applies patch-level
updates only. Vulnerabilities whose fix needs a minor bump require
`--autofix conservative`. Measured against the `vulnerable-demo` branch:

| Strategy | commons-collections 3.2.1 | jackson-databind 2.9.8 | log4j-core 2.17.0 | Security score |
|---|---|---|---|---|
| `safe` (default) | → 3.2.2 | unchanged | unchanged | 0 |
| `conservative` | → 3.2.2 | → 2.22.2 | → 2.26.1 | 100 |

`conservative` also refreshes dependencies that are merely outdated rather than
vulnerable — on this branch it additionally bumps `commons-lang3` 3.18.0 → 3.20.0,
taking the stability score from 97 to 100 — and pins vulnerable transitive
dependencies by adding explicit overrides (here `jackson-core` and `log4j-api`).
Append a reach to narrow it to security fixes only (`conservative+vulns`), or
add `no-overrides` to stop it introducing new direct dependencies, if you would
rather keep the diff to what addresses a CVE.

Use the weakest strategy that clears your vulnerabilities: `--dry-run` answers
that in one pass without touching anything. There is also an `aggressive`
strategy permitting major upgrades, but it is rarely needed — here it fixes
nothing that `conservative` does not, since every fix required is a minor bump.
See the [autofix documentation](https://docs.meterian.io/the-client/command-line-parameters/advanced-options/autofix)
for the full set of strategies and reach options.

Always check that the build still passes before merging.

### Other notes

- The script refreshes the cached client jar on every run via a conditional
  GET, so it always scans with the currently published version. Client releases
  before 1.2.41 reformatted `pom.xml` while fixing it — rewriting the `<?xml ?>`
  declaration and dropping the trailing newline — which made autofix diffs noisy;
  1.2.41 onwards applies each fix as a targeted text edit and leaves the rest of
  the file byte-identical.
