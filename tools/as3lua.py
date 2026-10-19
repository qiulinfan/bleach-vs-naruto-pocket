"""Translate the ActionScript 3 classes FFDec decompiles from BVN character
SWFs into Lua.

A class becomes a Lua table of methods; frame scripts become entries of
`frames` keyed by 1-based frame number. Lua runtime helpers used by the output
(BVNRuntime.*, written BVN_* here and renamed when the converter writes Lua): BVN_T (AS3 truthiness), BVN_INT,
BVN_TERN, BVN_ADD (string-aware +), BVN_RAND, BVN_NEW, BVN_TYPEOF.
Identifiers starting with `$` become `S_...`; `this` is `self`.
"""
import re

KEYWORDS_LUA = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
                "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"}
PUNCT = sorted(""">>>= === !== >>> <<= >>= ... += -= *= /= %= &= |= ^= == != <= >= && || ++ -- << >> :: { } ( ) [ ] ; , < > + - * / % & | ^ ! ~ ? : = .""".split(),
               key=len, reverse=True)
TOKEN_RE = re.compile(r"""
    (?P<ws>\s+|//[^\n]*|/\*.*?\*/)
  | (?P<num>0[xX][0-9a-fA-F]+|\d+\.\d*(?:[eE][-+]?\d+)?|\.\d+(?:[eE][-+]?\d+)?|\d+(?:[eE][-+]?\d+)?)
  | (?P<str>"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*')
  | (?P<id>[A-Za-z_$\u0080-￿][\w$\u0080-￿]*)
  | (?P<p>""" + "|".join(re.escape(p) for p in PUNCT) + r""")
""", re.S | re.X)


class Unsupported(Exception):
    pass


def tokenize(src):
    out, pos = [], 0
    while pos < len(src):
        m = TOKEN_RE.match(src, pos)
        if not m:
            raise Unsupported("bad character %r" % src[pos])
        pos = m.end()
        k = m.lastgroup
        if k == "ws":
            continue
        out.append((k, m.group(k)))
    out.append(("eof", ""))
    return out


def lua_string(s):
    body = s[1:-1]
    if s[0] == "'":
        body = body.replace('\\\'', "'").replace('"', '\\"')
    return '"' + body + '"'


def ident(name):
    if name.startswith("$"):
        name = "S_" + name[1:]
    return name


BINARY = [
    ("||",), ("&&",), ("|",), ("^",), ("&",),
    ("==", "!=", "===", "!=="),
    ("<", ">", "<=", ">=", "is", "as", "in", "instanceof"),
    ("<<", ">>", ">>>"),
    ("+", "-"),
    ("*", "/", "%"),
]
ASSIGN = {"=", "+=", "-=", "*=", "/=", "%=", "|=", "&=", "^=", "<<=", ">>=", ">>>="}
BUILTIN_CALLS = {"int": "BVN_INT", "uint": "BVN_INT", "Number": "tonumber", "String": "tostring", "Boolean": "BVN_T",
                 "trace": "BVN_TRACE", "isNaN": "BVN_ISNAN", "getDefinitionByName": "BVN_DEF"}
CASTS = {"MovieClip", "Sprite", "DisplayObject", "Object", "DisplayObjectContainer"}


# Expression nodes are tuples: (kind, ...)
def type_default(typ):
    """The value an AS3 variable of this type starts with."""
    if typ in ("int", "uint"):
        return ("num", "0")
    if typ == "Number":
        return ("raw", "(0/0)")
    if typ == "Boolean":
        return ("raw", "false")
    return None


class Parser:
    def __init__(self, tokens):
        self.t = tokens
        self.i = 0

    def peek(self, k=0):
        return self.t[self.i + k]

    def next(self):
        tok = self.t[self.i]
        self.i += 1
        return tok

    def at(self, v):
        return self.t[self.i][1] == v and self.t[self.i][0] in ("p", "id")

    def eat(self, v):
        if self.at(v):
            self.i += 1
            return True
        return False

    def expect(self, v):
        if not self.eat(v):
            raise Unsupported("expected %s got %s" % (v, self.peek()[1]))

    # Statements -------------------------------------------------------------
    def block(self):
        self.expect("{")
        out = []
        while not self.at("}"):
            if self.peek()[0] == "eof":
                raise Unsupported("unterminated block")
            out.append(self.statement())
        self.expect("}")
        return out

    def body(self):
        if self.at("{"):
            return self.block()
        return [self.statement()]

    def type_annot(self):
        if self.eat(":"):
            if self.eat("*"):
                return None
            t = self.next()[1]
            if self.eat("."):
                self.expect("<")
                self.next()
                self.expect(">")
            return t
        return None

    def statement(self):
        k, v = self.peek()
        if v == ";" and k == "p":
            self.next()
            return ("empty",)
        if k == "p" and v == "{":
            return ("block", self.block())
        if k == "id":
            if v == "var" or v == "const":
                self.next()
                decls = []
                while True:
                    name = ident(self.next()[1])
                    typ = self.type_annot()
                    init = self.expr() if self.eat("=") else type_default(typ)
                    decls.append((name, init))
                    if not self.eat(","):
                        break
                self.eat(";")
                return ("var", decls)
            if v == "if":
                self.next()
                self.expect("(")
                cond = self.expr()
                self.expect(")")
                then = self.body()
                other = None
                if self.eat("else"):
                    other = self.body()
                return ("if", cond, then, other)
            if v == "while":
                self.next()
                self.expect("(")
                cond = self.expr()
                self.expect(")")
                return ("while", cond, self.body())
            if v == "do":
                self.next()
                b = self.body()
                self.expect("while")
                self.expect("(")
                cond = self.expr()
                self.expect(")")
                self.eat(";")
                return ("dowhile", cond, b)
            if v == "for":
                self.next()
                if self.eat("each"):
                    self.expect("(")
                    self.eat("var")
                    name = ident(self.next()[1])
                    self.type_annot()
                    self.expect("in")
                    obj = self.expr()
                    self.expect(")")
                    return ("foreach", name, obj, self.body())
                self.expect("(")
                if self.at("var") and (self.peek(2)[1] == "in" or (self.peek(2)[1] == ":" and self.peek(4)[1] == "in")):
                    self.next()
                    name = ident(self.next()[1])
                    self.type_annot()
                    self.expect("in")
                    obj = self.expr()
                    self.expect(")")
                    return ("forin", name, obj, self.body())
                init = None if self.at(";") else self.statement_no_semi()
                self.expect(";")
                cond = None if self.at(";") else self.expr()
                self.expect(";")
                step = None if self.at(")") else self.expr()
                self.expect(")")
                return ("for", init, cond, step, self.body())
            if v == "switch":
                self.next()
                self.expect("(")
                subj = self.expr()
                self.expect(")")
                self.expect("{")
                cases = []
                while not self.at("}"):
                    if self.eat("case"):
                        val = self.expr()
                        self.expect(":")
                        cases.append([val, []])
                    elif self.eat("default"):
                        self.expect(":")
                        cases.append([None, []])
                    else:
                        if not cases:
                            raise Unsupported("switch body")
                        cases[-1][1].append(self.statement())
                self.expect("}")
                return ("switch", subj, cases)
            if v == "return":
                self.next()
                val = None if self.at(";") or self.at("}") else self.expr()
                self.eat(";")
                return ("return", val)
            if v == "break":
                self.next()
                self.eat(";")
                return ("break",)
            if v == "continue":
                self.next()
                self.eat(";")
                return ("continue",)
            if v == "try":
                self.next()
                b = self.block()
                while self.eat("catch"):
                    self.expect("(")
                    while not self.at(")"):
                        self.next()
                    self.expect(")")
                    self.block()
                if self.eat("finally"):
                    b += self.block()
                return ("block", b)
            if v == "throw":
                self.next()
                self.expr()
                self.eat(";")
                return ("empty",)
        s = self.statement_no_semi()
        self.eat(";")
        return s

    def statement_no_semi(self):
        if self.at("var"):
            self.next()
            name = ident(self.next()[1])
            typ = self.type_annot()
            init = self.expr() if self.eat("=") else type_default(typ)
            return ("var", [(name, init)])
        e = self.expr()
        return ("expr", e)

    # Expressions --------------------------------------------------------------
    def expr(self):
        e = self.assign()
        while self.at(","):
            self.next()
            e = ("seq", e, self.assign())
        return e

    def assign(self):
        left = self.ternary()
        k, v = self.peek()
        if k == "p" and v in ASSIGN:
            self.next()
            right = self.assign()
            return ("assign", v, left, right)
        return left

    def ternary(self):
        c = self.binary(0)
        if self.eat("?"):
            a = self.assign()
            self.expect(":")
            b = self.assign()
            return ("tern", c, a, b)
        return c

    def binary(self, level):
        if level == len(BINARY):
            return self.unary()
        left = self.binary(level + 1)
        while True:
            k, v = self.peek()
            if v in BINARY[level] and k in ("p", "id"):
                self.next()
                if v in ("is", "as"):
                    self.next()
                    while self.eat("."):
                        self.next()
                    if v == "is":
                        left = ("bool", True)
                    continue
                right = self.binary(level + 1)
                left = ("bin", v, left, right)
            else:
                return left

    def unary(self):
        k, v = self.peek()
        if k == "p" and v in ("!", "-", "+", "~"):
            self.next()
            return ("un", v, self.unary())
        if k == "p" and v in ("++", "--"):
            self.next()
            target = self.unary()
            return ("assign", "+=" if v == "++" else "-=", target, ("num", "1"))
        if k == "id" and v == "typeof":
            self.next()
            return ("call", ("raw", "BVN_TYPEOF"), [self.unary()])
        if k == "id" and v == "delete":
            self.next()
            return ("assign", "=", self.unary(), ("nil",))
        if k == "id" and v == "new":
            self.next()
            cls = self.primary()
            while self.eat("."):
                cls = ("member", cls, self.next()[1])
            args = self.args() if self.at("(") else []
            # new X().play(): members of the new object.
            return self.postfix(("call", ("raw", "BVN_NEW"), [("str", '"%s"' % self.name_of(cls))] + args))
        return self.postfix(self.primary())

    def name_of(self, node):
        if node[0] == "name":
            return node[1]
        if node[0] == "member":
            return self.name_of(node[1]) + "." + node[2]
        return "?"

    def args(self):
        self.expect("(")
        out = []
        while not self.at(")"):
            out.append(self.assign())
            if not self.eat(","):
                break
        self.expect(")")
        return out

    def postfix(self, e):
        while True:
            k, v = self.peek()
            if k == "p" and v == ".":
                self.next()
                e = ("member", e, self.next()[1])
            elif k == "p" and v == "(":
                e = ("call", e, self.args())
            elif k == "p" and v == "[":
                self.next()
                idx = self.expr()
                self.expect("]")
                e = ("index", e, idx)
            elif k == "p" and v in ("++", "--"):
                self.next()
                e = ("assign", "+=" if v == "++" else "-=", e, ("num", "1"), "post")
            else:
                return e

    def primary(self):
        k, v = self.next()
        if k == "num":
            return ("num", v)
        if k == "str":
            return ("str", lua_string(v))
        if k == "id":
            if v in ("true", "false"):
                return ("bool", v == "true")
            if v in ("null", "undefined"):
                return ("nil",)
            if v == "this":
                return ("this",)
            if v == "NaN":
                return ("raw", "(0/0)")
            if v == "function":
                raise Unsupported("function expression")
            return ("name", v)
        if v == "(":
            e = self.expr()
            self.expect(")")
            return ("paren", e)
        if v == "{":
            fields = []
            while not self.at("}"):
                kk, key = self.next()
                key = lua_string(key)[1:-1] if kk == "str" else key
                self.expect(":")
                fields.append((key, self.assign()))
                if not self.eat(","):
                    break
            self.expect("}")
            return ("obj", fields)
        if v == "[":
            items = []
            while not self.at("]"):
                items.append(self.assign())
                if not self.eat(","):
                    break
            self.expect("]")
            return ("arr", items)
        raise Unsupported("unexpected %s" % v)


class Emitter:
    def __init__(self, methods, fields):
        self.methods = methods
        self.fields = fields
        self.tmp = 0
        self.locals = set()
        self.dynamic = set()

    def new_tmp(self):
        self.tmp += 1
        return "_t%d" % self.tmp

    # Expressions
    def is_stringy(self, e):
        return e[0] == "str" or (e[0] == "bin" and e[1] == "+" and (self.is_stringy(e[2]) or self.is_stringy(e[3])))

    def cond(self, e):
        """Expression in a boolean context."""
        if e[0] == "paren":
            return self.cond(e[1])
        if e[0] == "bin" and e[1] in ("&&", "||"):
            return "(%s %s %s)" % (self.cond(e[2]), "and" if e[1] == "&&" else "or", self.cond(e[3]))
        if e[0] == "un" and e[1] == "!":
            return "(not %s)" % self.cond(e[2])
        if e[0] == "bin" and e[1] in ("==", "!=", "===", "!==", "<", ">", "<=", ">="):
            return self.ex(e)
        if e[0] == "bool":
            return "true" if e[1] else "false"
        return "BVN_T(%s)" % self.ex(e)

    def ex(self, e):
        k = e[0]
        if k == "num":
            return e[1]
        if k == "str":
            return e[1]
        if k == "bool":
            return "true" if e[1] else "false"
        if k == "nil":
            return "nil"
        if k == "raw":
            return e[1]
        if k == "this":
            return "self"
        if k == "paren":
            return "(%s)" % self.ex(e[1])
        if k == "name":
            n = e[1]
            if n in self.fields or n in self.methods or n in ("parent", "root", "currentFrame", "totalFrames", "name", "x", "y", "scaleX", "scaleY", "visible", "alpha", "rotation"):
                return "self." + ident(n)
            if n == "Math":
                return "math"
            if n in self.locals or n.startswith("_"):
                return ident(n)
            if n in self.dynamic or n.startswith("$"):
                # $-names are controllers the kernel sets on the clip ($attacker_ctrler, ...).
                return "self." + ident(n)
            # Any other bare name is a class (bitmap faces, sounds, effects).
            return 'BVN_CLASS("%s")' % n
        if k == "member":
            obj, name = e[1], e[2]
            if obj == ("name", "Math"):
                return {"PI": "math.pi"}.get(name, "math." + name)
            base = self.ex(obj)
            name = ident(name)
            if name in KEYWORDS_LUA:
                return '%s["%s"]' % (base, name)
            return "%s.%s" % (base, name)
        if k == "index":
            return "%s[%s]" % (self.ex(e[1]), self.ex(e[2]))
        if k == "call":
            fn, args = e[1], e[2]
            a = ", ".join(self.ex(x) for x in args)
            if fn[0] == "name":
                n = fn[1]
                if n in CASTS and len(args) == 1:
                    return self.ex(args[0])
                if n in BUILTIN_CALLS:
                    return "%s(%s)" % (BUILTIN_CALLS[n], a)
                if n in ("stop", "play", "gotoAndPlay", "gotoAndStop", "nextFrame", "prevFrame") or n in self.methods:
                    return "self:%s(%s)" % (ident(n), a)
                if n == "getTimer":
                    return "BVN_TIMER()"
                return "self:%s(%s)" % (ident(n), a)
            if fn[0] == "member":
                obj, name = fn[1], fn[2]
                if obj == ("name", "Math"):
                    if name == "random":
                        return "BVN_RAND()"
                    if name == "round":
                        return "BVN_ROUND(%s)" % a
                    return "math.%s(%s)" % (name, a)
                base = self.ex(obj)
                name = ident(name)
                if name in KEYWORDS_LUA:
                    return '%s["%s"](%s%s)' % (base, name, base, (", " + a) if a else "")
                if obj[0] in ("name", "member", "this", "index", "paren", "call"):
                    return "%s:%s(%s)" % (base, name, a)
                return "(%s):%s(%s)" % (base, name, a)
            if fn[0] == "raw":
                return "%s(%s)" % (fn[1], a)
            raise Unsupported("call target")
        if k == "un":
            op, x = e[1], e[2]
            if op == "!":
                return "(not %s)" % self.cond(x)
            if op == "-":
                return "(-%s)" % self.ex(x)
            if op == "+":
                return self.ex(x)
            raise Unsupported("unary " + op)
        if k == "bin":
            op, l, r = e[1], e[2], e[3]
            if op in ("&&", "||"):
                return "(%s %s %s)" % (self.ex(l), "and" if op == "&&" else "or", self.ex(r))
            if op in ("==", "==="):
                return "(%s == %s)" % (self.ex(l), self.ex(r))
            if op in ("!=", "!=="):
                return "(%s ~= %s)" % (self.ex(l), self.ex(r))
            if op == "+":
                if self.is_stringy(l) or self.is_stringy(r):
                    return "(%s .. %s)" % (self.ex(l), self.ex(r))
                return "BVN_ADD(%s, %s)" % (self.ex(l), self.ex(r))
            if op == "%":
                return "math.fmod(%s, %s)" % (self.ex(l), self.ex(r))
            if op in ("-", "*", "/", "<", ">", "<=", ">="):
                return "(%s %s %s)" % (self.ex(l), op, self.ex(r))
            if op in ("&", "|", "^", "<<", ">>", ">>>"):
                lua = {"&": "&", "|": "|", "^": "~", "<<": "<<", ">>": ">>", ">>>": ">>"}[op]
                return "(BVN_INT(%s) %s BVN_INT(%s))" % (self.ex(l), lua, self.ex(r))
            if op == "in":
                return "(%s[%s] ~= nil)" % (self.ex(r), self.ex(l))
            raise Unsupported("binary " + op)
        if k == "tern":
            return "BVN_TERN(%s, %s, %s)" % (self.cond(e[1]), self.ex(e[2]), self.ex(e[3]))
        if k == "obj":
            parts = []
            for key, val in e[1]:
                if re.match(r"^[A-Za-z_]\w*$", key) and key not in KEYWORDS_LUA:
                    parts.append("%s = %s" % (key, self.ex(val)))
                else:
                    parts.append('["%s"] = %s' % (key, self.ex(val)))
            return "{" + ", ".join(parts) + "}"
        if k == "arr":
            return "BVN_ARRAY({" + ", ".join(self.ex(x) for x in e[1]) + "})"
        if k == "assign":
            # An assignment used as a value (if (++n < 10), a = b = c): done in a closure that
            # returns the new value (the old one for a postfix ++ / --).
            target = self.ex(e[2])
            body = " ".join(x.strip() for x in self.assign_stmt(e, ""))
            if len(e) > 4 and e[4] == "post":
                return "(function() local v = %s; %s; return v end)()" % (target, body)
            return "(function() %s; return %s end)()" % (body, target)
        if k == "seq":
            raise Unsupported("comma expression")
        raise Unsupported(k)

    # Statements
    def assign_stmt(self, e, ind):
        op, target, value = e[1], e[2], e[3]
        t = self.ex(target)
        if op == "=":
            return [ind + "%s = %s" % (t, self.ex(value))]
        bop = op[:-1]
        return [ind + "%s = %s" % (t, self.ex(("bin", bop, target, value)))]

    def stmts(self, lst, ind, loop_label=None):
        out = []
        for s in lst:
            out += self.stmt(s, ind, loop_label)
        return out

    def stmt(self, s, ind, loop_label=None):
        k = s[0]
        if k == "empty":
            return []
        if k == "block":
            return [ind + "do"] + self.stmts(s[1], ind + "  ", loop_label) + [ind + "end"]
        if k == "var":
            out = []
            for name, init in s[1]:
                self.locals.add(name)
                if init is not None and init[0] == "assign":
                    out += self.assign_stmt(init, ind)
                    init = init[2]
                out.append(ind + "local %s = %s" % (name, self.ex(init) if init is not None else "nil"))
            return out
        if k == "expr":
            e = s[1]
            while e[0] == "paren":
                e = e[1]
            if e[0] == "assign":
                return self.assign_stmt(e, ind)
            if e[0] == "seq":
                return self.stmt(("expr", e[1]), ind) + self.stmt(("expr", e[2]), ind)
            if e[0] == "call":
                return [ind + self.ex(e)]
            if e[0] == "tern":
                return self.stmt(("if", e[1], [("expr", e[2])], [("expr", e[3])]), ind, loop_label)
            if e[0] == "bin" and e[1] in ("&&", "||"):
                c = e[2] if e[1] == "&&" else ("un", "!", e[2])
                return self.stmt(("if", c, [("expr", e[3])], None), ind, loop_label)
            return [ind + "local _ = %s" % self.ex(e)]
        if k == "if":
            out = [ind + "if %s then" % self.cond(s[1])]
            out += self.stmts(s[2], ind + "  ", loop_label)
            other = s[3]
            while other and len(other) == 1 and other[0][0] == "if":
                o = other[0]
                out.append(ind + "elseif %s then" % self.cond(o[1]))
                out += self.stmts(o[2], ind + "  ", loop_label)
                other = o[3]
            if other:
                out.append(ind + "else")
                out += self.stmts(other, ind + "  ", loop_label)
            out.append(ind + "end")
            return out
        if k == "while":
            return [ind + "while %s do" % self.cond(s[1])] + self.stmts(s[2], ind + "  ", "loop") + [ind + "::continue::", ind + "end"] if self.has_continue(s[2]) else \
                [ind + "while %s do" % self.cond(s[1])] + self.stmts(s[2], ind + "  ", "loop") + [ind + "end"]
        if k == "dowhile":
            return [ind + "repeat"] + self.stmts(s[2], ind + "  ", "loop") + [ind + "until not %s" % self.cond(s[1])]
        if k == "for":
            out = [ind + "do"]
            if s[1]:
                out += self.stmt(s[1], ind + "  ")
            out.append(ind + "  while %s do" % (self.cond(s[2]) if s[2] else "true"))
            out += self.stmts(s[4], ind + "    ", "loop")
            if self.has_continue(s[4]):
                out.append(ind + "    ::continue::")
            if s[3]:
                out += self.stmt(("expr", s[3]), ind + "    ")
            out += [ind + "  end", ind + "end"]
            return out
        if k in ("forin", "foreach"):
            self.locals.add(s[1])
            kv = "%s, _" % s[1] if k == "forin" else "_, %s" % s[1]
            return [ind + "for %s in BVN_PAIRS(%s) do" % (kv, self.ex(s[2]))] + self.stmts(s[3], ind + "  ", "loop") + [ind + "end"]
        if k == "switch":
            t = self.new_tmp()
            out = [ind + "repeat", ind + "  local %s = %s" % (t, self.ex(s[1]))]
            # Fall-through: a case without break runs into the next one.
            matched = self.new_tmp()
            out.append(ind + "  local %s = false" % matched)
            for val, body in s[2]:
                if val is None:
                    out.append(ind + "  %s = true" % matched)
                else:
                    out.append(ind + "  if %s or %s == %s then %s = true end" % (matched, t, self.ex(val), matched))
                out.append(ind + "  if %s then" % matched)
                out += self.stmts(body, ind + "    ", "switch")
                out.append(ind + "  end")
            out.append(ind + "until true")
            return out
        if k == "return":
            return [ind + ("do return %s end" % self.ex(s[1]) if s[1] is not None else "do return end")]
        if k == "break":
            return [ind + "break"]
        if k == "continue":
            return [ind + "goto continue"]
        raise Unsupported(k)

    def has_continue(self, lst):
        return any(s[0] == "continue" or (s[0] == "if" and (self.has_continue(s[2]) or (s[3] and self.has_continue(s[3])))) for s in lst)


CLASS_RE = re.compile(r"public\s+(?:dynamic\s+)?class\s+(\S+)\s+extends\s+(\S+)")


def split_members(src):
    """Return (fields {name: init_src}, methods {name: (params, body_src)}, frame_map {frame: method})."""
    m = CLASS_RE.search(src)
    if not m:
        raise Unsupported("no class")
    i = src.index("{", m.end()) + 1
    fields, methods = {}, {}
    depth = 0
    member_re = re.compile(r"\s*(?:\[[^\]]*\]\s*)?(?:(?:public|private|protected|internal|static|override|final)\s+)*(var|const|function)\s+(?:(get|set)\s+)?([\w$\u0080-￿]+)")
    while True:
        while i < len(src) and src[i] in " \t\r\n":
            i += 1
        if i >= len(src) or src[i] == "}":
            break
        mm = member_re.match(src, i)
        if not mm:
            raise Unsupported("member at %r" % src[i:i + 40])
        kind, accessor, name = mm.group(1), mm.group(2), mm.group(3)
        j = mm.end()
        if kind in ("var", "const"):
            end = src.index(";", j)
            decl = src[j:end]
            init = decl.split("=", 1)[1].strip() if "=" in decl else None
            if init is None:
                # AS3 defaults: int / uint 0, Number NaN, Boolean false.
                tm = re.match(r"\s*:\s*(\w+)", decl)
                init = {"int": "0", "uint": "0", "Number": "NaN", "Boolean": "false"}.get(tm.group(1)) if tm else None
            fields[name] = init
            i = end + 1
        else:
            p0 = src.index("(", j)
            p1 = src.index(")", p0)
            params = [p.split(":")[0].split("=")[0].strip() for p in src[p0 + 1:p1].split(",") if p.strip()]
            b0 = src.index("{", p1)
            depth, k = 0, b0
            in_str = None
            while True:
                c = src[k]
                if in_str:
                    if c == "\\":
                        k += 1
                    elif c == in_str:
                        in_str = None
                elif c in "\"'":
                    in_str = c
                elif c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        break
                k += 1
            if accessor:
                name = accessor + "_" + name
            methods[name] = ([ident(p) for p in params], src[b0:k + 1])
            i = k + 1
    cls = m.group(1)
    frame_map = {}
    ctor = methods.get(cls)
    if ctor:
        # FFDec wraps the long call, sometimes between `this` and `.frameN`.
        for idx, fn in re.findall(r"(\d+)\s*,\s*this\s*\.\s*([\w$]+)", ctor[1].split("addFrameScript", 1)[1] if "addFrameScript" in ctor[1] else ""):
            frame_map[int(idx) + 1] = fn
    return cls, fields, methods, frame_map


# An obfuscator's no-op FFDec leaves as stack code: `§§push(x); switch(n) {} §§pop()`
# (an empty switch between the push and the pop) is just `x`.
PUSH_POP = re.compile(r"§§push\(((?:[^()]|\([^()]*\))*)\);\s*switch\(\s*-?\d+\s*\)\s*\{\s*\}\s*§§pop\(\)", re.S)


def fold_push_pop(body):
    # A plain name stays bare: a Lua statement must not start with a parenthesis.
    return PUSH_POP.sub(lambda m: m.group(1) if re.fullmatch(r"[\w$.]+", m.group(1).strip()) else "(" + m.group(1) + ")", body)


def translate_class(src):
    """Lua source for one class: `return {fields = {...}, methods = {...}, frames = {[n] = "method"}}`.
    Returns (lua_source, failures)."""
    if "§" in src.split("class", 1)[-1][:200] or "invalid_utf8" in src:
        raise Unsupported("obfuscated class")
    cls, fields, methods, frame_map = split_members(src)
    em = Emitter(set(methods), set(fields))
    # Names assigned without a declaration are dynamic properties of `this`.
    try:
        toks = tokenize(src[src.index("{", CLASS_RE.search(src).end()):])
    except Unsupported:
        toks = []
    for i in range(1, len(toks) - 1):
        k, v = toks[i]
        if k == "id" and toks[i + 1][0] == "p" and (toks[i + 1][1] in ASSIGN or toks[i + 1][1] in ("++", "--")) \
                and toks[i - 1][1] not in (".", "var", "const", ":", ","):
            em.dynamic.add(v)
    out = ["{", "  fields = {"]
    failures = []
    for name, init in fields.items():
        val = "nil"
        if init:
            try:
                val = em.ex(Parser(tokenize(init)).expr())
            except Unsupported as e:
                failures.append("%s.%s: %s" % (cls, name, e))
        if val != "nil":
            out.append("    %s = %s," % (ident(name) if ident(name) not in KEYWORDS_LUA else '["%s"]' % name, val))
    out.append("  },")
    out.append("  methods = {")
    for name, (params, body) in methods.items():
        if name == cls:
            body = re.sub(r"super\(\s*\)\s*;", "", body)
            body = re.sub(r"addFrameScript\([^;]*\)\s*;", "", body, flags=re.S)
            name = "__init"
        em.locals = set(params)
        try:
            body = fold_push_pop(body)
            if "§" in body:
                raise Unsupported("undecompiled bytecode")
            stmts = Parser(tokenize(body)).block()
            lines = em.stmts(stmts, "      ")
        except Unsupported as e:
            failures.append("%s.%s: %s" % (cls, name, e))
            lines = ['      BVN_UNSUPPORTED(%s)' % lua_string('"%s.%s"' % (cls, name))]
        key = ident(name)
        key = key if re.match(r"^[A-Za-z_]\w*$", key) and key not in KEYWORDS_LUA else '["%s"]' % key
        out.append("    %s = function(%s)" % (key, ", ".join(["self"] + params)))
        out += lines
        out.append("    end,")
    out.append("  },")
    out.append("  frames = {" + ", ".join('[%d] = "%s"' % (f, ident(n)) for f, n in sorted(frame_map.items())) + "},")
    out.append("}")
    return "\n".join(out), failures
