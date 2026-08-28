# Per-project bootstrap for stu. Copy to
#   $(herdr plugin config-dir stu)/projects/<repo-name>.sh
# where <repo-name> is the basename of the repo's root checkout. Runs inside the
# new worktree with `step` and `copy_from_root` in scope (see bootstrap.sh).
copy_from_root .env
step "yarn install" yarn install
step "yarn build"   yarn build
