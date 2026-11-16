# DELIBERATELY VULNERABLE - never imported or executed.
# CI scans this file separately and asserts that Semgrep FAILS on it, proving the
# SAST gate is a real gate (the legacy pipeline's allow_failure scan could never fail).
import subprocess


def run(user_input):
    subprocess.call("echo " + user_input, shell=True)
    return eval(user_input)
