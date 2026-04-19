<img src="assets/logo.svg" width="64" height="64" align="right" alt="" />

# pars

A bytecode virtual machine for PEG grammars. Grammars compile to a
compact instruction set and execute against arbitrary byte input.

## Quick start

```
echo -n "192.168.1.1" | pars examples/ipv4.pars
```

Exit code 0 means the input matched; 1 means it did not.

## Example

```
-- examples/identifier.pars
use "std/abnf";

ident = (ALPHA / '_') (ALPHA / DIGIT / '_')*;
```

```
$ echo -n "foo_123" | pars examples/identifier.pars && echo matched
matched
```

More examples in [`examples/`](examples/).

## Language

A pars program is a sequence of rule declarations. The last rule is the
entry point.

### Primaries

| syntax                 | meaning                                            |
| ---------------------- | -------------------------------------------------- |
| `"literal"`            | match an exact byte sequence                       |
| `"""literal"""`        | triple-quoted, allows embedded newlines            |
| `i"literal"`           | case-insensitive (ASCII letters)                   |
| `'c'`                  | match a single byte                                |
| `.`                    | match any one byte                                 |
| `['a'-'z']`            | charset: match one byte in the set                 |
| `(A B)`                | grouping                                           |
| `#[longest](A / B)`    | longest-match choice: commit to the longest arm    |
| `name`                 | call a named rule                                  |
| `<x: A>`               | capture the span matched by `A` as `x`             |

Within the same rule, referencing a captured name matches the exact
bytes it captured earlier (back-reference).

### Operators (loosest to tightest)

| operator  | meaning                                              |
| --------- | ---------------------------------------------------- |
| `A / B`   | ordered choice: try A, else B (`\|` is a synonym)    |
| `A B`     | sequence (juxtaposition)                             |
| `!A`      | negative lookahead: succeeds when A fails            |
| `&A`      | positive lookahead: succeeds without consuming       |
| `A*`      | zero or more                                         |
| `A+`      | one or more                                          |
| `A?`      | optional                                             |
| `A{n}`    | exactly `n` times                                    |
| `A{n,m}`  | between `n` and `m` times                            |
| `A{n,}`   | at least `n` times                                   |
| `A{,m}`   | at most `m` times                                    |
| `^`       | cut: commit the innermost `/`; `^"msg"` adds a label |

### Rules

```
name = body;
```

Rules can reference each other in any order. The last rule in the file
is matched against the input.

A rule body may introduce locally-scoped sub-rules with `where`:

```
kv = k "=" v
  where
    k = ident;
    v = ident
  end
```

A declaration may carry bracketed attributes. Today `lr` is the only
declaration attribute: it opts a rule into direct left recursion via
seed-growing, so `expr` below matches left-associative chains like
`1+2-3` that a plain PEG would reject:

```
#[lr]
expr = expr "+" term
     / expr "-" term
     / term;
```

See [`examples/left-recursive-expr.pars`](examples/left-recursive-expr.pars).

The `#[longest](...)` form reuses the same bracketed-attribute syntax
in expression position. It runs every alternative from the same
starting position and commits to the one that consumed the most input,
so a shorter prefix cannot starve a longer one:

```
op = #[longest]("<" / "<=" / ">" / ">=" / "==" / "!=");
```

Ties resolve to the earlier arm; if every arm fails, the group fails.
See [`examples/longest-match.pars`](examples/longest-match.pars).

Attribute names are not reserved words: `lr` and `longest` are only
recognized inside `#[...]`, so rules or bindings named `lr` or
`longest` keep working unchanged.

### Imports

```
use "std/abnf";
```

Makes the rules from a standard library module (currently `std/abnf`
and `std/pars`) available in the current grammar.

## Usage

```
pars <grammar> [input-file]
```

With one argument, input is read from stdin. With two, the second
argument is an input file. Exit codes: 0 match, 1 no match, 65 compile
error, 70 runtime error.

## REPL

`pars` with no arguments starts an interactive session with a sticky
input buffer.

```
$ pars
pars REPL. type :help for commands.
> :input GET /foo HTTP/1.1
input set (17 bytes)
> "GET"
ok: matched 3/17 bytes
> method = ['A'-'Z']+;
ok: matched 3/17 bytes
> method " " "/" ['a'-'z']+
ok: matched 8/17 bytes
> :exit
```

Rules defined in the REPL persist across lines.

| command         | effect                          |
| --------------- | ------------------------------- |
| `:input <text>` | set the sticky input buffer     |
| `:input`        | show the current input          |
| `:clear`        | clear the input                 |
| `:help`         | list commands                   |
| `:exit`/`:quit` | exit                            |

## Editor support

A VSCode extension lives in [`editors/vsx/`](editors/vsx/). It bundles
the `pars-lsp` language server, which talks JSON-RPC over stdio and
provides:

- syntax-aware diagnostics (scanner and compiler errors)
- semantic token highlighting
- **go-to-definition** on rule references and capture back-references
- **hover** showing a rule's body (or a note for captures)
- **document outline** of top-level rules
- **inlay hints** flagging identifiers that resolve to capture
  back-references rather than rule calls
- snippets for common declarations (`rule`, `rulew`, `where`, `cap`,
  `alt`, `longest`, `neg`, `pos`, `cut`, `bq`, `use`, `cs`)

### Install

```
./editors/vsx/install.sh
```

Builds `pars-lsp` in ReleaseSafe, bundles it into the extension, packs
a `.vsix`, and installs it into VSCode via the `code` CLI. Pass
`--no-install` to build only, or `--no-build` to reuse an existing
`zig-out/bin/pars-lsp`.

To use a custom server path instead of the bundled one, set
`pars.serverPath` in VSCode settings.

## Building

Requires [Nix](https://nixos.org/) with flakes enabled.

```
nix develop --command zig build
nix develop --command zig build test
```
