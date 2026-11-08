# Contracts

Model-based tests for VeriPy's own stateful code, run with
[pytest-quint-connect](https://github.com/gigaverse-app/pytest-quint-connect). A small
[Quint](https://quint.sh) model states the rules. Quint generates histories of operations
from it, and pytest replays each history against the real code, comparing what the code
leaves behind with what the model says it should.

**Review the model, not the plumbing.** The `.qnt` file is the specification. The driver
(`conftest.py`) only applies steps and reads state back; it never computes an expected value.

## project-lock

`project_lock/project_lock.qnt` models the proof-artifact lifecycle of
`veripy project generate|check` (`veripy/project.py`, `run_project`):

- `generate` writes only after every enrolled target verifies. It then leaves exactly the
  current targets' `.dfy` and `.map.json` files and a lock recording what they came from.
- A changed enrollment needs `--update-enrollment`, and a changed contract needs
  `--update-contracts`. Adding or removing a target changes both.
- `check` never writes. It reports `verified` only when the lock and every enrolled target's
  artifacts match the current sources; otherwise it reports `stale`.
- The order matters: an enrollment error comes before a failed proof, which comes before a
  contract change or a stale artifact.

The type gate and Dafny are stubbed for the length of each history. The stub prover accepts
every target the model has not marked as rejected. So this contract checks the orchestration
(gates, ordering, what gets written), not the translation or the prover, which `tests/` covers.

### Bug found

Removing a target left its `.dfy` and `.map.json` in the generated directory, and `check`
still passed. A proof of code that no longer existed stayed in the repository and looked
current. `generate` now deletes generated-artifact files that no enrolled target produces,
and `check` reports them as stale. Other files in the directory are left alone. The
`orphaned-proofs-survive` mutant puts the old behavior back, and the contract must catch it.

## Run it

```sh
pip install -e ".[contracts]"   # Node.js 22+ too; the plugin installs Quint 0.33.1 on first use
pytest-quint-connect codegen --check contracts/project_lock/quint-connect.json
python -m pytest -c contracts/quint.ini contracts --quint-require-complete
```

After editing the model, regenerate the typed driver base with
`pytest-quint-connect codegen contracts/project_lock/quint-connect.json` and commit it.

<!-- pytest-quint-connect:start -->
<!-- pytest-quint-connect:end -->
