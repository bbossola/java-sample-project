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
    --branch develop --autofix "conservative+vulns" --pull-request

# see what would change without pushing anything
./scripts/meterian-autofix.sh git@github.com:you/your-repo.git --dry-run
```

Run `./scripts/meterian-autofix.sh --help` for all options.

The script needs `git`, `java`, `mvn` and `curl`; `--pull-request` additionally
needs an authenticated [`gh`](https://cli.github.com). The client jar is
downloaded once and cached in `~/.meterian/`.

### Why fixes are detected from git, not from the exit code

The client exits non-zero whenever the security score is below the minimum —
which is precisely the case in which it has just applied fixes. The exit code
therefore cannot tell you whether to branch, so the script decides on
`git status --porcelain` instead.

This is not a theoretical concern. Both of these runs applied fixes:

| Invocation | Client exit code | Fixes applied |
|---|---|---|
| `--autofix` (default `safe`) | `1` | 1 of 3 — score still below minimum |
| `--autofix "conservative+vulns"` | `0` | 3 of 3 — score back above minimum |

A script that branched on `exit == 0` would miss the first; one that branched on
`exit != 0` would miss the second.

### Choosing a strategy

The default is `safe+vulns,safe+dated+no-overrides`, which applies patch-level
updates only. Vulnerabilities whose fix needs a minor bump require
`--autofix "conservative+vulns"`; only fixes that require a new major version
need `"aggressive+vulns"`. Measured against the `vulnerable-demo` branch:

| Strategy | commons-collections 3.2.1 | jackson-databind 2.9.8 | log4j-core 2.17.0 | Security score |
|---|---|---|---|---|
| `safe` (default) | → 3.2.2 | unchanged | unchanged | 0 |
| `conservative+vulns` | → 3.2.2 | → 2.22.2 | → 2.26.1 | 100 |
| `aggressive+vulns` | → 3.2.2 | → 2.22.2 | → 2.26.1 | 100 |

`conservative` and `aggressive` produce identical output here, because every
fix these three dependencies need is a minor bump within their current major
version. Reach for `conservative` first and escalate only if it leaves
vulnerabilities unfixed — `aggressive` permits major upgrades, and so carries a
real risk of incompatible changes for no benefit in cases like this one.

Always check that the build still passes before merging.

### Other notes

- The client's XML rewriter joins the `<?xml ...?>` declaration onto the
  `<project>` line and drops the file's trailing newline. It is cosmetic, but it
  shows up in every autofix diff. The script deliberately does not post-process
  the client's output.
- The `vulnerable-demo` branch carries deliberately vulnerable dependencies to
  demonstrate the script against.
