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

# fix a specific branch, allow major version bumps, and open a pull request
./scripts/meterian-autofix.sh git@github.com:you/your-repo.git \
    --branch develop --autofix "aggressive+vulns" --pull-request

# see what would change without pushing anything
./scripts/meterian-autofix.sh git@github.com:you/your-repo.git --dry-run
```

Run `./scripts/meterian-autofix.sh --help` for all options.

The script needs `git`, `java`, `mvn` and `curl`; `--pull-request` additionally
needs an authenticated [`gh`](https://cli.github.com). The client jar is
downloaded once and cached in `~/.meterian/`.

### Notes

- The client exits non-zero whenever the security score is below the minimum,
  which is exactly the situation in which it has just applied fixes. The script
  therefore decides whether to branch by looking at `git status`, not at the
  exit code.
- The default autofix strategy is `safe+vulns,safe+dated+no-overrides`, which
  only applies patch-level updates. Vulnerabilities whose fix requires a minor
  or major bump need `--autofix "conservative+vulns"` or `"aggressive+vulns"`,
  at the usual risk of incompatible changes — always check the build before
  merging.
- The `vulnerable-demo` branch carries deliberately vulnerable dependencies to
  demonstrate the script against.
