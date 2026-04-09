# pars

A parsing virtual machine inspired by *Crafting Interpreters* Part II. Where Lox uses arithmetic and OOP as its vehicle for exploring VM implementation, pars uses PEG grammar rules, pattern matching, and structured captures. Every concept the book introduces maps onto something a parser author would naturally want to express.

## Building

Requires [Nix](https://nixos.org/) with flakes enabled.

```
nix develop --command zig build
nix develop --command zig build run
nix develop --command zig build test
```
