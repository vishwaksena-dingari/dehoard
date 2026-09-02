# GitHub topics for scree

GitHub allows 20. Mole has 65,804 stars and 19 topics, six of which are COMPETITOR PRODUCT NAMES
(cleanmymac, daisydisk, pearcleaner, sensei, istat, appcleaner). People searching "cleanmymac
alternative" land on Mole. That, not the word "Mole", is where the reach came from.

Two halves, deliberately:

## Contested — the same searches that already surface Mole
macos, cli, command-line, zsh, shell, cleaner, cleanup, disk-space, disk-usage, storage,
cleanmymac, daisydisk, pearcleaner, mole, developer-tools

## Uncontested — Mole has ZERO topics here, and it is the differentiator
ollama, llm, huggingface, local-llm, machine-learning, gguf, lm-studio

Nobody searching "ollama disk space" or "huggingface cache cleanup" finds a cleaner today. That is
the reason to exist, and the only topic space where being first matters more than being 65k stars
behind.

## Final 20 (paste into repo settings)
macos cli command-line zsh cleaner cleanup disk-space disk-usage storage
ollama llm huggingface local-llm machine-learning gguf lm-studio
cleanmymac daisydisk pearcleaner developer-tools

## Description (350 char limit)
Disk cleaner for macOS developers and ML engineers. One readable zsh script, previews by default,
never asks for sudo. Finds the same model downloaded into Ollama, LM Studio and HuggingFace at
once - usually the biggest thing on a machine that runs models locally.

## Rename steps on GitHub (after this branch merges)

1. Settings -> Repository name -> `scree`. Commit history, issues, stars and releases are all
   preserved; the name is only a label pointing at the same objects.
2. Settings -> Topics -> paste the 20 above. This is the actual reach lever, not the name.
3. Settings -> Description -> paste the description above.
4. Create a NEW empty repository named `dehoard`. GitHub auto-creates a redirect from an old name
   to a new one, and creating something at the old name is the only way to retire it - which is
   what you asked for. It also holds the name.
5. `git remote set-url origin https://github.com/vishwaksena-dingari/scree.git` locally.
6. Re-tag if you want the release names to match: the existing v0.2.x tags are unaffected by a
   repository rename and keep working.

Order matters: rename FIRST, then the install URLs in README/install.sh resolve. They already point
at /scree/ in this branch, so they 404 until step 1 is done.
