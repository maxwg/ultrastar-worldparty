# Visual Studio Code build workflow (legacy)

The repository includes legacy VS Code task and keybinding files. Free Pascal
and the project's development dependencies are required. The OmniPascal
extension is optional editor support; the checked-in compile tasks invoke the
repository's shell or batch build scripts.

On Debian/Ubuntu, the repository-root helper is `./install`, not `./install.sh`.
It runs `sudo apt-get`, then configure/build/install commands, and copies a
desktop file into `/usr/share/applications`. Review those system-wide effects
before running it. If you only need compiler dependencies, install the
appropriate development packages for your distribution separately.

Copy `dists/vscode/tasks.json` to `.vscode/tasks.json` in the repository root.
Merge `dists/vscode/keybindings_worldparty.json` into your [user
`keybindings.json`](https://code.visualstudio.com/docs/getstarted/keybindings),
keeping any existing bindings you need. The checked-in bindings map to these
tasks:

- F9: `Compile debug`.
- Ctrl+F9: `Compile`.
- F10: `Compile debug execute`.
- Ctrl+F10: `Compile execute`.
- F11: `Execute debug without compile`.
- Ctrl+F11: `Execute without compile`.

The task definitions call `dists/atom/linux/compile.sh` or
`dists/atom/windows/compile.bat`; this VS Code configuration is a front end to
those legacy wrappers, not a separate build implementation.
