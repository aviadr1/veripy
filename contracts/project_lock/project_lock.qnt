// The proof-artifact lifecycle of `veripy project generate|check` (veripy/project.py, run_project).
// Two candidate targets, "a" and "b". Each has a body version and a contract version; the prover
// either accepts or rejects it. `observed` is what the driver reads back from the real project
// directory after every step: the last run's status, the lock's enrolled targets, and the files
// in the generated-artifacts directory, by kind.
module project_lock {
  type Event = {
    op: str, target: str, body: int, contract: int, fails: bool,
    updateEnrollment: bool, updateContracts: bool,
  }
  // Generated files by kind: `proofs` holds the targets with a `<id>.dfy` proof program, `maps`
  // those with a `<id>.map.json` source map, `strays` any other file name in the directory.
  type View = {
    status: str, hasLock: bool, lockTargets: Set[str],
    proofs: Set[str], maps: Set[str], strays: Set[str],
  }
  // What the lock records: the enrolled targets and the input versions it was generated from.
  type Record = { targets: Set[str], body: str -> int, contract: str -> int }

  pure val TARGETS = Set("a", "b")
  pure val ZERO = TARGETS.mapBy(t => 0)

  var event: Event
  var observed: View
  // Model-only state: the current inputs (manifest enrollment, source versions, prover verdicts)
  // and the versions the lock recorded. Checked through their effects on later runs.
  var enrolled: Set[str]
  var body: str -> int
  var contract: str -> int
  var failing: Set[str]
  var recorded: Record

  pure def ev(op: str, target: str, b: int, c: int, fails: bool, ue: bool, uc: bool): Event =
    { op: op, target: target, body: b, contract: c, fails: fails, updateEnrollment: ue, updateContracts: uc }

  // The lock was generated from exactly the current enrollment and source versions.
  val lockCurrent = observed.hasLock and recorded.targets == enrolled
    and enrolled.forall(t => recorded.body.get(t) == body.get(t) and recorded.contract.get(t) == contract.get(t))
  // Reviewed contracts differ from the current ones (a target added or removed counts).
  val contractsChanged = recorded.targets != enrolled
    or enrolled.exists(t => recorded.contract.get(t) != contract.get(t))

  action unchangedInputs = all {
    enrolled' = enrolled, body' = body, contract' = contract, failing' = failing, recorded' = recorded,
  }

  action init = all {
    event' = ev("init", "", 0, 0, false, false, false),
    observed' = { status: "none", hasLock: false, lockTargets: Set(), proofs: Set(), maps: Set(), strays: Set() },
    enrolled' = TARGETS, body' = ZERO, contract' = ZERO, failing' = Set(),
    recorded' = { targets: Set(), body: ZERO, contract: ZERO },
  }

  // One run of `veripy project <mode>`. Checks apply in this order: enrollment, proofs,
  // contract review (generate only), then artifact freshness (check) or writing (generate).
  action runProject(mode: str, updateEnrollment: bool, updateContracts: bool): bool = {
    val status =
      if (enrolled == Set()) "enrollment-error"
      else if (observed.hasLock and recorded.targets != enrolled and not(mode == "generate" and updateEnrollment))
        "enrollment-error"
      else if (enrolled.exists(t => failing.contains(t))) "failed"
      else if (mode == "generate" and observed.hasLock and contractsChanged and not(updateContracts)) "contract-change"
      else if (mode == "check")
        if (lockCurrent and enrolled.subseteq(observed.proofs) and enrolled.subseteq(observed.maps)) "verified"
        else "stale"
      else "verified"
    // Only a verified generate writes, and it leaves exactly the current targets' artifacts.
    val writes = mode == "generate" and status == "verified"
    all {
      event' = ev(mode, "", 0, 0, false, updateEnrollment, updateContracts),
      observed' = if (writes)
        { status: status, hasLock: true, lockTargets: enrolled, proofs: enrolled, maps: enrolled, strays: Set() }
        else { ...observed, status: status },
      recorded' = if (writes) { targets: enrolled, body: body, contract: contract } else recorded,
      enrolled' = enrolled, body' = body, contract' = contract, failing' = failing,
    }
  }

  action generate(updateEnrollment: bool, updateContracts: bool): bool = runProject("generate", updateEnrollment, updateContracts)
  action check = runProject("check", false, false)

  // Edit the implementation (not the contract) of an enrolled source.
  action editBody(target: str): bool = {
    val v = 1 - body.get(target)
    all {
      enrolled.contains(target),
      event' = ev("editBody", target, v, contract.get(target), false, false, false),
      observed' = observed, body' = body.set(target, v),
      enrolled' = enrolled, contract' = contract, failing' = failing, recorded' = recorded,
    }
  }

  // Edit the `# @ ensures` contract of an enrolled source.
  action editContract(target: str): bool = {
    val v = 1 - contract.get(target)
    all {
      enrolled.contains(target),
      event' = ev("editContract", target, body.get(target), v, false, false, false),
      observed' = observed, contract' = contract.set(target, v),
      enrolled' = enrolled, body' = body, failing' = failing, recorded' = recorded,
    }
  }

  // Add the source file and its manifest entry; remove both.
  action enroll(target: str): bool = all {
    not(enrolled.contains(target)),
    event' = ev("enroll", target, body.get(target), contract.get(target), false, false, false),
    observed' = observed, enrolled' = enrolled.union(Set(target)),
    body' = body, contract' = contract, failing' = failing, recorded' = recorded,
  }

  action unenroll(target: str): bool = all {
    enrolled.contains(target),
    event' = ev("unenroll", target, 0, 0, false, false, false),
    observed' = observed, enrolled' = enrolled.exclude(Set(target)),
    body' = body, contract' = contract, failing' = failing, recorded' = recorded,
  }

  // The prover starts rejecting (or accepting again) the target.
  action setProof(target: str, fails: bool): bool = all {
    event' = ev("setProof", target, 0, 0, fails, false, false),
    observed' = observed,
    failing' = if (fails) failing.union(Set(target)) else failing.exclude(Set(target)),
    enrolled' = enrolled, body' = body, contract' = contract, recorded' = recorded,
  }

  // Someone deletes a generated proof program from the artifacts directory.
  action deleteArtifact(target: str): bool = all {
    observed.proofs.contains(target),
    event' = ev("deleteArtifact", target, 0, 0, false, false, false),
    observed' = { ...observed, proofs: observed.proofs.exclude(Set(target)) },
    unchangedInputs,
  }

  // A read-only step, so that a witness can end in an assertion without repeating an action.
  action inspect = all { event' = ev("inspect", "", 0, 0, false, false, false), observed' = observed, unchangedInputs }

  action step = {
    nondet target = TARGETS.oneOf()
    nondet updateEnrollment = Bool.oneOf()
    nondet updateContracts = Bool.oneOf()
    nondet fails = Bool.oneOf()
    any {
      generate(updateEnrollment, updateContracts), check, editBody(target), editContract(target), enroll(target), unenroll(target),
      setProof(target, fails), deleteArtifact(target),
    }
  }

  // Every generated file belongs to a target the lock records: no orphaned proofs.
  val noOrphanArtifacts = observed.proofs.union(observed.maps).subseteq(observed.lockTargets) and observed.strays == Set()

  run freshGenerateThenCheckTest = init.then(generate(false, false)).then(check)
    .then(all { assert(observed.status == "verified" and observed.proofs == TARGETS and observed.maps == TARGETS), inspect })

  run bodyEditIsStaleUntilRegeneratedTest = init.then(generate(false, false)).then(editBody("a")).then(check)
    .then(all { assert(observed.status == "stale"), generate(false, false) })
    .then(check).then(all { assert(observed.status == "verified"), inspect })

  run contractEditNeedsReviewTest = init.then(generate(false, false)).then(editContract("a"))
    .then(generate(false, false))
    .then(all { assert(observed.status == "contract-change"), generate(false, true) })
    .then(check).then(all { assert(observed.status == "verified"), inspect })

  run removedTargetLeavesNoProofTest = init.then(generate(false, false)).then(unenroll("b"))
    .then(check).then(all { assert(observed.status == "enrollment-error"), generate(true, true) })
    .then(all { assert(observed.proofs == Set("a") and observed.maps == Set("a") and observed.lockTargets == Set("a")), check })
    .then(all { assert(observed.status == "verified"), inspect })

  run failedProofWritesNothingTest = init.then(generate(false, false)).then(editBody("a"))
    .then(setProof("a", true)).then(generate(false, false))
    .then(all { assert(observed.status == "failed"), deleteArtifact("b") })
    .then(check).then(all { assert(observed.status == "failed" and observed.proofs == Set("a") and observed.maps == TARGETS), inspect })
}
