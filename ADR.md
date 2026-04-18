# Architecture Decision Records

Each record is tagged with its kind:

- **Rationale** — explains why the current default is the default, usually by
  ruling out the obvious alternative.
- **Decision** — a choice made between multiple viable options.
- **Guideline** — a policy to keep in mind when adding future features.

## 001 — Stack-based bytecode, not register-based

_Rationale._

Register-based VMs reduce push/pop overhead for expression-heavy
code. PEG operations (choice/commit/fail) are inherently stack-shaped though:
backtracking frames are pushed and popped dynamically based on input and grammar
depth. Named captures are write-once, read-once, so there is no expression tree
benefiting from register encoding. Not worth the compiler complexity.

## 002 — String interpolation is a user-defined grammar rule, not a scanner feature

_Decision._

Most languages bake string interpolation into the lexer. Python f-strings
(`f"hello {name}"`) and JavaScript template literals (`` `hello ${name}` ``)
are the most familiar examples: both lexers track a stack of quote-and-brace
contexts so they can tell when a `}` ends an interpolation versus when it is a
brace inside the interpolated expression itself. A few languages dodge the
ambiguity by choosing a delimiter that cannot collide with block scope at all,
but either way the interpolation syntax is hard-coded into the language. pars
is a language whose subject matter is parsing, so interpolation belongs in
user-space: authors write their own rule like

```
rule interp = '"' (chunk / "${" expression "}")* '"'
```

and get whatever delimiters, escape rules, and nesting semantics they want.
The scanner stays dumb and keeps `string` as a single opaque token. The cost
is that every grammar author reinvents the wheel for interpolated strings;
the benefit is that pars does not impose a canonical form on a feature whose
spelling varies wildly across host languages.

## 003 — New keyword-shaped operators are contextual, scanned as identifiers, promoted in the parser

_Guideline._

Adding a reserved word in a later release breaks every existing grammar that
happens to use it as a rule name. Since pars grammars are user data whose
identifiers are chosen for domain clarity (`label`, `trace`, `memo`, `cut`),
the cost of claiming a word globally is high. New keyword-shaped operators are
therefore contextual: the scanner emits them as plain `identifier` tokens, and
the parser promotes a specific lexeme into the operator role only in the
grammar positions where the operator is meaningful. Rule names, let bindings,
and action field keys keep working unchanged. The cost is that the parser has
to do lexeme comparisons at every contextual site; the benefit is that adding
operators is non-breaking and that the scanner stays a pure function of its
input, which preserves the on-demand pull model.

## 004 — Start single-pass, add a whole-grammar pre-pass once rule calls and grammar modules land

_Guideline._

The compiler is single-pass: the Pratt parser walks the source once and emits
bytecode as it goes. Some PEG-specific concerns cannot be answered with a
peephole view of the source, so I accept three compromises up front and plan
to retrofit a real analysis phase later.

1. _Forward rule references._ Grammars routinely call rules before defining
   them. Rule names resolve at runtime via the rule registry. Costs one
   hash lookup per call; buys order-independent rule definitions.

2. _Left recursion._ `rule expr = expr "+" term / term` will infinite-loop
   without intervention. Detecting it statically requires building a call
   graph and asking which rules can reach themselves via a first-position
   call without consuming input — a whole-grammar analysis. The VM detects
   it at runtime instead: each call frame records the input position at
   entry, and `callRule` scans the frame stack for a duplicate
   (same rule, same position). When found, the VM reports
   `Left recursion detected in rule 'expr'.` and halts. Correct but
   linear in call-stack depth per rule call.

3. _Memoization policy._ Memoizing every rule gives linear-time parsing but
   wastes memory; memoizing nothing is fast and small but degrades on
   pathological inputs. The optimal choice needs call-graph analysis.
   There is no memoization yet. Adding it is planned once the cost on
   real grammars justifies the complexity.

The crossover point is when grammar modules land. By then the cost of
these compromises will have grown enough that adding a pre-pass over the
parsed AST will feel cheaper than keeping the workarounds. The pre-pass
then retrofits static left-recursion detection, smart memoization, and any
other whole-grammar optimizations onto a real analysis phase. Until then,
document each compromise at the site where it bites.

## 005 — Sequence is an invisible infix operator in the Pratt table

_Decision._

In pars, juxtaposing two sub-patterns means "match the first, then match the
second": `"GET" " " "/" "HTTP/1.1"` is four primaries combined by three
sequence operators. There is no token between them. Every other PEG notation
spells sequence this way because grammars are read more often than they are
typed, and the invisible form is the more readable one.

This complicates the Pratt parser. The usual loop asks "is the current token
an infix operator at or above my precedence level?": a table lookup keyed on
token type. Sequence has no token, so it cannot appear in the table as a row.
Instead, the main loop in `parsePrecedence` checks both conditions in order:

1. Does the current token have an infix rule? If so, advance and dispatch as
   usual.
2. Otherwise, does the current token start a primary expression (literal,
   identifier, `(`, `[`, `.`, `^`, `i"`, `!`, `&`)? If so, treat it as a
   sequence continuation: recursively compile the next primary at one level
   tighter than sequence, without consuming any token first. No opcode is
   emitted: sequence is invisible in the bytecode as well, since one
   sub-pattern's code simply runs after the previous one's.

Sequence is left-associative so the right operand parses at
`quantifier`-or-tighter, not at `sequence`.

## 006 — A successful match leaves nothing on the value stack

_Decision._

The runtime model has to answer what a primary like `"GET"` produces when it
matches. Three options were considered:

- _Implicit success._ A matching primary leaves nothing on the stack.
  Failure unwinds to a saved backtrack frame. Captures are a separate
  mechanism.
- _Span per match._ Every successful primary pushes a `Span{start, length}`.
  Sequence merges two spans. The stack holds values as in a conventional VM.
- _Side channel._ Matches write to a capture buffer; the value stack is
  reserved for semantic-action values. Two parallel stacks.

I choose implicit success. Rules that only check whether input matches pay
zero runtime cost per primary, which is the common case for lexing and
protocol framing. The stack holds backtrack frames during a parse and is
empty on success. Sequence emits no opcode because one sub-pattern's code
naturally follows the previous. Lookaheads and quantifiers can be built on
top without touching a separate value dimension.

The cost is that any feature that wants a match _result_ - captures,
semantic actions, the top-level print in the REPL — has to fetch it from
somewhere other than the value stack. Captures will live on a dedicated
capture buffer when let-bindings land, and the REPL will print the matched
span range recovered from the VM's input cursor positions rather than
popping a value.

If semantic-action values grow complex enough to justify a second stack,
revisit and move toward the side-channel model. Until then, one stack for
backtrack frames is enough.

## 007 -- Strings are raw byte sequences, not Unicode-aware

_Decision._

The VM operates on bytes, not characters or code points. `ObjLiteral`
stores a raw byte sequence and matches byte-for-byte against the input.
`ObjCharset` is a 256-bit bitvector indexed by byte value. `Span`
records byte offsets into the input. None of these types encode or
decode Unicode.

Three approaches were considered:

- _Byte-level._ The VM treats input as a flat byte stream. Grammar
  authors who want to parse UTF-8 write rules that match the byte
  patterns (a `utf8_char` rule matching 1-4 byte sequences, for
  example).
- _Code-point-aware._ The VM decodes UTF-8 internally, charsets
  operate on code points, and spans are code-point-indexed. Correct
  for Unicode text but imposes an encoding assumption on all inputs,
  including binary protocols.
- _Maximal._ Support multiple encodings, expose both code-point and
  grapheme-cluster APIs. Comprehensive but far too complex for an
  embedded parsing VM.

I choose byte-level. pars is a tool for describing the structure of
input, and input is not always text. Binary protocols, wire formats,
and mixed-encoding streams are legitimate targets. Assuming UTF-8
would make these harder to express while adding decode overhead to
every match operation. Grammar authors who parse UTF-8 text can
express the encoding rules in the grammar itself, keeping the VM
simple and the charset bitvector a single array lookup.

The cost is that the language provides no built-in Unicode character
classes or code-point-level operations. Users who want `\p{Letter}`
style classes must build them from byte-level rules or a future
standard library. If enough grammars need Unicode support, a standard
`utf8` grammar module is the right place for it, not the VM.

## 008 — Cuts commit the innermost choice, with optional failure labels

_Decision._

A *cut* (`^`) marks a point in a grammar past which backtracking to the
enclosing ordered choice is no longer allowed. The scanner already emits a
`caret` token and recognizes the optional string-label form (`^"expected ')'"`).
Three sub-decisions define the runtime semantics.

_Scope: per-choice, not per-rule._ A cut commits the innermost enclosing `/`,
not the whole rule body. The alternative — per-rule scope, where any cut
anywhere in a rule commits the entire rule — was rejected because it is
strictly less expressive. An author who wants rule-wide scope under per-choice
semantics lifts the cut to the outermost `/` of the rule; under per-rule
semantics there is no way to go finer. Per-choice also falls out of the
existing frame discipline: `op_choice` and `op_commit` already pair in LIFO
order, so the innermost choice frame on the backtrack stack is the one a cut
should target.

_Label form: both `^` and `^"..."` are valid._ The bare form is the commit
itself: drop the innermost choice frame, keep parsing, and if later matching
fails let the failure propagate outward like any other failure. The labelled
form adds a diagnostic contract: if matching fails anywhere between the cut
and the end of the committed region, the VM raises a runtime error whose
message is the label string, rather than silently propagating. The bare form
is the memory/performance knob (prunes backtrack frames that can never be
revisited, and later will prune the memo entries associated with them). The
labelled form is the diagnostic knob ("expected ')' after expression" instead
of a generic "no alternative matched"). One syntax, one opcode with an
optional constant-index operand.

_Lookaheads: cuts inside `!(...)` or `&(...)` are a compile error._ Lookaheads
promise that the enclosed pattern has no effect on the caller's backtracking
state — checking without committing is their whole reason to exist. A cut
inside a lookahead leaks a commit out of a scope that is supposed to be
transparent. Forbidding this at compile time avoids a class of subtle bugs
where a lookahead unexpectedly prunes outer alternatives. Cuts inside
quantifiers (`*`, `+`, `?`) are allowed: a cut within an iteration body binds
to whichever `/` is lexically innermost at that point, and the quantifier's
own backtrack frame is skipped over because it is tagged as a quantifier
frame, not a choice frame.

The runtime cost is that backtrack frames gain a kind tag (choice, quantifier,
lookahead) so `op_cut` can walk past non-choice frames to find its target,
and the compiler needs a lookahead-nesting counter to reject cuts at the
wrong lexical depth. The benefit is a cut semantics that is local,
composable, and implementable without whole-grammar analysis — consistent
with ADR 004's single-pass stance. Revisit if experience shows that
per-choice scope is too fine-grained for common diagnostics, or that
labelled cuts want to carry more structured information than a single string.

## 009 — Bounded repetition desugars to existing quantifier opcodes

_Decision._

A *bounded quantifier* spells `A{n}`, `A{n,m}`, `A{n,}`, or `A{,m}`: match
`A` exactly `n` times, between `n` and `m` times, at least `n` times, or at
most `m` times respectively. The notation is the regex spelling, chosen
because it is immediately familiar and because the alternatives each
collided with tokens already in use: `^n` would clash with cut (ADR 008),
`|n..m|` with the alternate choice spelling, `<n,m>` with capture
delimiters.

_Desugaring instead of new opcodes._ Two implementation shapes were on the
table:

- _Dedicated bytecode._ A new `op_quant_range` that pushes a counter frame
  and inspects `(min, max)` each iteration. One opcode, emitted code size
  independent of `max`.
- _Compile-time duplication._ Re-use `op_choice_quant` / `op_commit`. Emit
  `n` verbatim copies of the operand followed by either `(max - n)` copies
  wrapped as `A?` or, for the unbounded form, an `A*` tail. No new opcode;
  the operand's bytecode is duplicated the same way `plusOp` already does.

Duplication wins. The VM stays unchanged, the existing frame-kind tagging
(ADR 008) already gives bounded repetition the right cut semantics — a cut
inside an iteration walks past the duplicated quantifier frames just as it
does for `*` and `+` — and the emitted bytecode reads the same as the
hand-written composition `A A A A? A?` would. The cost is that bytecode
size grows as `operand_len × max`. Mitigated by two caps: operand size
≤ 256 bytes (matches `plusOp`'s existing limit) and count ≤ 255. Authors
wanting more write the composition out by hand or use `+` / `*`.

_Braces do not conflict with the planned action syntax._ Semantic action
bodies will attach via `=> { ... }` (see the prelude in `lib/pars.pars`).
The `=>` token is the prelude, so a `{` that opens an action body only
appears after `=>` has been consumed. In expression position, a bare `{`
immediately after a primary always means bounded repetition. This ADR
fixes that arrangement: any future action syntax must remain `=>`-gated so
the bounded-quantifier infix stays unambiguous.

_Error cases are compile errors, not runtime ones._ Empty braces (`A{}`),
lone commas (`A{,}`), zero upper bounds (`A{0}`), inverted bounds
(`A{5,2}`), counts exceeding 255, and operands exceeding 256 bytes are all
rejected at compile time with a diagnostic. The checks run in `boundedOp`
and use the same error-reporting machinery as the rest of the compiler,
so diagnostics land at the right source location without special handling.
