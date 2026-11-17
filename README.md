# nim-entrypoints

A Nim library with an extensible protocol for entry points into a program's
main module. The program writes its ordinary entry in a `main:` block, and
libraries register alternative entries: running the program's tests,
describing the program (shell completion, help as JSON, its configuration
schema), fuzz targets and others. An entry is selected at compile time, for
a binary built for that entry, or at run time through a hidden parameter, and
a binary can list the entries it carries.

```nim
import entrypoints

main:
  # parse the command line and run the program
```

The library has not been published here yet. This commit creates the `dev`
branch so the repository can be cloned and developed side by side with its
consumers.
