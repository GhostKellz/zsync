#!/bin/bash
# Memory Leak Detection for zsync
# Uses Zig's GeneralPurposeAllocator leak detection + valgrind if available

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  zsync Memory Leak Detection${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""

# Build with debug mode (enables GPA leak detection)
echo -e "${BLUE}[1/3] Building with debug mode (GPA leak detection)...${NC}"
zig build -Doptimize=Debug 2>&1

# Run tests with leak detection
echo -e "${BLUE}[2/3] Running tests with leak detection...${NC}"
if zig build test -Doptimize=Debug 2>&1; then
    echo -e "${GREEN}[PASS]${NC} No memory leaks detected by GPA"
else
    echo -e "${RED}[FAIL]${NC} Memory issues detected"
    exit 1
fi

# Valgrind check if available
echo -e "${BLUE}[3/3] Checking for valgrind...${NC}"
if command -v valgrind &> /dev/null; then
    echo "Valgrind found, running memory analysis..."

    # Build a test binary
    if [ -f "zig-out/bin/zsync" ]; then
        valgrind --leak-check=full \
                 --show-leak-kinds=all \
                 --track-origins=yes \
                 --error-exitcode=1 \
                 ./zig-out/bin/zsync --help 2>&1 | tee /tmp/valgrind_output.txt

        if grep -q "no leaks are possible" /tmp/valgrind_output.txt; then
            echo -e "${GREEN}[PASS]${NC} Valgrind: No leaks detected"
        elif grep -q "definitely lost: 0 bytes" /tmp/valgrind_output.txt; then
            echo -e "${GREEN}[PASS]${NC} Valgrind: No definite leaks"
        else
            echo -e "${YELLOW}[WARN]${NC} Valgrind found potential issues"
        fi
    else
        echo -e "${YELLOW}[SKIP]${NC} No binary to test with valgrind"
    fi
else
    echo -e "${YELLOW}[SKIP]${NC} Valgrind not installed"
    echo "  Install with: sudo pacman -S valgrind  (Arch)"
    echo "            or: sudo apt install valgrind (Debian/Ubuntu)"
fi

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Memory check complete${NC}"
