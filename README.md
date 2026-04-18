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

| syntax          | meaning                                      |
| --------------- | -------------------------------------------- |
| `"literal"`     | match an exact byte sequence                 |
| `"""literal"""` | triple-quoted, allows embedded newlines      |
| `i"literal"`    | case-insensitive (ASCII letters)             |
| `'c'`           | match a single byte                          |
| `.`             | match any one byte                           |
| `['a'-'z']`     | charset: match one byte in the set           |
| `(A B)`         | grouping                                     |
| `name`          | call a named rule                            |
| `<x: A>`        | capture the span matched by `A` as `x`       |

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

## Building

Requires [Nix](https://nixos.org/) with flakes enabled.

```
nix develop --command zig build
nix develop --command zig build test
```
