#!/bin/bash
set -euo pipefail

# Configuration via environment variables:
#   REPO             - Org name ("my-org") for an org-level runner,
#                      or "owner/repo" for a repo-level runner.
#   NAME             - Runner name shown in GitHub. Default: hostname.
#   ACCESS_TOKEN     - GitHub PAT used to fetch a fresh registration token at
#                      startup. Recommended. Classic PAT: "admin:org" for org
#                      runners or "repo" for repo runners. Fine-grained PAT:
#                      "Self-hosted runners: read & write" (org) or
#                      "Administration: read & write" (repo).
#   REG_TOKEN        - (Optional/legacy) A pre-generated registration token.
#                      Only used when ACCESS_TOKEN is not set. Expires after
#                      ~1h, so ACCESS_TOKEN is strongly preferred.
#   LABELS           - (Optional) Comma-separated extra runner labels.
#                      "php-<version>" is always added.
#   RUNNER_GROUP     - (Optional) Runner group for org runners.
#   RUNNER_EPHEMERAL - Default true: take one job, then exit so the container
#                      restarts with a clean home directory. false = keep the
#                      runner and its files between jobs (old behaviour).
#
# This script runs as root so that ACCESS_TOKEN never reaches the runner:
# the runner (and so every job) runs as "docker" without the token in its
# environment, and can't read this process's memory or /proc/1/environ.

RUNNER_USER=docker
RUNNER_HOME=/home/docker
RUNNER_DIR=$RUNNER_HOME/actions-runner

REPO="${REPO:?REPO is required}"
NAME="${NAME:-$(hostname)}"
ACCESS_TOKEN="${ACCESS_TOKEN:-}"
REG_TOKEN="${REG_TOKEN:-}"
LABELS="${LABELS:-}"
RUNNER_GROUP="${RUNNER_GROUP:-}"
RUNNER_EPHEMERAL="${RUNNER_EPHEMERAL:-true}"

API="https://api.github.com"

if [[ "$REPO" == */* ]]; then
  TOKEN_API="${API}/repos/${REPO}/actions/runners"
else
  TOKEN_API="${API}/orgs/${REPO}/actions/runners"
fi
RUNNER_URL="https://github.com/${REPO}"

# Fetch a short-lived token of the given kind ("registration" or "remove")
# using the PAT. Echoes the token on success, exits non-zero on failure.
fetch_token() {
  local kind="$1"
  local resp token
  resp="$(curl -fsSL -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${TOKEN_API}/${kind}-token")" || {
      echo "ERROR: failed to fetch ${kind}-token from ${TOKEN_API}/${kind}-token" >&2
      echo "       Check that REPO ('${REPO}') is correct and the PAT has runner-admin rights." >&2
      return 1
    }
  token="$(jq -r '.token' <<<"$resp")"
  if [[ -z "$token" || "$token" == "null" ]]; then
    echo "ERROR: ${kind}-token missing in API response" >&2
    return 1
  fi
  echo "$token"
}

# Run a command as the runner user, without any of the tokens in its env.
as_runner() {
  env -u ACCESS_TOKEN -u REG_TOKEN \
    HOME="$RUNNER_HOME" USER="$RUNNER_USER" LOGNAME="$RUNNER_USER" \
    setpriv --reuid="$RUNNER_USER" --regid="$RUNNER_USER" --init-groups -- "$@"
}

# Ephemeral mode: start every job from a clean slate. Anything a previous job
# left behind in the runner user's home or temp dirs is removed, and a
# pristine copy of the runner is taken from the root-owned /opt.
if [[ "$RUNNER_EPHEMERAL" == "true" || ! -d $RUNNER_DIR ]]; then
  echo "Preparing a clean runner home ..."
  find "$RUNNER_HOME" -mindepth 1 -delete
  find /tmp /var/tmp /dev/shm -mindepth 1 -user "$RUNNER_USER" -delete 2>/dev/null || true
  cp -a /etc/skel/. "$RUNNER_HOME"/
  cp -a /opt/actions-runner "$RUNNER_DIR"
  chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME"
fi

cd "$RUNNER_DIR"

# Obtain a registration token: prefer the PAT, fall back to a legacy REG_TOKEN.
if [[ -n "$ACCESS_TOKEN" ]]; then
  echo "Fetching a fresh registration token for ${RUNNER_URL} ..."
  REG_TOKEN="$(fetch_token registration)"
elif [[ -n "$REG_TOKEN" ]]; then
  echo "Using provided REG_TOKEN (legacy mode; consider ACCESS_TOKEN instead)."
else
  echo "ERROR: either ACCESS_TOKEN (recommended) or REG_TOKEN must be set." >&2
  exit 1
fi

LABELS="php-${PHP_VERSION}${LABELS:+,$LABELS}"
CONFIG_ARGS=(
  --url "${RUNNER_URL}"
  --token "${REG_TOKEN}"
  --name "${NAME}"
  --labels "${LABELS}"
  --unattended
  --replace
)
[[ "$RUNNER_EPHEMERAL" == "true" ]] && CONFIG_ARGS+=(--ephemeral)
[[ -n "$RUNNER_GROUP" ]] && CONFIG_ARGS+=(--runnergroup "${RUNNER_GROUP}")

echo "Registering runner ${NAME} (labels: ${LABELS}, ephemeral: ${RUNNER_EPHEMERAL}) ..."
as_runner ./config.sh "${CONFIG_ARGS[@]}"

runner_pid=""
cleanup() {
  echo "Removing runner ${NAME} ..."
  if [[ -n "$runner_pid" ]]; then
    kill -TERM "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
  fi
  local remove_token="$REG_TOKEN"
  # A registration token cannot remove a runner; fetch a remove-token if we
  # have a PAT, otherwise fall back to whatever REG_TOKEN we were given.
  if [[ -n "$ACCESS_TOKEN" ]]; then
    remove_token="$(fetch_token remove || echo "")"
  fi
  if [[ -n "$remove_token" ]]; then
    as_runner ./config.sh remove --token "${remove_token}" || true
  fi
}

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# Started directly (not via as_runner) so $! is the runner itself and the
# shutdown signal from cleanup() reaches it.
env -u ACCESS_TOKEN -u REG_TOKEN \
  HOME="$RUNNER_HOME" USER="$RUNNER_USER" LOGNAME="$RUNNER_USER" \
  setpriv --reuid="$RUNNER_USER" --regid="$RUNNER_USER" --init-groups -- ./run.sh &
runner_pid=$!
wait "$runner_pid"
# In ephemeral mode the runner exits after one job and GitHub has already
# unregistered it; exiting lets Docker restart the container for the next job.
