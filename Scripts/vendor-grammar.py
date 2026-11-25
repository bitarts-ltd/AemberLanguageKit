#!/usr/bin/env python3
"""Copies a tree-sitter grammar into a pack, and sets up the pack's folder.

A pack compiles its grammar in, so the grammar's C sources are copied
into Packs/<Name>/Grammar as they are upstream, with the LICENSE and a
SOURCE file naming the repository and commit. This also writes what
the pack's Swift needs to see the grammar (Grammar/include/<header>.h
and <Name>Pack-Bridging-Header.h), and copies the upstream highlights
query into Queries/ unless the pack has one. Run it again with a newer
checkout to update the grammar.

Usage:
  vendor-grammar.py NAME CHECKOUT SYMBOL... [--subdir DIR ...]
      [--into DIR] [--extra DIR ...] [--queries DIR]

  NAME      the pack's folder in Packs/ (Rust), or the path of a pack
            folder elsewhere (../ZigPack), named for its Info.plist's
            AemberPackName (else the folder), whose generated headers
            then carry no BitArts copyright
  CHECKOUT  a clone of the grammar's repository
  SYMBOL    the grammar's function (tree_sitter_rust), one per --subdir
            when there are several
  --subdir  the grammar's folder in the repository, for repositories
            holding several (php_only; typescript and tsx)
  --into    a folder in Grammar/ for this repository's grammar, its
            LICENSE and SOURCE, for a pack with grammars from several
            repositories (javascript)
  --extra   more folders to copy beside it, that its scanner includes
            (common)
  --queries where the queries are, relative to the checkout (queries)

Nothing in the checkout is run; only files are copied.
"""

import argparse
import os
import plistlib
import shutil
import subprocess
import sys

HEADER = """/**
    @file {header}.h
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief The {name} grammar's entry point, for the pack's Swift code.
*/

#ifndef {guard}
#define {guard}

typedef struct TSLanguage TSLanguage;

/// The {name} grammar
const TSLanguage *{symbol}(void);

#endif
"""

# The lines naming BitArts, left out of a pack outside this repository
BITARTS_LINES = """    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
"""

BRIDGING = """/**
    @file {name}Pack-Bridging-Header.h
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief What the {name} pack's Swift code sees of its C grammars.
*/

"""


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("name")
    parser.add_argument("checkout")
    parser.add_argument("symbols", nargs="+")
    parser.add_argument("--subdir", action="append", default=[])
    parser.add_argument("--into", default="")
    parser.add_argument("--extra", action="append", default=[])
    parser.add_argument("--queries", default="queries")
    args = parser.parse_args()

    global HEADER, BRIDGING
    if os.sep in args.name:
        # A pack outside this repository, named for its folder
        root = os.path.abspath(args.name)
        # Named as build-pack.sh names its module: the Info.plist's
        # AemberPackName as an identifier, else the folder's name
        args.name = os.path.basename(root.rstrip(os.sep))
        info = os.path.join(root, "Info.plist")
        if os.path.exists(info):
            with open(info, "rb") as handle:
                name = plistlib.load(handle).get("AemberPackName", "")
            name = "".join(c for c in name if c.isalnum() or c == "_")
            if name:
                args.name = name
        if args.name.endswith("Pack") and len(args.name) > 4:
            args.name = args.name[:-4]
        HEADER = HEADER.replace(BITARTS_LINES, "")
        BRIDGING = BRIDGING.replace(BITARTS_LINES, "")
    else:
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Packs", args.name)
    grammar = os.path.join(root, "Grammar")
    subdirs = args.subdir or [""]
    if len(args.symbols) != len(subdirs):
        print("give one SYMBOL per --subdir", file=sys.stderr)
        return 1
    home = os.path.join(grammar, args.into) if args.into else grammar
    copied = []
    for subdir in subdirs:
        source = os.path.join(args.checkout, subdir, "src")
        if not os.path.exists(os.path.join(source, "parser.c")):
            print(f"no src/parser.c in {os.path.join(args.checkout, subdir)}", file=sys.stderr)
            return 1
        target = os.path.join(home, subdir, "src")
        shutil.rmtree(target, ignore_errors=True)
        os.makedirs(os.path.join(target, "tree_sitter"))
        for file in ["parser.c", "scanner.c"]:
            if os.path.exists(os.path.join(source, file)):
                shutil.copy(os.path.join(source, file), target)
        for header in os.listdir(os.path.join(source, "tree_sitter")):
            shutil.copy(os.path.join(source, "tree_sitter", header), os.path.join(target, "tree_sitter"))
        copied.append(os.path.relpath(target, grammar))
    for extra in args.extra:
        shutil.rmtree(os.path.join(home, extra), ignore_errors=True)
        shutil.copytree(os.path.join(args.checkout, extra), os.path.join(home, extra))
        copied.append(os.path.relpath(os.path.join(home, extra), grammar))
    os.makedirs(home, exist_ok=True)
    shutil.copy(os.path.join(args.checkout, "LICENSE"), os.path.join(home, "LICENSE"))

    commit = subprocess.run(["git", "-C", args.checkout, "log", "-1", "--format=%H (%cs)"], capture_output=True, text=True).stdout.strip()
    remote = subprocess.run(["git", "-C", args.checkout, "remote", "get-url", "origin"], capture_output=True, text=True).stdout.strip()
    with open(os.path.join(home, "SOURCE"), "w") as handle:
        handle.write(f"{os.path.basename(remote).removesuffix('.git')}\n{remote}\ncommit {commit}\nSee LICENSE\n\n"
                     f"{', '.join(copied)} copied as they are by Scripts/vendor-grammar.py.\nRun it again with a newer checkout to update them.\n")

    os.makedirs(os.path.join(grammar, "include"), exist_ok=True)
    for symbol in args.symbols:
        with open(os.path.join(grammar, "include", symbol + ".h"), "w") as handle:
            handle.write(HEADER.format(header=symbol, name=args.name, symbol=symbol, guard=symbol.upper() + "_H"))
    headers = sorted(f for f in os.listdir(os.path.join(grammar, "include")) if f.endswith(".h"))
    with open(os.path.join(root, f"{args.name}Pack-Bridging-Header.h"), "w") as handle:
        handle.write(BRIDGING.format(name=args.name).rstrip("\n") + "\n" + "".join(f'#include "Grammar/include/{h}"\n' for h in headers))

    queries = os.path.join(root, "Queries")
    upstream = os.path.join(args.checkout, args.queries, "highlights.scm")
    destination = os.path.join(queries, args.into) if args.into else queries
    if not os.path.exists(os.path.join(destination, "highlights.scm")) and os.path.exists(upstream):
        os.makedirs(destination, exist_ok=True)
        shutil.copy(upstream, destination)
    for folder in ["Sources", "Tests/Fixtures"]:
        os.makedirs(os.path.join(root, folder), exist_ok=True)
    print(f"{args.name}: {', '.join(copied)} at {commit}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
