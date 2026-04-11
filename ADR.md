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
peephole view of the source, so we accept three compromises up front and plan
to retrofit a real analysis phase later.

1. _Forward rule references._ Grammars routinely call rules before defining
   them. We resolve rule names at runtime via the rule registry. Costs one
   hash lookup per call; buys us order-independent rule definitions.

2. _Left recursion._ `rule expr = expr "+" term / term` will infinite-loop at
   runtime. Detecting it requires building a call graph and asking which
   rules can reach themselves via a first-position call without consuming
   input — a whole-grammar analysis. For now, left recursion is a runtime
   failure caught by a stack-depth guard. Not good, but tractable.

3. _Memoization policy._ Memoizing every rule gives linear-time parsing but
   wastes memory; memoizing nothing is fast and small but degrades on
   pathological inputs. The optimal choice needs call-graph analysis. For
   now, we memoize every top-level `rule` and inline every `let` binding.
   Suboptimal but simple.

The crossover point is when call frames and grammar modules land. By then
the cost of these three compromises will have grown enough that adding a
pre-pass over the parsed AST will feel cheaper than keeping the workarounds.
At that point we retrofit left-recursion detection, smart memoization, and
any other whole-grammar optimizations onto a real analysis phase. Until
then, document each compromise at the site where it bites.

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

If semantic-action values grow complex enough to justify a second stack, we
revisit and move toward the side-channel model. Until then, one stack for
backtrack frames is enough.
