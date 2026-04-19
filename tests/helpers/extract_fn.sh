# Extract a single function definition from a bash script to stdout.
# Usage: extract_fn <script_path> <fn_name>
#
# Why: the main scripts call `die` and exit early during `set -euo pipefail`
# sourcing (no root, missing /etc files, etc.), so we cannot simply `source`
# the whole file in a test. Instead, pluck out the function we want to test
# and eval it into the test shell.
extract_fn() {
    local script=$1 fn=$2
    awk -v fn="$fn" '
        $0 ~ "^"fn"\\(\\) \\{" { in_fn = 1; depth = 1; print; next }
        in_fn {
            # Track {} depth on the line to find the closing brace.
            for (i = 1; i <= length($0); i++) {
                c = substr($0, i, 1)
                if (c == "{") depth++
                else if (c == "}") depth--
            }
            print
            if (depth == 0) exit 0
        }
    ' "$script"
}
