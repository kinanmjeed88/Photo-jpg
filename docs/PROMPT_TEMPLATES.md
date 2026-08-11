# Standard Prompt Architecture for Jules (AI Agent)

This document defines the strict prompt engineering template that must be used for all tasks assigned to Jules in this project. The goal is to prevent regressions, hallucinations, and architectural drift.

## The Golden Rule (Agent Authority)
Jules has full decision authority. Jules MUST deeply analyze the project to determine the exact root cause and compare if the prompt fits the solution perfectly. 
* If it is a 100% match: Jules may proceed.
* If it is a 99% match or less: Jules MUST HALT immediately, write no code, and ask us for directions based on the analytical findings.

---

## 📋 The Universal Prompt Template

*Copy and paste the block below for every new task, filling in the bracketed information.*

```text
Role: Senior Flutter Architect & Autonomous Agent.

Context: 
[Describe the screen, the feature, or the bug clearly]

Target: 
[Describe what needs to be achieved in 1-2 sentences]

=======================================================================
DIRECTIVE 0: MANDATORY ANALYSIS & DECISION AUTHORITY
=======================================================================
Before modifying ANY code, strictly analyze the project to determine the exact root cause or implementation path. You have full decision authority to compare if this prompt fits the problem exactly.

PROCEED ONLY IF a 100% match is confirmed:
  ✓ You have located the exact files and lines of code.
  ✓ The proposed solution perfectly addresses the requirement without breaking existing logic or architecture.

If it is a 99% match or less (or you are guessing): HALT IMMEDIATELY. Do not write or patch any code. Ask us for directions based on your exact analytical findings.

=======================================================================
SCOPE LOCK
=======================================================================
Modify ONLY files directly related to this specific task. Do NOT refactor unrelated code, even if you consider it suboptimal.

=======================================================================
ACCEPTANCE CRITERIA
=======================================================================
1. [Criterion 1 - e.g., Visual change expected]
2. [Criterion 2 - e.g., Hitbox/Touch behavior]
3. [Criterion 3 - e.g., State management requirement]

=======================================================================
EXECUTION & VERIFICATION PROTOCOL
=======================================================================
1. Execute Directive 0 strictly.
2. If safe (100% match), implement the changes based on the Acceptance Criteria.
3. Run `flutter analyze` to ensure no syntax errors.
4. Commit atomically with a descriptive message.

Execute Directive 0 now.

📚 Reference Example: Resize Handle Fix
For a real-world application of this template, see commit:
fix: enlarge resize handle visual and hitbox
(This commit demonstrates how Directive 0 and the expanded hitboxes were successfully applied without breaking the existing scale/pan math).
⚠️ Common Pitfalls to Avoid
 * Never allow Jules to proceed with less than 100% confidence.
 * Always demand a "Findings Report" before code changes for complex bugs (e.g., adding a Directive 0.5 to check for Gesture Conflicts or Z-Index issues).
 * Never skip the SCOPE LOCK section, even for "small" fixes.
