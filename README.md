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
rule alpha = ['a'-'z' 'A'-'Z']
rule digit = ['0'-'9']
rule ident = (alpha / '_') (alpha / digit / '_')*
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

### Operators (loosest to tightest)

| operator | meaning                          |
| -------- | -------------------------------- |
| `A / B`  | ordered choice: try A, else B    |
| `A B`    | sequence (juxtaposition)         |
| `A*`     | zero or more                     |
| `A+`     | one or more                      |
| `A?`     | optional                         |

`|` is a synonym for `/`.

### Rules

```
rule name = body
```

Rules can reference each other in any order. The last rule in the file
is matched against the input.

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
> rule method = ['A'-'Z']+
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
