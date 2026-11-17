#!/usr/bin/env bash
#######################################
# Shared helpers for the pod VM image scripts
#######################################
# Sourced, not executed. Shared so the guards cannot drift between the siblings.
# Keep it to what both scripts actually call.

# Sourced by the scripts, so shellcheck cannot see the uses from here.
# shellcheck disable=SC2034
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info()  { echo -e "${BLUE}[i]${NC} $1"; }

# Call as need_value "$@": without it a valueless flag dies on $2 under set -u.
need_value() {
  [[ $# -ge 2 && -n "${2:-}" ]] || error "$1 needs a value (try --help)"
}

# Prints the comment header as help, so the two never drift.
print_help() {
  awk 'NR==1{next} /^#/{sub(/^# ?/, ""); print; next} {exit}' "$1"
}
