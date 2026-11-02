#!/bin/sh
# Prepare command for a dsh-superagent Ticket (Windows / Git Bash):
# fetch the ticket ref into the base clone, then add a worktree for the ticket.
# Environment comes from the dsh-superagent worker: DSH_SUPERAGENT_GITHUB_REPOSITORY,
# DSH_SUPERAGENT_TICKET, DSH_SUPERAGENT_NAME, DSH_SUPERAGENT_DIR,
# DSH_SUPERAGENT_GITHUB_PR_HEAD (optional).
set -eu
BASE='C:/Users/fixadmin/src/dsh-superagent-prototype'
: "${DSH_SUPERAGENT_GITHUB_PR_HEAD:=HEAD}"
: "${DSH_SUPERAGENT_GITHUB_REPOSITORY:?missing DSH_SUPERAGENT_GITHUB_REPOSITORY}"
: "${DSH_SUPERAGENT_TICKET:?missing DSH_SUPERAGENT_TICKET}"
: "${DSH_SUPERAGENT_NAME:?missing DSH_SUPERAGENT_NAME}"
: "${DSH_SUPERAGENT_DIR:?missing DSH_SUPERAGENT_DIR}"
git -C "$BASE" fetch --no-tags "https://github.com/${DSH_SUPERAGENT_GITHUB_REPOSITORY}.git" "${DSH_SUPERAGENT_GITHUB_PR_HEAD}:refs/dsh-superagent/${DSH_SUPERAGENT_TICKET}"
git -C "$BASE" worktree add -b "agent/${DSH_SUPERAGENT_NAME}" "${DSH_SUPERAGENT_DIR}" "refs/dsh-superagent/${DSH_SUPERAGENT_TICKET}"
