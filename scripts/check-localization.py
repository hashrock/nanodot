#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""訳のカタログ（Resources/*.xcstrings）と Swift 側の文言のずれを見張る。

    scripts/check-localization.py          ずれていたら 1 で落ちる
    scripts/check-localization.py --quiet  問題があるときだけ出す

なぜ要るか。SwiftPM でビルドしているので、Xcode のように文言をカタログへ拾ってくれるものがない。
文言を足して訳を入れ忘れても、英語の画面に日本語が出るだけで誰も気づかない。ここで機械的に見る。
`scripts/build-app.sh`、`swift test`（LocalizationTests）、CI から走る。

見るもの:
  1. Swift の文字列リテラルのうち日本語を含むものは、訳が引かれる書き方になっているか。
     - `L("…")` / `LM("…")` の引数
     - SwiftUI の部品にじかに書いたもの（`Text("…")`、`.help("…")` など。LocalizedStringKey として引かれる）
     - 行末に `// l10n: LName`（保存する名前。表示のときに LName で引く）
     - 行末に `// l10n: 訳さない`（保存する値など、わざと訳さないもの）
     どれでもなければ落とす（三項演算子や変数を経由すると String になり、訳が引かれない）。
     MCP のツール定義（エージェント向け。訳さない）のファイルは、L / LM で包んだものだけ見る。
  2. その文言がカタログにあるか。LM は MCP の表、ほかは Localizable。
  3. どのキーにも英語の訳が付いていて、state が translated になっているか。
  4. 訳の書式指定子がキーと食い違っていないか（%@ の数や型の取り違え）。
  5. カタログにあるのに Swift 側で使われていないキー。
  6. その言語にない複数形の区分を書いていないか。
  7. Localizable に MCP の文言が混ざっていないか（App Store 用の .app には MCP の表を入れないため）。
"""

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.join(ROOT, 'Resources')
MAIN, MCP, INFO = 'Localizable', 'MCP', 'InfoPlist'
SOURCE_DIR = os.path.join(ROOT, 'Sources')
# エージェント向けの文（ツールの説明・結果）を持つファイル。訳さない
AGENT_FACING = {'NanodotMCP.swift', 'MCP.swift'}

# 補間も書式指定子も同じ印に潰して突き合わせる。`L("\(n) 個")` が `%lld 個` に
# なるのか `%@ 個` になるのかは呼ぶ側の型で決まり、ここからは見えないため。
HOLE = '\x00'
SPECIFIER = re.compile(r'%(?:\d+\$)?(?:#@\w+@|lld|[@dioux]|\.?\d*l?[fgeEs])')
INTERPOLATION = re.compile(r'(?<!\\)\\\((?:[^()]|\([^()]*\))*\)')
STRING_LITERAL = re.compile(r'"(?:[^"\\\n]|\\.)*"')
JAPANESE = re.compile(r'[\u3040-\u30ff\u3400-\u9fff]')
WRAPPED = re.compile(r'\b(L|LM)\(\s*$')
# 先頭の引数が LocalizedStringKey になる SwiftUI の部品
SWIFTUI = re.compile(r'(?:\b(?:Text|Button|Toggle|Picker|Label|LabeledContent|Menu|Stepper|TextField|Window|CommandMenu)'
                     r'|\.help|\.navigationTitle)\(\s*$')
MARK_NAME = re.compile(r'//\s*l10n:\s*LName')
MARK_SKIP = re.compile(r'//\s*l10n:\s*訳さない')

# CLDR の複数形の区分。書いても選ばれない区分を弾くためだけに使う（表にない言語は見ない）。
PLURAL_CATEGORIES = {
    'ja': {'other'}, 'zh': {'other'}, 'ko': {'other'},
    'en': {'one', 'other'}, 'de': {'one', 'other'}, 'es': {'one', 'other'}, 'it': {'one', 'other'},
}


def punch(text):
    return INTERPOLATION.sub(HOLE, SPECIFIER.sub(HOLE, text))


def unescape(literal):
    """Swift のリテラル表記を、カタログに入っている素の文字列へ戻す。"""
    body = literal[1:-1]
    out, i = [], 0
    while i < len(body):
        c = body[i]
        if c == '\\' and i + 1 < len(body) and body[i + 1] != '(':
            nxt = body[i + 1]
            out.append({'n': '\n', 't': '\t', '"': '"', '\\': '\\', "'": "'", '0': '\0'}.get(nxt, '\\' + nxt))
            i += 2
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def swift_files():
    for dirpath, _, names in os.walk(SOURCE_DIR):
        for name in sorted(names):
            if name.endswith('.swift'):
                yield os.path.join(dirpath, name)


def code_part(line):
    """行末のコメントを落とす（文字列の中の // は残す）。"""
    rest = STRING_LITERAL.sub(lambda m: ' ' * len(m.group()), line)
    cut = rest.find('//')
    return line if cut < 0 else line[:cut]


def translation_values(localization):
    """stringUnit / variations / substitutions のどこにあっても訳文を集める。(訳文, state, 変種か)"""
    found = []

    def walk(node, variant):
        if not isinstance(node, dict):
            return
        unit = node.get('stringUnit')
        if isinstance(unit, dict):
            found.append((unit.get('value', ''), unit.get('state'), variant))
        for child in (node.get('variations') or {}).values():
            for grandchild in (child or {}).values():
                walk(grandchild, True)
        for child in (node.get('substitutions') or {}).values():
            walk(child, True)

    walk(localization, False)
    return found


def used_plural_categories(node, found=None):
    found = set() if found is None else found
    if not isinstance(node, dict):
        return found
    for kind, child in (node.get('variations') or {}).items():
        if kind == 'plural':
            found.update((child or {}).keys())
        for grandchild in (child or {}).values():
            used_plural_categories(grandchild, found)
    for child in (node.get('substitutions') or {}).values():
        used_plural_categories(child, found)
    return found


def load(table):
    return json.load(open(os.path.join(RESOURCES, table + '.xcstrings'), encoding='utf-8'))


def main():
    quiet = '--quiet' in sys.argv
    catalogs = {table: load(table) for table in (MAIN, MCP, INFO)}
    shapes = {table: {punch(key) for key in catalogs[table]['strings']} for table in (MAIN, MCP)}
    used = {MAIN: set(), MCP: set()}
    errors = []

    # 1 と 2. Swift 側の文言
    for path in swift_files():
        rel = os.path.relpath(path, ROOT)
        agent_facing = os.path.basename(path) in AGENT_FACING
        for number, line in enumerate(open(path, encoding='utf-8'), 1):
            if line.lstrip().startswith('//'):
                continue
            code = code_part(line)
            for match in STRING_LITERAL.finditer(code):
                literal = match.group()
                before = code[:match.start()]
                wrapped = WRAPPED.search(before)
                if not wrapped and not JAPANESE.search(literal):
                    continue
                where = '%s:%d  %s' % (rel, number, literal)
                if wrapped:
                    table = MCP if wrapped.group(1) == 'LM' else MAIN
                elif agent_facing or MARK_SKIP.search(line):
                    continue
                elif MARK_NAME.search(line) or SWIFTUI.search(before):
                    table = MAIN
                else:
                    errors.append(where + ' は訳が引かれません（L() で包むか、SwiftUI の部品にじかに書く）')
                    continue
                shape = punch(unescape(literal))
                used[table].add(shape)
                if shape not in shapes[table]:
                    errors.append(where + ' が %s.xcstrings にありません' % table)

    # 3、4、6. 訳の抜け、書式指定子の食い違い、複数形の区分
    for table, catalog in catalogs.items():
        source = catalog.get('sourceLanguage', 'ja')
        strings = catalog['strings']
        # InfoPlist のキーは文言ではないので、元の言語の値も要る
        required = ['en'] if table != INFO else ['en', source]
        for key in sorted(strings):
            localizations = strings[key].get('localizations') or {}
            expected = SPECIFIER.findall(key)
            for language in required:
                found = translation_values(localizations.get(language))
                if not found:
                    errors.append('%s: %s の訳がありません: %r' % (table, language, key))
                for value, state, variant in found:
                    if state != 'translated':
                        errors.append('%s: %s の訳が未確定 (%s) です: %r' % (table, language, state, key))
                    if not value.strip():
                        errors.append('%s: %s の訳が空です: %r' % (table, language, key))
                    if '#@' in value or '%arg' in value:
                        continue
                    # 位置指定（%1$@）は外して型だけ比べる。順番は入れ替えてよい
                    actual = [re.sub(r'\d+\$', '', s) for s in SPECIFIER.findall(value)]
                    if variant:
                        extra = [s for s in actual if s not in expected]
                        if extra:
                            errors.append('%s: %s の変種にキーにない書式指定子があります: %r -> %r' % (table, language, key, value))
                    elif sorted(actual) != sorted(expected):
                        errors.append('%s: %s の書式指定子がキーと違います: %r -> %r' % (table, language, key, value))
            for language, localization in localizations.items():
                categories = PLURAL_CATEGORIES.get(language.split('-')[0])
                for category in sorted(used_plural_categories(localization)):
                    if categories is not None and category not in categories:
                        errors.append('%s: %s に %r の複数形はありません: %r' % (table, language, category, key))

    # 5. 使われていないキー
    for table in (MAIN, MCP):
        for key in sorted(catalogs[table]['strings']):
            if punch(key) not in used[table]:
                errors.append('%s: Swift 側で使われていません: %r' % (table, key))

    # 7. Localizable に MCP の文言を入れない
    for key, entry in sorted(catalogs[MAIN]['strings'].items()):
        if 'mcp' in json.dumps(entry, ensure_ascii=False).lower() or 'mcp' in key.lower():
            errors.append('%s: MCP の文言は MCP.xcstrings に入れてください（App Store 用に入れないため）: %r' % (MAIN, key))

    for error in errors:
        print('エラー: ' + error, file=sys.stderr)
    if errors:
        print('\nカタログと合っていない箇所が %d 件あります。' % len(errors), file=sys.stderr)
        return 1
    if not quiet:
        print('訳のカタログ: ' + '、'.join('%s %d キー' % (t, len(c['strings'])) for t, c in catalogs.items()))
    return 0


if __name__ == '__main__':
    sys.exit(main())
