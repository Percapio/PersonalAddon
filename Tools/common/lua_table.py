"""Reads the table literal in a generated API docs file
(Architecture/20261002-Phase10.md section 3.1).

The docs are data written as Lua: `local Name = { ... };` followed by a call that
registers it. They are parsed as text here and never executed.
"""
import re


class LuaParseError(Exception):
    pass


class NameRef(str):
    """A bare name or dotted chain, such as Enum.SecretAspect.BarValue."""


class LuaNumber(str):
    """A number literal, kept as written."""


class LuaTable:
    """A table constructor's contents: positional items and keyed fields."""

    def __init__(self):
        self.items = []
        self.fields = {}

    def get(self, key, default=None):
        return self.fields.get(key, default)


_TOKEN = re.compile(
    r"(?P<space>\s+)"
    r"|(?P<comment>--\[(?P<ceq>=*)\[.*?\](?P=ceq)\]|--[^\n]*)"
    r"|(?P<long>\[(?P<leq>=*)\[(?P<lbody>.*?)\](?P=leq)\])"
    r"|(?P<string>\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*')"
    r"|(?P<number>0[xX][0-9a-fA-F]+|\d+(?:\.\d*)?(?:[eE][+-]?\d+)?|\.\d+)"
    r"|(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
    r"|(?P<punct>\.\.|[{}\[\]=,;().:\-+*/%^])",
    re.DOTALL,
)

_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "a": "\a",
            "b": "\b", "f": "\f", "v": "\v", "\n": "\n"}


def _unescape(body):
    out, index = [], 0
    while index < len(body):
        char = body[index]
        if char == "\\" and index + 1 < len(body):
            nxt = body[index + 1]
            if nxt.isdigit():
                digits = re.match(r"\d{1,3}", body[index + 1:]).group(0)
                out.append(chr(int(digits)))
                index += 1 + len(digits)
                continue
            out.append(_ESCAPES.get(nxt, nxt))
            index += 2
            continue
        out.append(char)
        index += 1
    return "".join(out)


def _tokens(text):
    position = 0
    while position < len(text):
        match = _TOKEN.match(text, position)
        if not match:
            raise LuaParseError(f"unexpected character {text[position]!r} at offset {position}")
        position = match.end()
        kind = match.lastgroup
        if kind in ("space", "comment"):
            continue
        if kind == "long":
            yield ("string", match.group("lbody"))
        elif kind == "string":
            yield ("string", _unescape(match.group(0)[1:-1]))
        elif kind == "number":
            yield ("number", match.group(0))
        elif kind == "name":
            yield ("name", match.group(0))
        else:
            yield ("punct", match.group(0))


class _Parser:
    def __init__(self, text):
        self.tokens = list(_tokens(text))
        self.index = 0

    def peek(self, offset=0):
        position = self.index + offset
        return self.tokens[position] if position < len(self.tokens) else ("eof", None)

    def take(self):
        token = self.peek()
        self.index += 1
        return token

    def expect(self, kind, value=None):
        token = self.take()
        if token[0] != kind or (value is not None and token[1] != value):
            raise LuaParseError(f"expected {value or kind}, found {token[1]!r}")
        return token

    _OPERATORS = {"+", "-", "*", "/", "%", "^", ".."}

    def value(self):
        """A value, or an arithmetic expression of values kept as its text, as some
        constants are written (A + B)."""
        left = self.primary()
        while self.peek()[0] == "punct" and self.peek()[1] in self._OPERATORS:
            operator = self.take()[1]
            right = self.primary()
            left = NameRef(f"{render(left)} {operator} {render(right)}")
        return left

    def primary(self):
        kind, text = self.peek()
        if kind == "punct" and text == "{":
            return self.table()
        if kind == "punct" and text == "-":
            self.take()
            return LuaNumber("-" + self.expect("number")[1])
        if kind == "string":
            self.take()
            return text
        if kind == "number":
            self.take()
            return LuaNumber(text)
        if kind == "name":
            self.take()
            if text in ("true", "false"):
                return text == "true"
            if text == "nil":
                return None
            chain = [text]
            while self.peek() == ("punct", ".") and self.peek(1)[0] == "name":
                self.take()
                chain.append(self.take()[1])
            return NameRef(".".join(chain))
        raise LuaParseError(f"unexpected token {text!r}")

    def table(self):
        self.expect("punct", "{")
        table = LuaTable()
        while self.peek() != ("punct", "}"):
            kind, text = self.peek()
            if kind == "name" and self.peek(1) == ("punct", "="):
                self.take()
                self.take()
                table.fields[text] = self.value()
            elif kind == "punct" and text == "[":
                self.take()
                key = self.value()
                self.expect("punct", "]")
                self.expect("punct", "=")
                table.fields[key] = self.value()
            else:
                table.items.append(self.value())
            if self.peek()[0] == "punct" and self.peek()[1] in (",", ";"):
                self.take()
            elif self.peek() != ("punct", "}"):
                raise LuaParseError(f"expected , or }} in table, found {self.peek()[1]!r}")
        self.expect("punct", "}")
        return table


def parse_docs_file(text):
    """The table assigned by the file's first `local Name = { ... }`."""
    parser = _Parser(text)
    while parser.peek()[0] != "eof":
        if parser.peek() == ("name", "local") and parser.peek(1)[0] == "name" \
                and parser.peek(2) == ("punct", "="):
            parser.index += 3
            return parser.value()
        parser.take()
    raise LuaParseError("no `local Name = { ... }` in file")


def render(value):
    """A value as literal text, so flags compare as the docs write them."""
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return "nil"
    if isinstance(value, LuaTable):
        parts = [render(item) for item in value.items]
        parts += [f"{key} = {render(item)}" for key, item in sorted(value.fields.items(), key=str)]
        return "{ " + ", ".join(parts) + " }"
    if isinstance(value, (NameRef, LuaNumber)):
        return str(value)
    if isinstance(value, str):
        return '"' + value + '"'
    return str(value)
