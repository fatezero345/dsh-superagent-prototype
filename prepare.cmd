@echo off
rem Prepare command for a dsh-superagent Ticket: fetch the ticket ref and add a worktree.
rem Environment provided by the dsh-superagent worker: DSH_SUPERAGENT_GITHUB_REPOSITORY,
rem DSH_SUPERAGENT_TICKET, DSH_SUPERAGENT_NAME, DSH_SUPERAGENT_DIR, DSH_SUPERAGENT_GITHUB_PR_HEAD (optional).
setlocal
set BASE=C:\Users\fixadmin\src\dsh-superagent-prototype
if not defined DSH_SUPERAGENT_GITHUB_REPOSITORY goto :missing
if not defined DSH_SUPERAGENT_TICKET goto :missing
if not defined DSH_SUPERAGENT_NAME goto :missing
if not defined DSH_SUPERAGENT_DIR goto :missing
if not defined DSH_SUPERAGENT_GITHUB_PR_HEAD set DSH_SUPERAGENT_GITHUB_PR_HEAD=HEAD
git -C "%BASE%" fetch --no-tags "https://github.com/%DSH_SUPERAGENT_GITHUB_REPOSITORY%.git" "%DSH_SUPERAGENT_GITHUB_PR_HEAD%:refs/dsh-superagent/%DSH_SUPERAGENT_TICKET%" && git -C "%BASE%" worktree add -b "agent/%DSH_SUPERAGENT_NAME%" "%DSH_SUPERAGENT_DIR%" "refs/dsh-superagent/%DSH_SUPERAGENT_TICKET%"
exit /b %ERRORLEVEL%
:missing
echo prepare.cmd: missing required DSH_SUPERAGENT_* environment variable 1>&2
exit /b 1
