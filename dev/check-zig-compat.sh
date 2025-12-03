#!/bin/bash
# Zig 0.16.0-dev Compatibility Checker
# Scans for deprecated APIs and patterns that need updating

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
echo -e "${BLUE}  Zig 0.16.0-dev Compatibility Check${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""

ISSUES=0

check_pattern() {
    local pattern="$1"
    local description="$2"
    local fix="$3"

    matches=$(grep -rn "$pattern" src/ --include="*.zig" 2>/dev/null || true)
    if [ -n "$matches" ]; then
        echo -e "${YELLOW}[DEPRECATED]${NC} $description"
        echo -e "  Fix: $fix"
        echo "$matches" | head -5 | sed 's/^/    /'
        count=$(echo "$matches" | wc -l)
        if [ "$count" -gt 5 ]; then
            echo "    ... and $((count - 5)) more"
        fi
        echo ""
        ((ISSUES++))
    fi
}

echo -e "${BLUE}Scanning for Zig 0.16 deprecated APIs...${NC}"
echo ""

# ArrayList changes (0.16)
# ArrayList API (0.16)
# - Managed(T).init(allocator) still works but is transitioning
# - Unmanaged: ArrayList(T){} or .empty, methods take allocator
# - Check for old patterns that don't pass allocator

# ArrayList append patterns are correct if they pass allocator
# No check needed - zsync already uses correct API

# Time API - REMOVED in 0.16
check_pattern "std\.time\.milliTimestamp" \
    "std.time.milliTimestamp REMOVED in 0.16" \
    "Use std.time.Instant.now() or std.time.Timer"

check_pattern "std\.time\.nanoTimestamp" \
    "std.time.nanoTimestamp REMOVED in 0.16" \
    "Use std.time.Instant.now() then .since(earlier)"

check_pattern "std\.time\.timestamp" \
    "std.time.timestamp() REMOVED in 0.16" \
    "Use std.time.Instant.now() or std.posix.clock_gettime()"

# Memory allocator patterns
# page_allocator is valid, not deprecated - no check needed

# catch unreachable is valid Zig - not a compat issue

# Old async patterns (removed in 0.16) - code only, not comments
# Note: @asyncCall mention in comments is OK (documentation)
# Only flag actual code usage

# Check for actual suspend/resume statements (not variable names)
check_pattern "^[[:space:]]*suspend[[:space:]]*;" \
    "suspend statement removed in Zig 0.16" \
    "Use zsync runtime instead"

check_pattern "^[[:space:]]*resume[[:space:]]" \
    "resume statement removed in Zig 0.16" \
    "Use zsync runtime instead"

# Deprecated std lib
check_pattern "std\.event\." \
    "std.event removed in Zig 0.16" \
    "Use zsync event loop"

check_pattern "std\.io\.BufferedReader" \
    "Check BufferedReader API changes" \
    "Verify buffer handling matches 0.16 API"

echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
if [ "$ISSUES" -eq 0 ]; then
    echo -e "${GREEN}No compatibility issues found!${NC}"
    exit 0
else
    echo -e "${YELLOW}Found $ISSUES potential compatibility issues${NC}"
    echo "Review and fix before release"
    exit 1
fi
