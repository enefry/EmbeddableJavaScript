import re
import sys

def parse_coverage(filename):
    total_lines = 0
    total_executed = 0
    file_stats = []

    with open(filename, 'r') as f:
        current_file = None
        for line in f:
            file_match = re.match(r"^File '(.*)'", line)
            if file_match:
                current_file = file_match.group(1)
            else:
                cov_match = re.match(r"^Lines executed:([0-9.]+)% of ([0-9]+)", line)
                if cov_match and current_file:
                    if not any(x in current_file for x in ['third_party/', 'tests/', 'sample/', '/Library/']):
                        percent = float(cov_match.group(1))
                        lines = int(cov_match.group(2))
                        executed = int(round(percent * lines / 100.0))
                        total_lines += lines
                        total_executed += executed
                        file_stats.append((current_file, percent, lines))
                    current_file = None

    if total_lines == 0:
        print("No coverage data found.")
        return

    overall_percent = (total_executed / total_lines) * 100
    print(f"Overall Coverage: {overall_percent:.2f}% ({total_executed}/{total_lines} lines)")
    
    print("\nCoverage by File (sorted by percentage):")
    # sort by percent ascending
    file_stats.sort(key=lambda x: x[1])
    for f, p, l in file_stats:
        if l > 0:
            print(f"{p:6.2f}% of {l:4d} lines : {f}")

if __name__ == "__main__":
    parse_coverage("build_coverage/coverage.txt")
