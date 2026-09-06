receipt: 2026-09-06T02:46:41Z
name: validation29-readme-fix-cmp
cmd: bash -c gh gist view 56f907f2fc152a9c467df7f55df8f49e -f README.md | cmp - README.md && echo "README.md BYTE-EQUAL after Cyrillic-e fix (Pasted-evidence ASCII now)"
--- output ---
README.md BYTE-EQUAL after Cyrillic-e fix (Pasted-evidence ASCII now)
--- exit: 0 ---
