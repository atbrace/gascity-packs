"""Isolate the test suite from the ambient Gas Town agent environment.

Gas Town exports its session identity and configuration into every agent
session as ``GC_*`` and ``BEADS_*`` variables. The scripts these packs test
derive real decisions from exactly those variables — ``GC_BIN`` becomes the
subprocess argv prefix the intake services build, and ``GC_TEMPLATE`` becomes
the claim command's expected route — so a suite run inside an agent session
sees argv and routing that no test fixture asked for. CI has none of them set,
which is why those tests are green there and red on any developer machine or
agent session that does.

Stripping them here makes every run match CI. ``GC_TEST_BIN`` is preserved:
CI sets it deliberately to point the role-prompt integration tests at a real
gc binary.
"""

import os

_PRESERVED = {"GC_TEST_BIN"}

for _name in [
    _n
    for _n in os.environ
    if _n.startswith(("GC_", "BEADS_")) and _n not in _PRESERVED
]:
    del os.environ[_name]
