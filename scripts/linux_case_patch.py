"""Linux case-sensitivity patch for the bot scripts.

Lowercases every file/dir name under the given folder and the quoted module
paths in require/dofile/LinkLuaModifier calls, so Lua lookups match on a
case-sensitive filesystem. Same logic as bots/Install-to-vscript/quick-install-oha-linux.sh
(based on github.com/ashoktamang/dota2bot-OpenHyperAI-linux-patcher).
"""
import os
import re
import sys

root = sys.argv[1]

for dirpath, dirnames, filenames in os.walk(root, topdown=False):
    for name in filenames + dirnames:
        lower = name.lower()
        if name != lower:
            dst = os.path.join(dirpath, lower)
            if not os.path.exists(dst):
                os.rename(os.path.join(dirpath, name), dst)

keywords = re.compile(r"\b(require|dofile|LinkLuaModifier)\b")
path_dirs = {"bots", "botslib", "funclib", "funlib", "fretbots", "customize", "buff"}


def lower_paths(line):
    if not keywords.search(line):
        return line

    def lower_match(m):
        s = m.group(0)
        q, inner = s[0], s[1:-1]
        if "/" in inner or "\\" in inner or "." in inner:
            return q + inner.lower() + q
        if any(p in path_dirs for p in inner.lower().split(".")):
            return q + inner.lower() + q
        return s

    return re.sub(r"""(['"])[^'"]+\1""", lower_match, line)


for dirpath, _, filenames in os.walk(root):
    for fname in filenames:
        if not fname.endswith(".lua"):
            continue
        fpath = os.path.join(dirpath, fname)
        with open(fpath, encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
        new_lines = [lower_paths(l) for l in lines]
        if new_lines != lines:
            with open(fpath, "w", encoding="utf-8") as f:
                f.writelines(new_lines)
