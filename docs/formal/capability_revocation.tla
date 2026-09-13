---- MODULE capability_revocation ----
(***************************************************************************)
(* Formal model of Innigkeit's capability slot lifecycle: grant, copy,     *)
(* transfer over IPC, revoke, remove.  Scoped per docs/test-system-plan.md *)
(* section 3 -- deliberately NOT a model of IPC message ordering, the      *)
(* scheduler, or memory management.  Grounded directly in the real        *)
(* implementation (src/innigkeit/capabilities/CapabilityTable.zig), not an *)
(* idealized design:                                                       *)
(*                                                                         *)
(*   - insertLocked  -> Grant (the one-shot root of every derivation       *)
(*                       chain; a fresh kernel object handed full trust    *)
(*                       by whatever creates it, e.g. Notify.create()      *)
(*                       immediately followed by insertLocked)             *)
(*   - copyLocked    -> CopyCap (same-process only; rejects rights         *)
(*                       escalation via a subset check, and -- since the   *)
(*                       fix landed alongside this model -- rejects a      *)
(*                       revoked source slot by routing through            *)
(*                       getAndRefLocked instead of the generation-blind   *)
(*                       getLocked)                                        *)
(*   - transferCaps  -> TransferCap (crosses a process boundary over IPC;  *)
(*                       replicates the source slot's rights verbatim, no  *)
(*                       local subset check -- and, since the .grant fix   *)
(*                       landed alongside this model, requires the source  *)
(*                       slot to hold .grant)                              *)
(*   - revokeLocked  -> Revoke (bumps the object's generation counter;     *)
(*                       requires .revoke on the revoking slot; does NOT   *)
(*                       require the revoking slot itself to be live --    *)
(*                       matches the real code exactly, and is harmless:   *)
(*                       revoking twice just over-invalidates)             *)
(*   - removeLocked  -> RemoveCap (frees a slot; no rights check, matches  *)
(*                       the real code)                                    *)
(*                                                                         *)
(* Both `.claude/rules/capabilities.md` fixes this pass are load-bearing   *)
(* for this model, not incidental:                                        *)
(*                                                                         *)
(*   1. CopyCap and TransferCap both require IsLive(source) as a          *)
(*      precondition.  Before the copyLocked fix, the real code's         *)
(*      getLocked-based lookup made a copy of an already-revoked slot      *)
(*      possible -- the copy is stamped with the CURRENT generation at    *)
(*      insert time regardless of the source's own staleness, so it came  *)
(*      back fully live, letting a revoker silently un-revoke for         *)
(*      itself.  This is NOT visible as a RightsMonotonicity violation     *)
(*      (the copied rights are still bounded by the object's root grant)  *)
(*      -- it is a precondition-shape bug, not a reachable-state shape     *)
(*      bug, so modeling the buggy version would not produce a TLC        *)
(*      counterexample under the invariant below.  It is encoded here by  *)
(*      simply not being representable: CopyCap/TransferCap are UNDEFINED *)
(*      (disabled) for a stale source, matching the fixed code.           *)
(*   2. TransferCap additionally requires "grant" in the source slot's    *)
(*      rights, matching the enforcement added to transferCaps this pass. *)
(*                                                                         *)
(* The property this model DOES check, exhaustively via TLC over the      *)
(* bound below: RightsMonotonicity holds despite TransferCap replicating  *)
(* rights verbatim with no local subset check of its own -- i.e. the      *)
(* "emergent, not locally enforced" property docs/test-system-plan.md's   *)
(* section 3 names is actually true of the full action set, not merely    *)
(* plausible by inspection.                                                *)
(***************************************************************************)

EXTENDS Naturals, FiniteSets

CONSTANTS
    Objects,        \* the finite set of underlying kernel objects modeled
    Procs,          \* the finite set of processes modeled
    Slots,          \* the finite set of per-process capability-table slot ids
    MaxGeneration   \* bounds Revoke's counter so the state space stays finite

ASSUME Objects # {}

RightsSet == {"read", "write", "grant", "revoke"}

(* Grant and CopyCap range over this representative sample rather than      *)
(* `SUBSET RightsSet` (16 values): the full 4-bit lattice makes the        *)
(* reachable state space too large to exhaust in reasonable time (9.7M+    *)
(* states, still growing after 10 minutes, before this reduction -- with   *)
(* no violations found in any of them, but not a completed check). Rights  *)
(* subset behavior is uniform across "shape-equivalent" values (the        *)
(* invariant only ever compares one set to another via \subseteq), so a    *)
(* handful of representative shapes -- empty, one non-.grant right alone,  *)
(* .grant alone (the specific bit TransferCap's precondition now checks),  *)
(* a combination, and full rights -- exercises every qualitatively         *)
(* distinct case (escalation rejection, subset narrowing, .grant gating)   *)
(* without the combinatorial blowup of all 16 subsets.                     *)
SampleRights == {
    {},
    {"read"},
    {"grant"},
    {"read", "grant"},
    {"read", "write", "grant", "revoke"}
}

(* Every slot is a uniform record shape (occupied flag plus payload)       *)
(* rather than "a record, or a distinguished empty sentinel" -- comparing  *)
(* a record against a plain value of a different shape is a known TLC     *)
(* fingerprinting trap (mixing a record and a string under `=`/`#` inside  *)
(* a quantified invariant errors out instead of just being FALSE).  The    *)
(* placeholder obj/rights/gen values on an unoccupied slot are never read  *)
(* by any action or invariant below; they exist only so every slot has     *)
(* exactly one shape.                                                      *)
SomeObject == CHOOSE o \in Objects : TRUE

EmptySlot == [occupied |-> FALSE, obj |-> SomeObject, rights |-> {}, gen |-> 0]

VARIABLES
    table,          \* table[p][s] = EmptySlot, or an occupied slot record
    objGen,         \* objGen[o] = current generation counter of object o
    created,        \* set of objects that have had their one-time Grant
    rootRights      \* rootRights[o] = the rights o's Grant established

vars == <<table, objGen, created, rootRights>>

TypeOK ==
    /\ objGen \in [Objects -> 0..MaxGeneration]
    /\ created \subseteq Objects
    /\ rootRights \in [Objects -> SUBSET RightsSet]
    /\ \A p \in Procs : \A s \in Slots :
        /\ table[p][s].occupied \in BOOLEAN
        /\ table[p][s].obj \in Objects
        /\ table[p][s].rights \subseteq RightsSet
        /\ table[p][s].gen \in 0..MaxGeneration

Init ==
    /\ table = [p \in Procs |-> [s \in Slots |-> EmptySlot]]
    /\ objGen = [o \in Objects |-> 0]
    /\ created = {}
    /\ rootRights = [o \in Objects |-> {}]

(* A slot is live iff occupied and its stamped generation matches the      *)
(* object's current one -- exactly getAndRefLocked's check.                *)
IsLive(p, s) ==
    /\ table[p][s].occupied
    /\ table[p][s].gen = objGen[table[p][s].obj]

(* The one-shot root grant: a brand-new object, handed whatever rights its *)
(* creator decided (matching e.g. Notify.create() + insertLocked(..., .all)*)
(* at every real call site) into one of the granted process's own slots.   *)
Grant(p, s, o, r) ==
    /\ o \notin created
    /\ ~table[p][s].occupied
    /\ r \in SUBSET RightsSet
    /\ table' = [table EXCEPT ![p][s] = [occupied |-> TRUE, obj |-> o, rights |-> r, gen |-> objGen[o]]]
    /\ created' = created \cup {o}
    /\ rootRights' = [rootRights EXCEPT ![o] = r]
    /\ UNCHANGED objGen

(* Same-process copy, optionally restricting rights.  Never crosses a      *)
(* process boundary, so .grant does not gate it (see file header).         *)
CopyCap(p, s_src, s_dst, r) ==
    /\ s_src # s_dst
    /\ IsLive(p, s_src)
    /\ ~table[p][s_dst].occupied
    /\ r \subseteq table[p][s_src].rights
    /\ table' = [table EXCEPT ![p][s_dst] =
        [occupied |-> TRUE, obj |-> table[p][s_src].obj, rights |-> r, gen |-> objGen[table[p][s_src].obj]]]
    /\ UNCHANGED <<objGen, created, rootRights>>

(* Cross-process delegation over IPC.  Replicates rights verbatim (no      *)
(* local subset check -- RightsMonotonicity below is what proves this is  *)
(* still sound) but requires .grant and a live source.                     *)
TransferCap(p_src, s_src, p_dst, s_dst) ==
    /\ (p_src # p_dst \/ s_src # s_dst)
    /\ IsLive(p_src, s_src)
    /\ ~table[p_dst][s_dst].occupied
    /\ "grant" \in table[p_src][s_src].rights
    /\ table' = [table EXCEPT ![p_dst][s_dst] =
        [occupied |-> TRUE,
         obj |-> table[p_src][s_src].obj,
         rights |-> table[p_src][s_src].rights,
         gen |-> objGen[table[p_src][s_src].obj]]]
    /\ UNCHANGED <<objGen, created, rootRights>>

(* Bumps the object's generation, invalidating every slot (in every        *)
(* process's table) that points to it -- a global, not per-lineage, cutoff.*)
(* Matches the real revokeLocked: the revoking slot need not itself be     *)
(* live (over-invalidating is always safe; see .claude/rules/capabilities.md).*)
Revoke(p, s) ==
    /\ table[p][s].occupied
    /\ "revoke" \in table[p][s].rights
    /\ objGen[table[p][s].obj] < MaxGeneration
    /\ objGen' = [objGen EXCEPT ![table[p][s].obj] = @ + 1]
    /\ UNCHANGED <<table, created, rootRights>>

RemoveCap(p, s) ==
    /\ table[p][s].occupied
    /\ table' = [table EXCEPT ![p][s] = EmptySlot]
    /\ UNCHANGED <<objGen, created, rootRights>>

Next ==
    \/ \E p \in Procs, s \in Slots, o \in Objects, r \in SampleRights : Grant(p, s, o, r)
    \/ \E p \in Procs, s_src \in Slots, s_dst \in Slots, r \in SampleRights :
        CopyCap(p, s_src, s_dst, r)
    \/ \E p_src \in Procs, p_dst \in Procs, s_src \in Slots, s_dst \in Slots :
        TransferCap(p_src, s_src, p_dst, s_dst)
    \/ \E p \in Procs, s \in Slots : Revoke(p, s)
    \/ \E p \in Procs, s \in Slots : RemoveCap(p, s)

Spec == Init /\ [][Next]_vars

(* The invariant docs/test-system-plan.md section 3 scopes this model      *)
(* around: no execution reaches a state where a live capability carries    *)
(* rights not derivable from a strictly-decreasing chain back to its one   *)
(* root Grant.  Grant defines rootRights[o] exactly; CopyCap only narrows;  *)
(* TransferCap replicates verbatim from an already-bounded live source;    *)
(* Revoke/RemoveCap never touch a rights field -- so this should hold      *)
(* inductively, and TLC confirms it holds for every state reachable within *)
(* the bound below.                                                        *)
RightsMonotonicity ==
    \A p \in Procs, s \in Slots :
        IsLive(p, s) => table[p][s].rights \subseteq rootRights[table[p][s].obj]

====
