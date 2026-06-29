#!/usr/bin/env bash
# =============================================================================
# Skolva Core — Test Suite dispatcher
#
# Usage:
#   ./scripts/test.sh              Interactive: select steps from menu
#   ./scripts/test.sh 01 04 05      Run specific steps non-interactively
#   ./scripts/test.sh --ci 04 05    CI mode
#   ./scripts/test.sh all           Run all steps in order
# =============================================================================
set -euo pipefail

# source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ============================================================================
# Aggregated steps
# ============================================================================

s_test_all() {   banner "All Tests";  run_go_test "core tests" ./... -v; }
s_test_unit() {  banner "Unit Tests (no Docker)";  SKIP_INTEGRATION=1 go test ./... -v 2>&1 | sed 's/^/  /'; echo -e "  ${GREEN}[PASS]${NC} unit tests"; PASSED=$((PASSED + 1)); }
s_run_all() { s_prerequisites; s_build; s_lint; s_test_all; s_coverage; }

# ============================================================================
# Menu
# ============================================================================

ALL_STEPS=(
    "all:Run all steps in order"
    "01:Prerequisites Check"
    "02:Build"
    "03:Lint (golangci-lint)"
    "04:Test (all packages, needs Docker)"
    "04a:Test (unit only, SKIP_INTEGRATION=1, no Docker)"
    "05:Full Test Suite + Coverage"
    "06:Full Check (build+lint+test+coverage)"
)

show_menu() {
    echo ""
    echo -e "${BOLD}Available Test Steps${NC}"
    echo "──────────────────────────────────────"
    for entry in "${ALL_STEPS[@]}"; do
        local key="${entry%%:*}" desc="${entry#*:}"
        printf "  %-6s %s\n" "${key}" "${desc}"
    done
    echo ""
}

run_step() {
    local step="$1"
    case "$step" in
        all)   s_run_all ;;
        help|--help) show_menu; echo "Usage: $0 [--ci] [step...]  (steps: $(echo "${ALL_STEPS[@]}" | grep -oE '[0-9a-z]+:' | tr -d ':' | tr '\n' ' '))" ;;
        01)    s_prerequisites ;;
        02)    s_build ;;
        03)    s_lint ;;
        04)    s_test_all ;;
        04a)   s_test_unit ;;
        05)    s_coverage ;;
        06)    s_full_check ;;
        *)     echo -e "${RED}Unknown step: $step${NC}"; return 1 ;;
    esac
}

# ============================================================================
# Main
# ============================================================================

if [[ -f "go.mod" ]]; then true
elif [[ -f "../go.mod" ]]; then cd ..
else echo -e "${RED}ERROR: Must run from project root (where go.mod is)${NC}"; exit 1; fi

# --- logging ---
mkdir -p logs
LOG_FILE="logs/test-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee "$LOG_FILE") 2>&1

if [[ "$CI_MODE" == "true" ]]; then CI_LABEL=" (CI mode)"; else CI_LABEL=""; fi
echo -e "${BOLD}Skolva Core Test Suite${NC}${CI_LABEL}"
echo "Project: $(pwd)"
echo "Go:      $(go version)"

if [[ $# -eq 0 ]]; then
    show_menu
    echo -n "Which step(s)? Enter number(s) separated by space [all]: "
    read -r selection
else
    selection="$*"
fi

if [[ -z "$selection" ]]; then
    if $CI_MODE; then selection="04 05"; else selection="all"; fi
fi

echo ""; echo -e "${BOLD}Running: ${selection}${NC}"; echo ""

for s in $selection; do run_step "${s,,}" || true; done
summary

if $CI_MODE && [[ $FAILED -gt 0 ]]; then exit 1; fi
