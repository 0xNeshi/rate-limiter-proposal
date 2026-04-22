<aside>
⚠️

Keep this short and verifiable. Each section maps to a pipeline artifact — don't copy everything from the artifacts, extract only what’s needed for review.

**If it’s not clear from the integration surface + a minimal example, it’s not ready.**

</aside>

#### 1. Problem (short)

- What is being solved/improved?
    - 
- Who is the target user (regular user / protocol / developer)?
    - 

#### 2. Existing solutions

*Source: research artifact — Existing Sui Implementations + Gap Analysis*

- What already exists in Sui?
    - 
- What does it do well / poorly?
    - 
- Which constraints come from Sui’s model (ownership, shared objects, upgrades, etc.)?
    - 

#### 3. Integration surface

*Source: design artifact — Integration Patterns + Object Ownership Model*

- What does the integrator add on their end?
- What comes from the library?
- What objects/capabilities are required, and which entities hold them?
- How does the system get configured?
- Ownership boundaries
- Link to design artifact
    - 
- Consumer-side integration sketch (high level — types and flow, not full code)
    - 

#### 4. Minimal end-to-end examples (required)

Actual compiling code in a separate repo/module. **Add comments explaining flow**, not implementation. Anyone should understand the system by reading the example, not the spec.

- Link to example repo/module(s)
    - 
- Happy path example
    - 
- Failing case example
    - 

#### 5. Invariants summary

*Source: invariants artifact*

Link to the full invariants artifact — don’t duplicate it here.

- Link to invariants artifact
    - 
- Critical invariants (type-level, runtime, economic) — 3–5 max
    - 

#### 6. Why this is better (the delta)

*Source: design artifact — Design Decisions Log*

- Improvements over existing solutions
    - 
- Tradeoffs introduced
    - 
- What it does NOT solve
    - 

<aside>

If this is unclear → design is not ready.

</aside>

#### 7. Review readiness

- [ ]  Problem is written down
- [ ]  Research artifact exists and has a go/no-go recommendation
- [ ]  Design artifact exists with ownership model decision
- [ ]  Invariants artifact exists
- [ ]  Integration surface is clear (consumer sketch compiles conceptually)
- [ ]  Examples compile
- [ ]  Examples include happy + failing cases
- [ ]  Delta is explicit (why this is better, what it doesn’t solve)
- [ ]  Open questions listed

#### Open questions / follow-ups

-
