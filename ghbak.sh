#!/usr/bin/env bash
# =============================================================================
# ghbak.sh - back up a GitHub account with github-backup (in Docker)
#
#   ghbak.sh run               full backup into DATA_DIR                 (crontab)
#   ghbak.sh test [repos...]   only these repos (default TEST_REPOS) into TEST_DATA_DIR
#
# Settings: .env next to this script (override: ENV_FILE=/path/.env ghbak.sh ...)
# Logs:     LOG_DIR/<cmd>-YYYYMMDD-HHMMSS.log, one line per run in LOG_DIR/history.log
# crontab:  30 3 * * * /srv/ghbak/ghbak.sh run >/dev/null 2>&1
# =============================================================================
set -uo pipefail

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ENV_FILE="${ENV_FILE:-$DIR/.env}"
export PATH="$PATH:/usr/local/bin:/usr/bin:/bin"   # cron has a minimal PATH
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: don't rewrite /data in docker arguments

CMD="${1:-}"; [[ $# -gt 0 ]] && shift
case "$CMD" in
    run|test) ;;
    *) sed -n '5,6p' "$0" | sed 's/^# //'; exit 2 ;;
esac
[[ -r "$ENV_FILE" ]] || { echo "Cannot read $ENV_FILE (copy .env.example to .env)" >&2; exit 1; }

# env_get KEY [default]: last KEY=value line of .env, value taken verbatim (unquoted, may contain spaces)
env_get() {
    local v; v=$(grep -E "^$1=" "$ENV_FILE" | tail -n 1 | cut -d= -f2- | tr -d '\r')
    printf '%s' "${v:-${2:-}}"
}
IMAGE=$(env_get IMAGE ghbak:latest)
GITHUB_USER=$(env_get GITHUB_USER)
GITHUB_TOKEN=$(env_get GITHUB_TOKEN)
LOG_DIR=$(env_get LOG_DIR "$DIR/logs")
RUN_AS=$(env_get RUN_AS "$(id -u):$(id -g)")
# Docker Desktop on Windows: only root may chmod on a mounted folder, which git needs
[[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]] && [[ -z "$(env_get RUN_AS)" ]] && RUN_AS=0:0
TZ_ENV=$(env_get TZ UTC); export TZ="$TZ_ENV"
read -r -a args <<< "$(env_get GHB_ARGS "--all --private --fork --bare --incremental")"
# The backup only grows: never delete local branches/tags that were deleted on GitHub
[[ " ${args[*]} " == *" --no-prune "* ]] || args+=(--no-prune)

if [[ "$CMD" == run ]]; then
    DATA=$(env_get DATA_DIR)
    MNT=$(env_get REQUIRE_MOUNT)
else
    DATA=$(env_get TEST_DATA_DIR)
    MNT=""
    repos=("$@"); (( ${#repos[@]} )) || read -r -a repos <<< "$(env_get TEST_REPOS)"
    (( ${#repos[@]} )) || { echo "test needs repo names (arguments or TEST_REPOS in .env)" >&2; exit 2; }
    # gists are not filtered by -N, so leave them out of the test
    keep=(); for a in "${args[@]}"; do [[ "$a" == --gists || "$a" == --starred-gists ]] || keep+=("$a"); done
    args=("${keep[@]}" -N "^($(IFS='|'; echo "${repos[*]//./\\.}"))\$")
fi

mkdir -p "$LOG_DIR" || exit 1
START=$(date '+%F %T')
LOG="$LOG_DIR/$CMD-$(date '+%Y%m%d-%H%M%S').log"
history() { printf '%s | %-4s | %-4s | %s | log=%s\n' "$START" "$1" "$CMD" "$2" "$(basename "$LOG")" >> "$LOG_DIR/history.log"; }
fail() { echo "$START ERROR $*" | tee -a "$LOG" >&2; history FAIL "$*"; exit 1; }

[[ -n "$GITHUB_USER" && -n "$GITHUB_TOKEN" && -n "$DATA" ]] || fail "GITHUB_USER, GITHUB_TOKEN and the data dir must be set in .env"
[[ -z "$MNT" ]] || mountpoint -q "$MNT" || fail "Backup disk not mounted: $MNT"
mkdir -p "$DATA" || fail "Cannot create $DATA"

# Run github-backup. git errors print the clone URL including the token: mask it in the log.
echo "$START github-backup $GITHUB_USER ${args[*]} -o $DATA" | tee "$LOG"
docker run --rm --init --name ghbak --user "$RUN_AS" -e TZ="$TZ" -v "$DATA:/data" \
    "$IMAGE" "$GITHUB_USER" -f "$GITHUB_TOKEN" -o /data "${args[@]}" 2>&1 |
    sed -u -E 's#(://[^/@ ]+:)[^@ ]+@#\1*****@#g' | tee -a "$LOG"
rc=${PIPESTATUS[0]}

# github-backup stores the clone URL including the token in every mirror's config
# (and sets it again on the next run): remove it.
docker run --rm --user "$RUN_AS" -v "$DATA:/data" --entrypoint find "$IMAGE" /data \
    -mindepth 2 -maxdepth 4 -type f -name config -exec sed -i -E 's#(url = https?://)[^/@]+@#\1#' {} +

# github-backup exits 0 even when a git clone/fetch fails, so look at its output too
gitfail=$(grep -c '^git returned' "$LOG")
errs=$(grep -Ec 'ERROR|CRITICAL|Traceback|fatal:' "$LOG")
if   (( rc != 0 ));      then history FAIL "github-backup exit $rc";      exit 1
elif (( gitfail > 0 ));  then history FAIL "$gitfail git command(s) failed"; exit 1
elif (( errs > 0 ));     then history WARN "$errs error lines";           exit 10
else                       history OK   "completed";             exit 0
fi
