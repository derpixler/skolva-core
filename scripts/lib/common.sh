#!/usr/bin/env bash
# =============================================================================
# Skolva Core — shared test harness library (minimal, no product baggage)
# =============================================================================
set -euo pipefail

# --- CI Mode Detection ---
if [[ "${1:-}" == "--ci" ]]; then
    CI_MODE=true; shift
else
    CI_MODE=false
fi

# --- Colors ---
if $CI_MODE; then
    RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
else
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
fi

# --- State ---
PASSED=0; FAILED=0; FAILED_STEPS=()

# --- Helpers ---
docker_available() { docker info &>/dev/null 2>&1; }

check_tool() {
    local name="$1" cmd="$2" hint="$3"
    if command -v "$cmd" &>/dev/null; then echo -e "  ${GREEN}[OK]${NC} $name"; return 0
    else echo -e "  ${RED}[MISSING]${NC} $name — $hint"; return 1; fi
}

banner() {
    echo ""; echo -e "${BLUE}============================================${NC}"
    echo -e "${BOLD}  $1${NC}"; echo -e "${BLUE}============================================${NC}"
}

step() {
    local num="$1" desc="$2"
    echo ""; echo -e "${YELLOW}[${num}]${NC} ${BOLD}${desc}${NC}"
}

run_cmd() {
    local desc="$1"; shift
    echo -e "  ${BLUE}\$${NC} $*"
    if "$@"; then echo -e "  ${GREEN}[PASS]${NC} ${desc}"; PASSED=$((PASSED + 1)); return 0
    else echo -e "  ${RED}[FAIL]${NC} ${desc}"; FAILED=$((FAILED + 1)); FAILED_STEPS+=("$desc"); return 1; fi
}

run_go_test() {
    local desc="$1" pkg="$2"; shift 2
    echo -e "  ${BLUE}\$${NC} go test $* ${pkg}"
    if go test -count=1 "$@" "$pkg" 2>&1 | sed 's/^/  /'; then
        echo -e "  ${GREEN}[PASS]${NC} ${desc}"; PASSED=$((PASSED + 1)); return 0
    else local rc=$?; echo -e "  ${RED}[FAIL]${NC} ${desc} (exit $rc)"; FAILED=$((FAILED + 1)); FAILED_STEPS+=("$desc"); return 1; fi
}

summary() {
    echo ""; echo -e "${BLUE}============================================${NC}"
    local total=$((PASSED + FAILED))
    echo -e "  Results: ${GREEN}${PASSED} passed${NC}, ${RED}${FAILED} failed${NC}, ${total} total"
    if [[ $FAILED -eq 0 ]]; then echo -e "  ${GREEN}${BOLD}All checks passed.${NC}"
    else
        echo -e "  ${RED}${BOLD}${FAILED} check(s) failed.${NC}"
        for f in "${FAILED_STEPS[@]}"; do echo -e "    ${RED}✗${NC} $f"; done
    fi
    echo -e "${BLUE}============================================${NC}"
}

# ============================================================================
# Global steps
# ============================================================================

s_prerequisites() {
    banner "Prerequisites"
    echo ""; echo "  Go: $(go version)"
    if $CI_MODE; then
        echo -e "  ${GREEN}[OK]${NC} golangci-lint (separate CI job)"
    else
        check_tool "golangci-lint" "golangci-lint" "brew install golangci-lint"
    fi
    if $CI_MODE; then echo -e "  ${GREEN}[OK]${NC} Docker (GitHub Actions)"
    else
        if docker info &>/dev/null 2>&1; then echo -e "  ${GREEN}[OK]${NC} Docker (running)"
        else echo -e "  ${YELLOW}[WARN]${NC} Docker not running — container tests will be skipped"; fi
    fi
}

s_build()  { banner "Build";   run_cmd "go build ./..." go build ./...; }
s_lint()   { banner "Lint (golangci-lint)"; run_cmd "golangci-lint" golangci-lint run ./...; }

s_coverage() {
    banner "Full Test Suite + Coverage Report"
    echo ""; echo -e "  ${BLUE}\$${NC} go test -count=1 -coverprofile=coverage.out ./..."
    go test -count=1 -coverprofile=coverage.out ./... 2>&1 | sed 's/^/  /' || true
    echo ""
    local total; total=$(go tool cover -func=coverage.out 2>/dev/null | grep total | awk '{print $3}')
    echo -e "  ${BOLD}Total Coverage: ${GREEN}${total}${NC}"
    local threshold=75; local pct; pct=$(echo "$total" | sed 's/%//')
    if echo "$pct $threshold" | awk '{exit ($1 >= $2 ? 0 : 1)}'; then
        echo -e "  ${GREEN}[PASS]${NC} Coverage ${total} >= ${threshold}% threshold"; PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} Coverage ${total} < ${threshold}% threshold"; FAILED=$((FAILED + 1)); FAILED_STEPS+=("Coverage ${total} < ${threshold}%")
    fi
    echo ""; echo "  Per-package coverage:"
    go tool cover -func=coverage.out | grep -v "total:" | grep "0.0%" | sed 's/^/  /'
}

s_full_check() {
    banner "Full Check — Build + Lint + Test + Coverage"
    step "build"   "Build";   go build ./...  2>&1 | sed 's/^/  /' || true
    step "lint"    "Lint";    golangci-lint run ./... 2>&1 | sed 's/^/  /' || true
    step "test"    "Test + Coverage"; go test -count=1 -coverprofile=coverage.out ./... 2>&1 | sed 's/^/  /'
    step "summary" "Coverage"; go tool cover -func=coverage.out 2>/dev/null | grep -E "ok |total:" | sed 's/^/  /' || true
    local total; total=$(go tool cover -func=coverage.out 2>/dev/null | grep total | awk '{print $3}' | sed 's/%//')
    if [[ -n "$total" ]]; then echo -e "  ${BOLD}Total Coverage: ${GREEN}${total}%${NC}"; fi
}
