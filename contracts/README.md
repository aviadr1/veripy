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
<!-- pytest-quint-connect:contracts project-lock -->
<a href="https://github.com/gigaverse-app/pytest-quint-connect" title="Mutants: deliberately broken copies of the code. Each must make some history diverge, proving the contract would notice that kind of bug"><img alt="Quint contracts: 1 contract passed · 21 histories · 7/7 planted bugs caught" src="https://img.shields.io/badge/Quint_contracts-1_contract_passed_%C2%B7_21_histories_%C2%B7_7%2F7_planted_bugs_caught-brightgreen"></a>

| | Contract | Cases passed | [Planted bugs caught](https://github.com/gigaverse-app/pytest-quint-connect/blob/main/docs/why.md#proof-that-the-tests-can-fail "Mutants: deliberately broken copies of the code. Each must make some history diverge, proving the contract would notice that kind of bug") |
| :-: | :-- | --: | --: |
| ✅ | `project-lock` `project_lock/test_project_lock_contract.py::test_project_lock`<br><sub>21 histories (5 witnesses, 16 samples, seed 11) · every action covered · Quint 0.33.1</sub> | 29/29 | 7/7 |

**Bugs this contract found**

1. **Removing a target left its .dfy and .map.json in the generated directory and check still passed, so a proof of deleted code looked current.** Fixed in https://github.com/aviadr1/veripy/pull/3 · found by witness removedTargetLeavesNoProofTest, and independently a sampled history · regression test `tests/project/test_project.py::test_removed_target_leaves_no_proof_artifacts`. 2 of 21 histories diverge when [planted bug](https://github.com/gigaverse-app/pytest-quint-connect/blob/main/docs/why.md#proof-that-the-tests-can-fail "Mutants: deliberately broken copies of the code. Each must make some history diverge, proving the contract would notice that kind of bug") `orphaned-proofs-survive` (a removed target's .dfy and .map.json stay in the artifacts directory and check still passes (the shipped behavior before the fix)) reintroduces it; first caught by `witness-removedTargetLeavesNoProofTest` at state 4, after `generate(body=0, contract=0, fails=False, target='', updateContracts=True, updateEnrollment=True)`.

**[Planted bugs](https://github.com/gigaverse-app/pytest-quint-connect/blob/main/docs/why.md#proof-that-the-tests-can-fail "Mutants: deliberately broken copies of the code. Each must make some history diverge, proving the contract would notice that kind of bug") this contract catches**

- `check-writes`: check also writes artifacts and the lock, so CI would silently refresh a stale proof. Caught by `witness-bodyEditIsStaleUntilRegeneratedTest` at state 3, after `check(body=0, contract=0, fails=False, target='', updateContracts=False, updateEnrollment=False)`.
- `no-contract-review`: generate accepts a changed contract without --update-contracts. Caught by `witness-contractEditNeedsReviewTest` at state 3, after `generate(body=0, contract=0, fails=False, target='', updateContracts=False, updateEnrollment=False)`.
- `no-enrollment-review`: a manifest whose enrollment differs from the lock is accepted without --update-enrollment. Caught by `witness-removedTargetLeavesNoProofTest` at state 3, after `check(body=0, contract=0, fails=False, target='', updateContracts=False, updateEnrollment=False)`.
- `ignores-failed-proof`: a rejected proof does not stop the run, so generate records it as verified. Caught by `witness-failedProofWritesNothingTest` at state 4, after `generate(body=0, contract=0, fails=False, target='', updateContracts=False, updateEnrollment=False)`.
- `check-ignores-missing-artifact`: check does not notice a deleted generated file. Caught by `sample-0` at state 1, after `check(body=0, contract=0, fails=False, target='', updateContracts=False, updateEnrollment=False)`.
- `lock-forgets-contracts`: the lock records no reviewed contracts, so every later generate demands review again. Caught by `witness-bodyEditIsStaleUntilRegeneratedTest` at state 4, after `generate(body=0, contract=0, fails=False, target='', updateContracts=False, updateEnrollment=False)`.

<details>
<summary>What <code>project-lock</code> says</summary>

**Actions**, and the code each one drives:

- `init`: a fresh project directory with targets a and b enrolled and no generated artifacts
- `generate`: run_project(manifest, 'generate', update_enrollment=..., update_contracts=...)
- `check`: run_project(manifest, 'check')
- `editBody`: rewrite the target's function body (same contract)
- `editContract`: rewrite the target's `# &#64; ensures` clause
- `enroll`: write the target's source and add its manifest entry
- `unenroll`: delete the target's source and remove its manifest entry
- `setProof`: make the stub prover reject (or accept again) the target's proof
- `deleteArtifact`: delete the target's generated .dfy file
- `inspect`: read the artifacts directory and lock without changing them

**Invariant** `noOrphanArtifacts`, checked while sampling histories.

**Witnesses**, scenarios replayed exactly as written: `freshGenerateThenCheckTest`, `bodyEditIsStaleUntilRegeneratedTest`, `contractEditNeedsReviewTest`, `removedTargetLeavesNoProofTest`, `failedProofWritesNothingTest`.

**Bounds**: seed `11` · max_samples `400` · max_steps `10` · n_traces `16`.

**Witness `freshGenerateThenCheckTest`, step by step**: what the model expects the code to show after each action.

| State | Action | Model expects |
| --: | :-- | :-- |
| `0` | `init(body=0, contract=0, fails=False, target='', updateContracts=False, updateEnrollment=False)` | `{ hasLock: false, lockTargets: Set(), maps: Set(), proofs: Set(), status: "none", strays: Set() }` |
| `1` | `generate(body=0, contract=0, fails=False, target='', updateContracts=False, updateEnrollment=False)` | `{ hasLock: true, lockTargets: Set("a", "b"), maps: Set("a", "b"), proofs: Set("a", "b"), status: "verified", strays: Set() }` |
| `2` | `check(body=0, contract=0, fails=False, target='', updateContracts=False, updateEnrollment=False)` | `{ hasLock: true, lockTargets: Set("a", "b"), maps: Set("a", "b"), proofs: Set("a", "b"), status: "verified", strays: Set() }` |
| `3` | `inspect(body=0, contract=0, fails=False, target='', updateContracts=False, updateEnrollment=False)` | `{ hasLock: true, lockTargets: Set("a", "b"), maps: Set("a", "b"), proofs: Set("a", "b"), status: "verified", strays: Set() }` |

</details>

<sub>Generated by [pytest-quint-connect](https://github.com/gigaverse-app/pytest-quint-connect) from contract receipts; [what a passing run proves](https://github.com/gigaverse-app/pytest-quint-connect/blob/main/docs/limits.md).</sub>
<!-- pytest-quint-connect:end -->
