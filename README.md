# eslint-lang-server

A lightweight LSP server that delegates linting to `eslint_d` (or `eslint`).

## Prerequisites

```sh
yay -S eslint_d
yay -S zig

zig build
# Make sure to adjust your $PATH if needed
cp zig-out/bin/eslint-lang-server ~/.local/bin/eslint-lang-server
```

## Helix integration

```toml
[[language]]
name = "typescript"
language-servers = [ "typescript-language-server", "eslint-lang-server" ]

[language-server.eslint-lang-server]
command = "eslint-lang-server"
```
