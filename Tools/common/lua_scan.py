"""Lua source scanning shared by the lint and the patch check
(Architecture/20261002-Phase10.md sections 3.3 and 9).

Two scanners:
- strip_comment_and_strings works one line at a time, as the secret-read lint
  always has. PersonalAddon's code keeps strings and comments on one line.
- blank_lua works on a whole file and also handles --[[ ]] blocks and long strings,
  which Blizzard's code uses. It keeps every newline, so line numbers survive.
"""
import re


def strip_comment_and_strings(line):
    """Returns (code with string contents blanked, list of string literals)."""
    code, strings, index, quote, current = [], [], 0, None, []
    while index < len(line):
        char = line[index]
        if quote:
            if char == "\\":
                current.append(line[index:index + 2])
                index += 2
                continue
            if char == quote:
                strings.append("".join(current))
                current = []
                code.append(quote + quote)
                quote = None
            else:
                current.append(char)
            index += 1
            continue
        if line.startswith("--", index):
            break
        if char in ("'", '"'):
            quote = char
        else:
            code.append(char)
        index += 1
    return "".join(code), strings


# Order matters: a long comment must win over a line comment at the same "--", and
# a quoted string is matched where it starts, so "--" inside it is never a comment.
_TOKENS = re.compile(
    r"--\[(?P<lceq>=*)\[.*?\](?P=lceq)\]"
    r"|--[^\n]*"
    r"|\[(?P<lseq>=*)\[.*?\](?P=lseq)\]"
    r"|\"(?:\\.|[^\"\\\n])*\"?"
    r"|'(?:\\.|[^'\\\n])*'?",
    re.DOTALL,
)


def _keep_newlines(text):
    return "".join(char if char == "\n" else " " for char in text)


def _blank(match):
    token = match.group(0)
    if token.startswith("--"):
        return _keep_newlines(token)
    if token.startswith("["):
        opener = token.index("[", 1) + 1
        closer = len(token) - opener
        return token[:opener] + _keep_newlines(token[opener:closer]) + token[closer:]
    quote = token[0]
    closed = len(token) > 1 and token.endswith(quote)
    body = token[1:-1] if closed else token[1:]
    return quote + " " * len(body) + (quote if closed else "")


def blank_lua(text):
    """The text with every comment and the contents of every string blanked.
    Delimiters stay, so a call written as Name("x") still reads Name(" ")."""
    return _TOKENS.sub(_blank, text)


def line_of(text, offset):
    """The 1-based line number of a character offset."""
    return text.count("\n", 0, offset) + 1
