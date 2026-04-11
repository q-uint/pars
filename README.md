# pars

A parsing virtual machine inspired by *Crafting Interpreters* Part II. Where Lox uses arithmetic and OOP as its vehicle for exploring VM implementation, pars uses PEG grammar rules, pattern matching, and structured captures. Every concept the book introduces maps onto something a parser author would naturally want to express.

## Status

The compiler currently accepts expressions built from these primaries:

- `"literal"` — match an exact byte sequence
- `"""literal"""` — triple-quoted literal that allows embedded newlines
- `i"literal"` — case-insensitive literal (ASCII letters only)
- `'c'` — match a single byte
- `.` — match any one byte
- `(A B C)` — grouping; juxtaposition is sequence

Ordered choice (`/`), quantifiers (`*` `+` `?`), lookaheads (`!` `&`), rule definitions, captures, and grammar modules are not wired up yet.

## Building

Requires [Nix](https://nixos.org/) with flakes enabled.

```
nix develop --command zig build
nix develop --command zig build run
nix develop --command zig build test
```

## REPL

`pars` with no arguments starts an interactive session. The REPL keeps a *sticky input buffer*: you set it once with `:input`, then every subsequent expression is compiled and matched against that buffer.

```
$ pars
pars REPL. type :help for commands.
> :input GET /foo HTTP/1.1
input set (17 bytes)
> "GET"
ok: matched 3/17 bytes
> "GET" " " "/"
ok: matched 5/17 bytes
> "POST"
no match at byte 0/17
> :exit
```

Meta commands:

| command         | effect                                  |
| --------------- | --------------------------------------- |
| `:input <text>` | replace the sticky input buffer         |
| `:input`        | show the current input                  |
| `:clear`        | clear the sticky input                  |
| `:help`         | list commands                           |
| `:exit`/`:quit` | exit the REPL                           |

## Running a script

```
pars path/to/program.pars
```

The script is compiled and matched against an empty input. Exit codes: `0` on match, `1` on no match, `65` on compile error, `70` on runtime error.
