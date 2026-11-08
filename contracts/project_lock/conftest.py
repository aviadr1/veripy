"""Drive `veripy.project.run_project` through the project-lock model's histories.

The driver applies each model action to a real project directory (sources, manifest,
generated artifacts) and reads the directory and lock back. It never decides a status:
statuses come from `run_project`, expectations only from `project_lock.qnt`.

The type gate and Dafny are replaced by stubs for the length of one history, so the
contract checks run_project's orchestration (review gates, check ordering, what gets
written) in seconds. The stub prover accepts every target except the ones `set_proof`
marked as rejected.
"""

import json
import tempfile
import types
from collections.abc import Callable
from pathlib import Path

import pytest
from project_lock_driver import ProjectLockDriver, View

import veripy.project
from pytest_quint_connect import HistoryContext
from veripy.backends.dafny.backend import DafnyBackend
from veripy.backends.dafny.driver import VerifyResult
from veripy.frontend.typegate import TypeGateResult

PROJECT_SOURCE = Path(veripy.project.__file__)
TARGETS = ("a", "b")
CONTRACTS = ("result == n", "result >= n")
BODIES = ("n", "n + 0")
LOCK = "project.lock.json"
SUFFIXES = {".dfy": "proofs", ".map.json": "maps"}

# Each mutant is one plausible bug in veripy/project.py, written as an exact source edit.
MUTANTS: dict[str, tuple[str, str]] = {
    "check-writes": (
        '        if mode == "check":\n            stale =',
        "        if False:\n            stale =",
    ),
    "no-contract-review": (
        'if mode == "generate" and not update_contracts:',
        "if False:",
    ),
    "no-enrollment-review": (
        'if previous and previous.get("enrollment") != enrollment and not (mode == "generate" and update_enrollment):',
        "if False:",
    ),
    "ignores-failed-proof": (
        '        if failed:\n            report["status"] = failed[0]["proof_status"]',
        '        if False:\n            report["status"] = failed[0]["proof_status"]',
    ),
    "check-ignores-missing-artifact": (
        "not (artifacts / name).is_file() or (artifacts / name).read_text() != text",
        "(artifacts / name).is_file() and (artifacts / name).read_text() != text",
    ),
    # Reintroduces the shipped pre-fix code: no orphaned artifact is ever noticed or removed.
    "orphaned-proofs-survive": (
        "and path.name not in outputs) if artifacts.is_dir() else []",
        "and path.name not in outputs and False) if artifacts.is_dir() else []",
    ),
    "lock-forgets-contracts": (
        '"contracts": contracts, "compiler": compiler,',
        '"contracts": {}, "compiler": compiler,',
    ),
}


def project_module(mutant: str | None) -> types.ModuleType:
    """The real veripy.project, or a copy with exactly one mutant edit applied."""
    if mutant is None:
        return veripy.project
    old, new = MUTANTS[mutant]
    text = PROJECT_SOURCE.read_text()
    assert text.count(old) == 1, f"mutant {mutant!r} no longer matches veripy/project.py"
    module = types.ModuleType(f"veripy._project_mutant_{mutant.replace('-', '_')}")
    module.__file__ = str(PROJECT_SOURCE)  # the compiler fingerprint hashes the real package
    exec(compile(text.replace(old, new), str(PROJECT_SOURCE), "exec"), module.__dict__)
    return module


def source_text(contract: int, body: int) -> str:
    return f"# @ ensures {CONTRACTS[contract]}\ndef pick(n: int) -> int:\n    return {BODIES[body]}\n"


class ProjectDriver(ProjectLockDriver):
    """Applies model actions to a real project directory. No lifecycle logic lives here."""

    def __init__(self, context: HistoryContext) -> None:
        self.project = project_module(context.mutant)
        self.failing: set[str] = set()
        self.patches = pytest.MonkeyPatch()
        failing = self.failing

        def verify_artifact(backend: DafnyBackend, artifact: Path, line_map: dict[int, int], *,
                            time_limit: int, extent: int | None) -> VerifyResult:
            if artifact.stem in failing:
                return VerifyResult(ok=False, summary="Dafny program verifier finished with 0 verified, 1 error")
            return VerifyResult(ok=True, summary="Dafny program verifier finished with 99 verified, 0 errors")

        self.patches.setattr(self.project, "run_type_gate", lambda paths: TypeGateResult(available=True, version="stub"))
        self.patches.setattr(DafnyBackend, "prover_version", lambda backend: "4.11.0")
        self.patches.setattr(DafnyBackend, "verify_artifact", verify_artifact)
        context.work_dir.mkdir(parents=True, exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix="project-", dir=context.work_dir))
        self.status = "none"
        self.enrolled: set[str] = set()
        self.contract = dict.fromkeys(TARGETS, 0)
        self.body = dict.fromkeys(TARGETS, 0)

    def close(self) -> None:
        self.patches.undo()

    @property
    def manifest(self) -> Path:
        return self.root / "veripy-project.json"

    @property
    def artifacts(self) -> Path:
        return self.root / "proofs" / "generated"

    def write_source(self, target: str) -> None:
        (self.root / f"{target}.py").write_text(source_text(self.contract[target], self.body[target]))

    def write_manifest(self) -> None:
        targets = sorted(self.enrolled)
        self.manifest.write_text(json.dumps({
            "version": 1, "sources": ["*.py"], "required_targets": targets,
            "targets": [{"id": t, "source": f"{t}.py", "backend": "dafny", "functions": ["pick"], "dependencies": []}
                        for t in targets],
            "artifacts": "proofs/generated", "dafny_version": "4.11.0",
        }, indent=2))

    def init(self) -> None:
        (self.root / "pyrightconfig.json").write_text('{"typeCheckingMode": "strict"}')
        self.enrolled = set(TARGETS)
        for target in TARGETS:
            self.write_source(target)
        self.write_manifest()

    def generate(self, update_enrollment: bool, update_contracts: bool) -> None:
        self.status = self.project.run_project(self.manifest, "generate", update_enrollment=update_enrollment,
                                               update_contracts=update_contracts)["status"]

    def check(self) -> None:
        self.status = self.project.run_project(self.manifest, "check")["status"]

    def edit_body(self, target: str) -> None:
        self.body[target] = 1 - self.body[target]
        self.write_source(target)

    def edit_contract(self, target: str) -> None:
        self.contract[target] = 1 - self.contract[target]
        self.write_source(target)

    def enroll(self, target: str) -> None:
        self.enrolled.add(target)
        self.write_source(target)
        self.write_manifest()

    def unenroll(self, target: str) -> None:
        self.enrolled.discard(target)
        (self.root / f"{target}.py").unlink()
        self.write_manifest()

    def set_proof(self, target: str, fails: bool) -> None:
        if fails:
            self.failing.add(target)
        else:
            self.failing.discard(target)

    def delete_artifact(self, target: str) -> None:
        (self.artifacts / f"{target}.dfy").unlink()

    def inspect(self) -> None:
        pass

    def observe(self) -> View:
        lock_path = self.artifacts / LOCK
        lock_targets: set[str] = set()
        if lock_path.is_file():
            lock_targets = {entry["id"] for entry in json.loads(lock_path.read_text())["enrollment"]["targets"]}
        found: dict[str, set[str]] = {"proofs": set(), "maps": set(), "strays": set()}
        if self.artifacts.is_dir():
            for path in self.artifacts.iterdir():
                if path.name == LOCK:
                    continue
                suffix = next((s for s in SUFFIXES if path.name.endswith(s)), None)
                if suffix is None:
                    found["strays"].add(path.name)
                else:
                    found[SUFFIXES[suffix]].add(path.name.removesuffix(suffix))
        return {"status": self.status, "hasLock": lock_path.is_file(), "lockTargets": lock_targets,
                "proofs": found["proofs"], "maps": found["maps"], "strays": found["strays"]}


@pytest.fixture
def project_driver() -> Callable[[HistoryContext], ProjectDriver]:
    return ProjectDriver
