# ghbak - github-backup in a container (multi-arch: build for linux/arm64 and linux/amd64)
#   docker buildx build --platform linux/arm64,linux/amd64 -t ghbak:latest .
FROM python:3.14.9-slim

# Pin the backup tool so a rebuild never changes behaviour unexpectedly
ARG GITHUB_BACKUP_VERSION=0.67.0

RUN apt-get update \
 && apt-get install -y --no-install-recommends git git-lfs ca-certificates tzdata \
 && rm -rf /var/lib/apt/lists/* \
 && git lfs install --system --skip-repo \
 # Bind-mounted dirs may be owned by another uid; let git work on them anyway
 && git config --system --add safe.directory '*'

RUN pip install --no-cache-dir "github-backup==${GITHUB_BACKUP_VERSION}"

# The container runs as an arbitrary uid (docker run --user); give git a writable HOME
ENV HOME=/tmp

ENTRYPOINT ["github-backup"]
