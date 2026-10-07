# Shell & Command Execution Guidelines

## Restrictions on Inline Scripts
- **NEVER** run inline scripts via `-c` or `-e` flags in shell commands:
  - Do NOT execute `python3 -c "..."` or `python -c "..."`.
  - Do NOT execute `node -e "..."`.
  - Do NOT execute inline `ruby -e` or `perl -e` commands.
- **Do NOT wrap CLI tools in `subprocess`:** Run compiler, build, and inspection tools directly in shell commands (e.g. `swiftc ...`, `git ...`, `xcodebuild ...`, `clang ...`). Wrapping them inside Python `subprocess.check_output` or similar scripts is prohibited.

## How to Run Helper Scripts
If a multi-step inspection or test script is strictly necessary:
1. Write the code to a temporary script file first using file editing/creation tools (e.g. `scripts/temp_check.py` or `.agents/scratch/check.py`).
2. Run the script via `python3 path/to/script.py`.
3. Clean up the temporary file if it is no longer needed.
