# eslint-lang-server

A LSP that makes calls to `eslint_d`.

## Prerequisites

```sh
yay -S eslint_d
```

## Install

```sh
yay -S gcc json-c
make
mkdir -p ~/.local/bin
cp bin/eslint-lang-server ~/.local/bin/
# Make sure to adjust your $PATH if needed
```

## Helix integration

```toml
[[language]]
name = "typescript"
language-servers = [ "typescript-language-server", "eslint-lang-server" ]

[language-server.eslint-lang-server]
command = "eslint-lang-server"
```
