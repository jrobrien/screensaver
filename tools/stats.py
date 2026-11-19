"""Code size per implementation, as a markdown table.

Lines are split into code, comment and blank with simple per-language rules
(line comments, C block comments, Python docstrings). Tests are counted
separately: separate test trees, *_test files, and Zig's inline `test` blocks.
"""
import re

from impls import IMPLS, TEST_DIRS


def classify(lines, lang):
    code = comment = blank = 0
    in_block = False
    for raw in lines:
        s = raw.strip()
        if not s:
            blank += 1
        elif in_block:
            comment += 1
            if ('"""' in s) if lang == 'python' else ('*/' in s):
                in_block = False
        elif lang == 'python' and s.startswith('"""'):
            comment += 1
            in_block = s.count('"""') == 1
        elif lang == 'python' and s.startswith('#'):
            comment += 1
        elif lang != 'python' and s.startswith('//'):
            comment += 1
        elif lang in ('c', 'odin') and s.startswith('/*'):
            comment += 1
            in_block = '*/' not in s
        else:
            code += 1
    return code, comment, blank


def zig_split(text):
    """Zig keeps tests in the source files: move `test "..." { ... }` blocks out."""
    src, tests, depth = [], [], 0
    for line in text.splitlines():
        if depth == 0 and re.match(r'\s*test\s+("|\w|\{)', line):
            depth = line.count('{') - line.count('}')
            tests.append(line)
            continue
        if depth > 0:
            depth += line.count('{') - line.count('}')
            tests.append(line)
            continue
        src.append(line)
    return src, tests


def main():
    print('| impl | files | code | comments | blank | test code |')
    print('|---|---:|---:|---:|---:|---:|')
    for name, (_, src_dir, exts, is_test) in IMPLS.items():
        src, tests, nfiles = [], [], 0
        for p in sorted(src_dir.rglob('*')):
            if p.suffix not in exts or '.zig-cache' in p.parts:
                continue
            text = p.read_text()
            if is_test and is_test(p):
                tests += text.splitlines()
                continue
            nfiles += 1
            if name == 'zig':
                s, t = zig_split(text)
                src += s
                tests += t
            else:
                src += text.splitlines()
        tdir = TEST_DIRS.get(name)
        if tdir:
            for p in sorted(tdir.rglob('*')):
                if p.suffix in exts:
                    tests += p.read_text().splitlines()
        code, comment, blank = classify(src, name)
        tcode = classify(tests, name)[0]
        print(f'| {name} | {nfiles} | {code} | {comment} | {blank} | {tcode} |')


if __name__ == '__main__':
    main()
