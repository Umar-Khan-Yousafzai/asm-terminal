# Self-test of the case-file machinery (tests/run_tests.sh sources every
# tests/cases/*.sh, then runs every tests/cases/*.py through py_cases).
run_case "cases: hermetic HOME"       'echo $HOME'                    "/asm-tests\\."
