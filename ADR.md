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
