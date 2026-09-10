#!/usr/bin/env bash
#
# Clone a repository, run the Meterian thin client with --autofix, and if any
# manifests were changed, push the fixes on a dedicated branch.
#
# The Meterian client (https://docs.meterian.io/the-client/client) rewrites
# vulnerable dependency versions in place; it does not touch git. This script
# supplies the git workflow around it.
#
set -euo pipefail

readonly PROGNAME="${0##*/}"
readonly CLI_URL="https://www.meterian.com/downloads/meterian-cli.jar"
readonly CLI_CACHE="${HOME}/.meterian/meterian-cli.jar"

# --- options ----------------------------------------------------------------

REPO_URL=""
SRC_BRANCH=""
FIX_BRANCH=""
AUTOFIX_SPEC=""
WORKDIR=""
OPEN_PR=false
DRY_RUN=false

usage() {
    cat <<EOF
Usage: $PROGNAME <repo-url> [options]

Clones <repo-url>, runs the Meterian client with --autofix, and pushes any
resulting dependency fixes on a new branch.

Options:
  --branch <name>       Branch to clone and fix (default: the remote's default)
  --fix-branch <name>   Branch to create for the fixes
                        (default: meterian-autofix-<YYYYmmdd-HHMMSS>)
  --autofix <spec>      Value passed to the client's --autofix
                        (default: the client's own, safe+vulns,safe+dated+no-overrides)
  --workdir <dir>       Clone here instead of a temporary directory (kept on exit)
  --pull-request        Open a pull request after pushing (requires the gh CLI)
  --dry-run             Do everything except push; show the diff and stop
  -h, --help            Show this help

Environment:
  METERIAN_API_TOKEN    Required. Your Meterian API token.
  METERIAN_CLI_JAR      Optional. Path to an existing meterian-cli.jar;
                        otherwise it is downloaded to $CLI_CACHE.

Exit codes:
  0  fixes pushed, or nothing to fix
  1  usage error or a failure along the way
EOF
}

log()  { printf '[%s] %s\n'    "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '%s: error: %s\n' "$PROGNAME" "$*"  >&2; exit 1; }

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --branch)       SRC_BRANCH="${2:-}";   [ -n "$SRC_BRANCH" ]   || die "--branch needs a value";      shift 2 ;;
            --fix-branch)   FIX_BRANCH="${2:-}";   [ -n "$FIX_BRANCH" ]   || die "--fix-branch needs a value";  shift 2 ;;
            --autofix)      AUTOFIX_SPEC="${2:-}"; [ -n "$AUTOFIX_SPEC" ] || die "--autofix needs a value";     shift 2 ;;
            --workdir)      WORKDIR="${2:-}";      [ -n "$WORKDIR" ]      || die "--workdir needs a value";     shift 2 ;;
            --pull-request) OPEN_PR=true;  shift ;;
            --dry-run)      DRY_RUN=true;  shift ;;
            -h|--help)      usage; exit 0 ;;
            -*)             die "unknown option: $1" ;;
            *)
                [ -z "$REPO_URL" ] || die "unexpected argument: $1"
                REPO_URL="$1"; shift ;;
        esac
    done

    [ -n "$REPO_URL" ] || { usage >&2; exit 1; }
    FIX_BRANCH="${FIX_BRANCH:-meterian-autofix-$(date +%Y%m%d-%H%M%S)}"
}

# --- preflight --------------------------------------------------------------

# Fail before doing any work, rather than after the scan.
preflight() {
    local missing=()
    for tool in git java mvn curl; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    [ ${#missing[@]} -eq 0 ] || die "missing required tools: ${missing[*]}"

    [ -n "${METERIAN_API_TOKEN:-}" ] || die "METERIAN_API_TOKEN is not set"

    if $OPEN_PR; then
        command -v gh >/dev/null 2>&1 \
            || die "--pull-request needs the gh CLI (https://cli.github.com)"
        gh auth status >/dev/null 2>&1 \
            || die "--pull-request needs an authenticated gh (run: gh auth login)"
    fi
}

# --- the meterian client ----------------------------------------------------

# Echoes the path to the client jar, downloading it if we don't have one.
resolve_client() {
    if [ -n "${METERIAN_CLI_JAR:-}" ]; then
        [ -f "$METERIAN_CLI_JAR" ] || die "METERIAN_CLI_JAR does not exist: $METERIAN_CLI_JAR"
        echo "$METERIAN_CLI_JAR"; return
    fi

    mkdir -p "$(dirname "$CLI_CACHE")"

    # Conditional GET: -z sends If-Modified-Since from the cached jar's
    # timestamp and -R stamps the reply's Last-Modified onto it, so a cached
    # client refreshes as soon as a new one is published. Scanning for
    # vulnerabilities with a client that never updates is not worth the
    # saved bandwidth.
    if [ -f "$CLI_CACHE" ]; then
        log "checking for a newer Meterian client"
    else
        log "downloading the Meterian client to $CLI_CACHE"
    fi

    if curl -fsSL -R -z "$CLI_CACHE" -o "$CLI_CACHE.tmp" "$CLI_URL"; then
        if [ -s "$CLI_CACHE.tmp" ]; then
            mv "$CLI_CACHE.tmp" "$CLI_CACHE"
            log "using the Meterian client published $(date -r "$CLI_CACHE" '+%Y-%m-%d')"
        else
            # 304 Not Modified: curl truncated the placeholder, keep the cache.
            rm -f "$CLI_CACHE.tmp"
            log "the cached client is up to date"
        fi
    else
        rm -f "$CLI_CACHE.tmp"
        # A failed refresh is survivable if we already have a client.
        [ -f "$CLI_CACHE" ] || die "could not download $CLI_URL"
        log "warning: could not reach $CLI_URL, using the cached client from $(date -r "$CLI_CACHE" '+%Y-%m-%d')"
    fi

    echo "$CLI_CACHE"
}

# --- main -------------------------------------------------------------------

main() {
    parse_args "$@"
    preflight

    local jar; jar="$(resolve_client)"

    local clone_dir cleanup=false
    if [ -n "$WORKDIR" ]; then
        mkdir -p "$WORKDIR"
        clone_dir="$WORKDIR/repo"
        [ -e "$clone_dir" ] && die "$clone_dir already exists"
    else
        clone_dir="$(mktemp -d)/repo"
        cleanup=true
    fi
    # shellcheck disable=SC2064  # expand clone_dir now, it is stable from here
    $cleanup && trap "rm -rf '$(dirname "$clone_dir")'" EXIT

    log "cloning $REPO_URL${SRC_BRANCH:+ (branch $SRC_BRANCH)}"
    git clone --quiet --depth 1 ${SRC_BRANCH:+--branch "$SRC_BRANCH"} "$REPO_URL" "$clone_dir" \
        || die "clone failed"
    cd "$clone_dir"

    local src_branch; src_branch="$(git rev-parse --abbrev-ref HEAD)"
    [ "$FIX_BRANCH" != "$src_branch" ] \
        || die "the fix branch and the source branch are both '$src_branch'; refusing to push onto it"

    log "running the Meterian client with autofix"
    # The client exits non-zero whenever the security score is below threshold,
    # which is precisely the case where it has just fixed something. So its exit
    # code cannot tell us whether fixes were applied -- git can. Report it and
    # carry on.
    local rc=0
    java -jar "$jar" --interactive=false "--autofix${AUTOFIX_SPEC:+=$AUTOFIX_SPEC}" || rc=$?
    log "the client exited with code $rc"

    if [ -z "$(git status --porcelain)" ]; then
        log "no manifests were changed: nothing to fix"
        exit 0
    fi

    log "fixes applied to: $(git diff --name-only | tr '\n' ' ')"
    git checkout --quiet -b "$FIX_BRANCH"
    git -c user.name="meterian-autofix" -c user.email="autofix@meterian.io" \
        commit --quiet --all --message "Apply Meterian autofix to vulnerable dependencies

Applied by the Meterian client${AUTOFIX_SPEC:+ (--autofix=$AUTOFIX_SPEC)} on ${src_branch}.

$(git diff --stat HEAD)"

    if $DRY_RUN; then
        log "dry run: not pushing. The commit is:"
        git --no-pager show --stat --patch HEAD
        exit 0
    fi

    log "pushing $FIX_BRANCH"
    git push --quiet --set-upstream origin "$FIX_BRANCH" || die "push failed"

    if $OPEN_PR; then
        log "opening a pull request"
        gh pr create --base "$src_branch" --head "$FIX_BRANCH" \
            --title "Apply Meterian autofix to vulnerable dependencies" \
            --body "Automated dependency remediation by the [Meterian client](https://docs.meterian.io/the-client/client).

\`\`\`
$(git diff --stat "origin/$src_branch"...HEAD)
\`\`\`

Review the version changes and check the build before merging."
    else
        log "branch pushed. Open a pull request from $FIX_BRANCH into $src_branch to merge the fixes."
    fi
}

main "$@"
