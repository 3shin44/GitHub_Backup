# ghbak - GitHub account backup in Docker

Backs up a whole GitHub account (private repos, wikis, issues, PRs, releases, gists) into a local directory with [github-backup](https://github.com/josegonzalez/python-github-backup). The backup is only read, never worked in. If GitHub is ever unavailable, it is the starting point for a self-hosted Git server.

```
cron ──> ghbak.sh ──> docker run --rm ghbak  =  github-backup <user> -o /data ...
            └─ .env, mount check, logs
```

| File | Purpose |
|---|---|
| `Dockerfile` | `python` + git + git-lfs + `github-backup` (pinned version) |
| `ghbak.sh` | Reads `.env`, runs the container, writes the logs |
| `.env.example` | All settings, with comments |

## Setup

```bash
docker build -t ghbak:latest .
# or build on a PC for the Pi (arm64) and push to a registry; then IMAGE=<registry>/ghbak:<tag> in .env
docker buildx build --platform linux/arm64,linux/amd64 -t <registry>/ghbak:<tag> --push .
sudo mkdir -p /srv/ghbak && sudo chown $USER /srv/ghbak
cp ghbak.sh .env.example /srv/ghbak/ && cd /srv/ghbak
cp .env.example .env && chmod 600 .env
nano .env        # GITHUB_USER, GITHUB_TOKEN, DATA_DIR, LOG_DIR, REQUIRE_MOUNT, TEST_REPOS
```
The user running `ghbak.sh` must be able to use Docker (`sudo usermod -aG docker $USER`).

**GitHub token** (Settings → Developer settings → Fine-grained tokens): Repository access **All repositories**, read-only permissions Contents, Metadata, Issues, Pull requests, Webhooks. `--all` also backs up webhooks; without the Webhooks permission the run fails with HTTP 403.

## Use

```bash
./ghbak.sh test                    # repos from TEST_REPOS into TEST_DATA_DIR (no gists)
./ghbak.sh test repoA repoB        # or name them
./ghbak.sh run                     # full backup into DATA_DIR; the first run takes longest
crontab -e                         # add:
30 3 * * * /srv/ghbak/ghbak.sh run >/dev/null 2>&1
```
On Windows, run it from Git Bash or with `bash ./ghbak.sh test`. Typing `./ghbak.sh` in PowerShell opens a separate window that closes at once.

Exit codes: `0` OK, `10` WARN (finished, but there are error lines in the output), `1` FAIL, `2` usage.

## Logs

Under `LOG_DIR`: the full output of each run (`run-*.log`, `test-*.log`) and one line per run in `history.log`:
```
2026-11-06 03:30:00 | OK   | run  | completed | log=run-20261106-033000.log
2026-11-07 03:30:00 | FAIL | run  | Backup disk not mounted: /mnt/backup | log=run-20261107-033000.log
2026-11-08 03:30:00 | FAIL | run  | github-backup exit 1 | log=run-20261108-033000.log
```
Check now and then: `grep -v '| OK ' /srv/ghbak/logs/history.log`. A run that starts while another is still going fails with `docker run` "name already in use".

## What the backup does and doesn't follow

- **Kept:** branches, tags and whole repos deleted on GitHub (`ghbak.sh` always adds `--no-prune`).
- **Overwritten:** a force-push on GitHub moves that branch in the backup as well.
- **Token:** `github-backup` writes the token into each mirror's `config` (clone URL) and prints it when git fails. `ghbak.sh` masks it in the log and removes it from the `config` files after every run.

## Restore / use as a Git server

Each `repositories/<repo>/repository` is a bare mirror: all branches, tags and history.
```bash
git clone /mnt/backup/github/repositories/<repo>/repository my-repo        # working copy
```
To serve the repos from your own Git server, **copy** them to the server's directory first (and stop the cron job), because each backup run resets the mirrors to the GitHub state. Issues and PRs are JSON files in `issues/` and `pulls/`; you can read them, but they can't be imported automatically.
