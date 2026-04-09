# Architecture Decision Records

## 001 — Stack-based bytecode, not register-based

Register-based VMs reduce push/pop overhead for expression-heavy
code. PEG operations (choice/commit/fail) are inherently stack-shaped though:
backtracking frames are pushed and popped dynamically based on input and grammar
depth. Named captures are write-once, read-once, so there is no expression tree
benefiting from register encoding. Not worth the compiler complexity.
