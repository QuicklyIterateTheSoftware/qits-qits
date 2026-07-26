#!/usr/bin/env python3
"""Exhaustively extract JAX-RS operations (verb + full path) from java sources.

Validated against the monolith's own docs/openapi.yml. Needed because the extracted
submodules cannot emit a schema: their service modules carry no quarkus-maven-plugin, so
there is no augmentation to generate one from.
"""
import os, re, sys

VERBS = ("GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS")
ANN = re.compile(r'^\s*@(' + '|'.join(VERBS) + r')\s*$')
PATH_ANN = re.compile(r'@Path\s*\(\s*"([^"]*)"\s*\)')
CLASS_DECL = re.compile(r'^\s*(?:public\s+|final\s+|abstract\s+)*(?:class|interface)\s+(\w+)')
IS_ANN = re.compile(r'^\s*@\w')
IS_COMMENT = re.compile(r'^\s*(//|/\*|\*)')


def join(*parts):
    out = ""
    for p in parts:
        if not p:
            continue
        if not p.startswith("/"):
            p = "/" + p
        out += p.rstrip("/")
    return out or "/"


def scan(root, prefix):
    ops = []
    for dirpath, _, files in os.walk(root):
        if "/target/" in dirpath or "/src/test/" in dirpath:
            continue
        for fn in sorted(files):
            if not fn.endswith(".java"):
                continue
            src = open(os.path.join(dirpath, fn), encoding="utf-8", errors="replace").read()
            lines = src.split("\n")
            cls_path, cls_at = None, None
            for i, l in enumerate(lines):
                if CLASS_DECL.match(l):
                    cls_at = i
                    break
                m = PATH_ANN.search(l)
                if m:
                    cls_path = m.group(1)
            if cls_at is None:
                continue
            verb, mpath = None, None
            for l in lines[cls_at:]:
                if ANN.match(l):
                    verb, mpath = ANN.match(l).group(1), None
                    continue
                if verb is None:
                    continue
                mp = PATH_ANN.search(l)
                if mp:
                    mpath = mp.group(1)
                    continue
                # Skip any other annotations and comments between the verb and the signature.
                if IS_ANN.match(l) or IS_COMMENT.match(l) or not l.strip():
                    continue
                # First real line after the annotation block is the method declaration, whose
                # parameter list may span many lines — do not require '{' on this line.
                ops.append((verb, join(prefix, cls_path, mpath), fn[:-5]))
                verb, mpath = None, None
    return sorted(set(ops), key=lambda t: (t[1], t[0]))


if __name__ == "__main__":
    prefix = sys.argv[1]
    for root in sys.argv[2:]:
        for verb, path, cls in scan(root, prefix):
            print(f"{verb}\t{path}\t{cls}")
