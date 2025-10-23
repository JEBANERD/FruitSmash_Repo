#!/usr/bin/env python3
"""Luau syntax checker for bundled script JSON."""
from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator, List, Optional, Sequence


class SyntaxError(Exception):
    """Parser syntax error with position metadata."""

    def __init__(self, message: str, line: int, column: int) -> None:
        super().__init__(message)
        self.line = line
        self.column = column
        self.message = message


@dataclass
class Token:
    type: str
    value: str
    line: int
    column: int


KEYWORDS = {
    "and": "KW_AND",
    "break": "KW_BREAK",
    "do": "KW_DO",
    "else": "KW_ELSE",
    "elseif": "KW_ELSEIF",
    "end": "KW_END",
    "false": "KW_FALSE",
    "for": "KW_FOR",
    "function": "KW_FUNCTION",
    "goto": "KW_GOTO",
    "if": "KW_IF",
    "in": "KW_IN",
    "local": "KW_LOCAL",
    "nil": "KW_NIL",
    "not": "KW_NOT",
    "or": "KW_OR",
    "repeat": "KW_REPEAT",
    "return": "KW_RETURN",
    "then": "KW_THEN",
    "true": "KW_TRUE",
    "until": "KW_UNTIL",
    "while": "KW_WHILE",
    "continue": "KW_CONTINUE",
    "export": "KW_EXPORT",
}


SUFFIX_BOUNDARY_TOKENS = {"DOT", "COLON", "LPAREN", "LBRACKET", "STRING"}

EXPR_BOUNDARY_TOKENS = {
    "COMMA",
    "RPAREN",
    "RBRACKET",
    "RBRACE",
    "PLUS",
    "MINUS",
    "MUL",
    "DIV",
    "FLOORDIV",
    "MOD",
    "POW",
    "EQ",
    "NE",
    "LT",
    "LE",
    "GT",
    "GE",
    "SHL",
    "SHR",
    "BITAND",
    "BITOR",
    "BITXOR",
    "CONCAT",
    "KW_AND",
    "KW_OR",
    "KW_THEN",
    "KW_ELSE",
    "KW_ELSEIF",
    "KW_UNTIL",
    "KW_END",
    "ASSIGN",
}


class Lexer:
    """Tokenizes Luau source."""

    def __init__(self, source: str) -> None:
        self.source = source
        self.length = len(source)
        self.index = 0
        self.line = 1
        self.column = 1

    def _peek(self, offset: int = 0) -> str:
        pos = self.index + offset
        if pos >= self.length:
            return ""
        return self.source[pos]

    def _advance(self, count: int = 1) -> None:
        for _ in range(count):
            if self.index >= self.length:
                return
            ch = self.source[self.index]
            self.index += 1
            if ch == "\n":
                self.line += 1
                self.column = 1
            else:
                self.column += 1

    def _match(self, expected: str) -> bool:
        if self.source.startswith(expected, self.index):
            self._advance(len(expected))
            return True
        return False

    def tokens(self) -> Iterator[Token]:
        while True:
            tok = self._next_token()
            yield tok
            if tok.type == "EOF":
                break

    def _next_token(self) -> Token:
        while True:
            if self.index >= self.length:
                return Token("EOF", "", self.line, self.column)
            ch = self._peek()
            if ch in " \t\r":
                self._advance()
                continue
            if ch == "\n":
                self._advance()
                continue
            if ch == "-" and self._peek(1) == "-":
                self._advance(2)
                if self._peek() == "[":
                    level = self._read_long_bracket_level()
                    if level >= 0:
                        self._read_long_bracket(level)
                        continue
                    else:
                        self._skip_until_newline()
                        continue
                self._skip_until_newline()
                continue
            if ch == "[":
                level = self._read_long_bracket_level()
                if level >= 0:
                    return self._read_long_string(level)
            break

        start_line, start_col = self.line, self.column
        ch = self._peek()

        # Identifiers or keywords
        if ch.isalpha() or ch == "_":
            ident = self._read_identifier()
            token_type = KEYWORDS.get(ident, "NAME")
            return Token(token_type, ident, start_line, start_col)

        # Numbers
        if ch.isdigit() or (ch == "." and self._peek(1).isdigit()):
            number = self._read_number()
            return Token("NUMBER", number, start_line, start_col)

        # Strings
        if ch in ('"', "'"):
            value = self._read_string(ch)
            return Token("STRING", value, start_line, start_col)

        # Operators and punctuation
        self._advance()
        if ch == ".":
            if self._match("."):
                if self._match("."):
                    return Token("ELLIPSIS", "...", start_line, start_col)
                return Token("CONCAT", "..", start_line, start_col)
            return Token("DOT", ".", start_line, start_col)
        if ch == ":":
            if self._match(":"):
                return Token("DOUBLECOLON", "::", start_line, start_col)
            return Token("COLON", ":", start_line, start_col)
        if ch == ",":
            return Token("COMMA", ",", start_line, start_col)
        if ch == ";":
            return Token("SEMICOLON", ";", start_line, start_col)
        if ch == "+":
            return Token("PLUS", "+", start_line, start_col)
        if ch == "-":
            if self._match(">"):
                return Token("ARROW", "->", start_line, start_col)
            return Token("MINUS", "-", start_line, start_col)
        if ch == "*":
            return Token("MUL", "*", start_line, start_col)
        if ch == "/":
            if self._match("/"):
                return Token("FLOORDIV", "//", start_line, start_col)
            return Token("DIV", "/", start_line, start_col)
        if ch == "%":
            return Token("MOD", "%", start_line, start_col)
        if ch == "^":
            return Token("POW", "^", start_line, start_col)
        if ch == "#":
            return Token("LEN", "#", start_line, start_col)
        if ch == "~":
            if self._match("="):
                return Token("NE", "~=", start_line, start_col)
            return Token("BITNOT", "~", start_line, start_col)
        if ch == "=":
            if self._match("="):
                return Token("EQ", "==", start_line, start_col)
            return Token("ASSIGN", "=", start_line, start_col)
        if ch == "<":
            if self._match("="):
                return Token("LE", "<=", start_line, start_col)
            if self._match("<"):
                return Token("SHL", "<<", start_line, start_col)
            return Token("LT", "<", start_line, start_col)
        if ch == ">":
            if self._match("="):
                return Token("GE", ">=", start_line, start_col)
            if self._match(">"):
                return Token("SHR", ">>", start_line, start_col)
            return Token("GT", ">", start_line, start_col)
        if ch == "(":
            return Token("LPAREN", "(", start_line, start_col)
        if ch == ")":
            return Token("RPAREN", ")", start_line, start_col)
        if ch == "[":
            return Token("LBRACKET", "[", start_line, start_col)
        if ch == "]":
            return Token("RBRACKET", "]", start_line, start_col)
        if ch == "{":
            return Token("LBRACE", "{", start_line, start_col)
        if ch == "}":
            return Token("RBRACE", "}", start_line, start_col)
        if ch == "|":
            return Token("PIPE", "|", start_line, start_col)
        if ch == "&":
            return Token("AMP", "&", start_line, start_col)
        if ch == "?":
            return Token("QUESTION", "?", start_line, start_col)

        raise SyntaxError(f"Unexpected character: {ch}", start_line, start_col)

    def _skip_until_newline(self) -> None:
        while self.index < self.length and self._peek() not in ("", "\n"):
            self._advance()

    def _read_long_bracket_level(self) -> int:
        if self._peek() != "[":
            return -1
        level = 0
        idx = 1
        while self._peek(idx) == "=":
            level += 1
            idx += 1
        if self._peek(idx) == "[":
            return level
        return -1

    def _read_long_string(self, level: int) -> Token:
        start_line, start_col = self.line, self.column
        # skip opening [===[
        self._advance(1 + level)
        self._advance()
        contents = []
        while True:
            if self.index >= self.length:
                raise SyntaxError("Unterminated long string", start_line, start_col)
            if self._peek() == "]" and self._check_closing(level):
                self._advance(1 + level)
                self._advance()
                break
            ch = self._peek()
            contents.append(ch)
            self._advance()
        return Token("STRING", "".join(contents), start_line, start_col)

    def _read_long_bracket(self, level: int) -> None:
        start_line, start_col = self.line, self.column
        self._advance(1 + level)
        self._advance()
        while True:
            if self.index >= self.length:
                raise SyntaxError("Unterminated long comment", start_line, start_col)
            if self._peek() == "]" and self._check_closing(level):
                self._advance(1 + level)
                self._advance()
                break
            self._advance()

    def _check_closing(self, level: int) -> bool:
        for offset in range(1, level + 1):
            if self._peek(offset) != "=":
                return False
        return self._peek(1 + level) == "]"

    def _read_identifier(self) -> str:
        start = self.index
        while self._peek().isalnum() or self._peek() == "_":
            self._advance()
        return self.source[start:self.index]

    def _read_number(self) -> str:
        start = self.index
        if self._peek() == "0" and self._peek(1) in {"x", "X"}:
            self._advance(2)
            while self._peek().isalnum() or self._peek() == "_":
                self._advance()
        else:
            while self._peek().isdigit() or self._peek() in {"_", "."}:
                self._advance()
        if self._peek() in {"e", "E", "p", "P"}:
            self._advance()
            if self._peek() in {"+", "-"}:
                self._advance()
            while self._peek().isdigit() or self._peek() == "_":
                self._advance()
        return self.source[start:self.index]

    def _read_string(self, quote: str) -> str:
        self._advance()  # consume opening quote already handled in caller? adjust
        start_line, start_col = self.line, self.column
        chars: List[str] = []
        while True:
            if self.index >= self.length:
                raise SyntaxError("Unterminated string", start_line, start_col)
            ch = self._peek()
            if ch == "\\":
                self._advance()
                escape = self._peek()
                if escape == "":
                    raise SyntaxError("Unterminated escape sequence", self.line, self.column)
                chars.append("\\" + escape)
                self._advance()
                continue
            if ch == quote:
                self._advance()
                break
            self._advance()
            chars.append(ch)
        return "".join(chars)


class Parser:
    def __init__(self, tokens: Sequence[Token]):
        self.tokens = list(tokens)
        self.index = 0

    def parse(self) -> None:
        while not self._check("EOF"):
            self._statement()
        self._consume("EOF", "Expected end of chunk")

    def _current(self) -> Token:
        return self.tokens[self.index]

    def _check(self, token_type: str, value: Optional[str] = None) -> bool:
        tok = self._current()
        if tok.type != token_type:
            return False
        if value is not None and tok.value != value:
            return False
        return True

    def _advance(self) -> Token:
        tok = self._current()
        if tok.type != "EOF":
            self.index += 1
        return tok

    def _consume(self, token_type: str, message: str) -> Token:
        if self._check(token_type):
            return self._advance()
        tok = self._current()
        raise SyntaxError(message, tok.line, tok.column)

    def _match(self, *token_types: str) -> bool:
        if self._check_any(token_types):
            self._advance()
            return True
        return False

    def _check_any(self, token_types: Sequence[str]) -> bool:
        tok = self._current()
        return tok.type in token_types

    # Parsing helpers

    def _statement(self) -> None:
        if self._match("SEMICOLON"):
            return
        tok = self._current()
        if tok.type == "KW_IF":
            self._advance()
            self._expression()
            self._consume("KW_THEN", "Expected 'then' after if condition")
            self._block({"KW_END", "KW_ELSE", "KW_ELSEIF"})
            while self._match("KW_ELSEIF"):
                self._expression()
                self._consume("KW_THEN", "Expected 'then' after elseif condition")
                self._block({"KW_END", "KW_ELSE", "KW_ELSEIF"})
            if self._match("KW_ELSE"):
                self._block({"KW_END"})
            self._consume("KW_END", "Expected 'end' to close if")
            return
        if tok.type == "KW_WHILE":
            self._advance()
            self._expression()
            self._consume("KW_DO", "Expected 'do' after while condition")
            self._block({"KW_END"})
            self._consume("KW_END", "Expected 'end' after while block")
            return
        if tok.type == "KW_DO":
            self._advance()
            self._block({"KW_END"})
            self._consume("KW_END", "Expected 'end' after do block")
            return
        if tok.type == "KW_REPEAT":
            self._advance()
            self._block({"KW_UNTIL"})
            self._consume("KW_UNTIL", "Expected 'until' to close repeat")
            self._expression()
            return
        if tok.type == "KW_FOR":
            self._advance()
            self._consume("NAME", "Expected identifier after 'for'")
            if self._check("COLON"):
                self._skip_type_annotation({"COMMA", "KW_IN", "KW_DO"}, stop_on_name=False)
            if self._match("ASSIGN"):
                self._expression()
                self._consume("COMMA", "Expected ',' in numeric for")
                self._expression()
                if self._match("COMMA"):
                    self._expression()
                self._consume("KW_DO", "Expected 'do' after for range")
                self._block({"KW_END"})
                self._consume("KW_END", "Expected 'end' after for loop")
            else:
                while self._match("COMMA"):
                    self._consume("NAME", "Expected identifier in for-in list")
                    if self._check("COLON"):
                        self._skip_type_annotation({"COMMA", "KW_IN"}, stop_on_name=False)
                self._consume("KW_IN", "Expected 'in' in for-in loop")
                self._expression_list()
                self._consume("KW_DO", "Expected 'do' after for-in iterator")
                self._block({"KW_END"})
                self._consume("KW_END", "Expected 'end' after for-in loop")
            return
        if tok.type == "KW_FUNCTION":
            self._advance()
            self._function_statement()
            return
        if tok.type == "KW_LOCAL":
            self._advance()
            self._local_statement()
            return
        if tok.type == "KW_RETURN":
            self._advance()
            if not self._check("KW_END") and not self._check("KW_ELSE") and not self._check("KW_ELSEIF") and not self._check("KW_UNTIL") and not self._check("EOF"):
                self._expression_list()
            return
        if tok.type == "KW_BREAK" or tok.type == "KW_CONTINUE":
            self._advance()
            return
        if tok.type == "KW_GOTO":
            self._advance()
            self._consume("NAME", "Expected label name after 'goto'")
            return
        if tok.type == "DOUBLECOLON":
            self._advance()
            self._consume("NAME", "Expected label name after '::'")
            self._consume("DOUBLECOLON", "Expected closing '::' for label")
            return
        if tok.type == "KW_EXPORT":
            self._advance()
            self._export_statement()
            return
        if tok.type == "NAME" and tok.value == "type":
            self._advance()
            self._type_alias(False)
            return
        self._assignment_or_call()

    def _block(self, end_tokens: set[str]) -> None:
        while not self._check_any(tuple(end_tokens)) and not self._check("EOF"):
            self._statement()

    def _function_statement(self) -> None:
        self._function_name()
        self._function_generic_params_optional()
        self._function_body()

    def _function_name(self) -> None:
        self._consume("NAME", "Expected function name")
        while self._match("DOT"):
            self._consume("NAME", "Expected field name after '.'")
        if self._match("COLON"):
            self._consume("NAME", "Expected method name after ':'")

    def _function_generic_params_optional(self) -> None:
        if self._match("LT"):
            depth = 1
            while depth > 0:
                tok = self._advance()
                if tok.type == "ELLIPSIS":
                    if self._check("NAME"):
                        self._advance()
                    continue
                if tok.type == "NAME":
                    continue
                if tok.type == "COMMA":
                    continue
                if tok.type == "GT":
                    depth -= 1
                    if depth == 0:
                        break
                elif tok.type == "LT":
                    depth += 1
                else:
                    raise SyntaxError("Unexpected token in generic parameter list", tok.line, tok.column)
            if depth != 0:
                tok = self._current()
                raise SyntaxError("Unterminated generic parameter list", tok.line, tok.column)

    def _function_body(self) -> None:
        self._consume("LPAREN", "Expected '(' to start parameter list")
        if not self._check("RPAREN"):
            while True:
                if self._match("ELLIPSIS"):
                    if self._check("NAME"):
                        self._advance()
                    if self._check("COLON"):
                        self._skip_type_annotation({"RPAREN", "COMMA"}, stop_on_name=False)
                    break
                self._consume("NAME", "Expected parameter name")
                if self._check("COLON"):
                    self._skip_type_annotation({"COMMA", "RPAREN"}, stop_on_name=False)
                if not self._match("COMMA"):
                    break
        self._consume("RPAREN", "Expected ')' after parameters")
        if self._check("COLON"):
            self._skip_type_annotation({"KW_END", "KW_LOCAL", "KW_IF", "KW_FOR", "KW_WHILE", "KW_REPEAT", "KW_RETURN", "KW_FUNCTION", "KW_DO", "KW_BREAK", "KW_CONTINUE", "KW_GOTO", "SEMICOLON", "EOF"}, stop_on_name=True)
        self._block({"KW_END"})
        self._consume("KW_END", "Expected 'end' after function body")

    def _local_statement(self) -> None:
        if self._match("KW_FUNCTION"):
            self._consume("NAME", "Expected function name")
            self._function_generic_params_optional()
            self._function_body()
            return
        if self._check("NAME") and self._current().value == "type":
            self._advance()
            self._type_alias(True)
            return
        names = []
        while True:
            names.append(self._consume("NAME", "Expected local variable name"))
            if self._check("COLON"):
                local_stop_tokens = {
                    "COMMA",
                    "ASSIGN",
                    "KW_LOCAL",
                    "KW_FUNCTION",
                    "KW_IF",
                    "KW_FOR",
                    "KW_WHILE",
                    "KW_REPEAT",
                    "KW_RETURN",
                    "KW_BREAK",
                    "KW_CONTINUE",
                    "KW_GOTO",
                    "KW_END",
                    "KW_ELSE",
                    "KW_ELSEIF",
                    "KW_UNTIL",
                    "KW_EXPORT",
                }
                self._skip_type_annotation(local_stop_tokens, stop_on_name=True)
            if not self._match("COMMA"):
                break
        if self._match("ASSIGN"):
            self._expression_list()

    def _export_statement(self) -> None:
        if self._check("NAME") and self._current().value == "type":
            self._advance()
            self._type_alias(False)
            return
        tok = self._current()
        raise SyntaxError("Only 'export type' statements are supported", tok.line, tok.column)

    def _type_alias(self, is_local: bool) -> None:
        self._consume("NAME", "Expected type name")
        if self._match("LT"):
            depth = 1
            while depth > 0:
                tok = self._advance()
                if tok.type == "ELLIPSIS":
                    if self._check("NAME"):
                        self._advance()
                    continue
                if tok.type == "NAME":
                    continue
                if tok.type == "COMMA":
                    continue
                if tok.type == "GT":
                    depth -= 1
                    if depth == 0:
                        break
                elif tok.type == "LT":
                    depth += 1
                else:
                    raise SyntaxError("Unexpected token in type parameter list", tok.line, tok.column)
        self._consume("ASSIGN", "Expected '=' in type definition")
        self._skip_type_expression()

    def _skip_type_expression(self) -> None:
        stop_tokens = {
            "SEMICOLON",
            "KW_LOCAL",
            "KW_FUNCTION",
            "KW_IF",
            "KW_FOR",
            "KW_WHILE",
            "KW_REPEAT",
            "KW_RETURN",
            "KW_BREAK",
            "KW_CONTINUE",
            "KW_GOTO",
            "KW_EXPORT",
            "KW_END",
        }
        self._skip_balanced(stop_tokens, allow_suffix=False, stop_on_name=True)

    def _skip_type_annotation(self, stop_tokens: set[str], *, stop_on_name: bool) -> None:
        self._consume("COLON", "Expected ':' for type annotation")
        self._skip_balanced(stop_tokens, allow_suffix=False, stop_on_name=stop_on_name)

    def _skip_balanced(self, stop_tokens: set[str], *, allow_suffix: bool, stop_on_name: bool) -> None:
        depth_stack: List[str] = []
        end_tokens = {
            "NAME",
            "NUMBER",
            "STRING",
            "KW_NIL",
            "KW_TRUE",
            "KW_FALSE",
            "RBRACE",
            "RBRACKET",
            "RPAREN",
            "QUESTION",
            "GT",
            "ELLIPSIS",
        }
        last_type: Optional[str] = None
        while True:
            tok = self._current()
            if tok.type == "EOF":
                return
            if not depth_stack:
                if tok.type in stop_tokens or tok.type in EXPR_BOUNDARY_TOKENS:
                    return
                if allow_suffix and tok.type in SUFFIX_BOUNDARY_TOKENS and last_type in end_tokens:
                    return
                if stop_on_name and tok.type == "NAME" and last_type in end_tokens:
                    return
            self._advance()
            last_type = tok.type
            if tok.type in {"LPAREN", "LBRACE", "LBRACKET"}:
                depth_stack.append(tok.type)
            elif tok.type == "LT":
                depth_stack.append("LT")
            elif tok.type == "RPAREN":
                if depth_stack and depth_stack[-1] == "LPAREN":
                    depth_stack.pop()
            elif tok.type == "RBRACE":
                if depth_stack and depth_stack[-1] == "LBRACE":
                    depth_stack.pop()
            elif tok.type == "RBRACKET":
                if depth_stack and depth_stack[-1] == "LBRACKET":
                    depth_stack.pop()
            elif tok.type == "GT":
                if depth_stack and depth_stack[-1] == "LT":
                    depth_stack.pop()

    def _assignment_or_call(self) -> None:
        targets = []
        first = self._prefix_expression()
        targets.append(first)
        while self._match("COMMA"):
            targets.append(self._prefix_expression())
        if self._match("ASSIGN"):
            self._expression_list()
            return
        next_type = self._current().type
        compound_ops = {
            "PLUS",
            "MINUS",
            "MUL",
            "DIV",
            "FLOORDIV",
            "MOD",
            "POW",
            "CONCAT",
            "SHL",
            "SHR",
            "BITAND",
            "BITOR",
            "AMP",
            "PIPE",
        }
        if next_type in compound_ops and self._peek_type() == "ASSIGN":
            self._advance()  # operator
            self._advance()  # '='
            self._expression()
            return
        # expression statement must end with call
        if not first.is_call or len(targets) > 1:
            tok = self._current()
            raise SyntaxError("Expected function call in statement", tok.line, tok.column)

    def _expression_list(self) -> None:
        self._expression()
        while self._match("COMMA"):
            self._expression()

    def _expression(self) -> None:
        if self._check("KW_IF"):
            self._advance()
            self._expression()
            self._consume("KW_THEN", "Expected 'then' in if expression")
            self._expression()
            self._consume("KW_ELSE", "Expected 'else' in if expression")
            self._expression()
            return
        self._or_expression()

    def _or_expression(self) -> None:
        self._and_expression()
        while self._match("KW_OR"):
            self._and_expression()

    def _and_expression(self) -> None:
        self._comparison_expression()
        while self._match("KW_AND"):
            self._comparison_expression()

    def _comparison_expression(self) -> None:
        self._bitwise_or_expression()
        while self._match("LT", "LE", "GT", "GE", "EQ", "NE"):
            self._bitwise_or_expression()

    def _bitwise_or_expression(self) -> None:
        self._bitwise_xor_expression()
        while self._match("BITOR", "PIPE"):
            self._bitwise_xor_expression()

    def _bitwise_xor_expression(self) -> None:
        self._bitwise_and_expression()
        while self._match("BITXOR"):
            self._bitwise_and_expression()

    def _bitwise_and_expression(self) -> None:
        self._shift_expression()
        while self._match("BITAND", "AMP"):
            self._shift_expression()

    def _shift_expression(self) -> None:
        self._concat_expression()
        while self._match("SHL", "SHR"):
            self._concat_expression()

    def _concat_expression(self) -> None:
        self._add_expression()
        while self._match("CONCAT"):
            self._add_expression()

    def _add_expression(self) -> None:
        self._mul_expression()
        while self._match("PLUS", "MINUS"):
            self._mul_expression()

    def _mul_expression(self) -> None:
        self._unary_expression()
        while self._match("MUL", "DIV", "FLOORDIV", "MOD"):
            self._unary_expression()

    def _unary_expression(self) -> None:
        if self._match("KW_NOT", "MINUS", "LEN", "BITNOT"):
            self._unary_expression()
        else:
            self._power_expression()

    def _power_expression(self) -> None:
        self._primary_expression()
        while self._match("POW"):
            self._unary_expression()

    def _primary_expression(self) -> None:
        tok = self._current()
        if tok.type == "NUMBER" or tok.type == "STRING" or tok.type in {"KW_NIL", "KW_TRUE", "KW_FALSE"}:
            self._advance()
            return
        if tok.type == "ELLIPSIS":
            self._advance()
            return
        if tok.type == "KW_FUNCTION":
            self._advance()
            self._function_generic_params_optional()
            self._function_body()
            return
        if tok.type == "LBRACE":
            self._table_constructor()
            return
        if tok.type == "LPAREN":
            self._advance()
            self._expression()
            self._consume("RPAREN", "Expected ')' to close expression")
            self._suffix_expression(allow_call=True)
            return
        if tok.type == "NAME" or tok.type == "KW_IF":
            if tok.type == "KW_IF":
                # Expression handled earlier, unreachable
                pass
            self._advance()
            self._suffix_expression(allow_call=True)
            return
        raise SyntaxError("Unexpected expression", tok.line, tok.column)

    def _suffix_expression(self, allow_call: bool) -> None:
        is_call = False
        while True:
            tok = self._current()
            if tok.type == "LBRACKET":
                self._advance()
                self._expression()
                self._consume("RBRACKET", "Expected ']' after indexing expression")
                continue
            if tok.type == "DOT":
                self._advance()
                self._consume("NAME", "Expected field name after '.'")
                continue
            if tok.type == "COLON":
                self._advance()
                self._consume("NAME", "Expected method name after ':'")
                self._parse_args()
                is_call = True
                continue
            if tok.type in {"LPAREN", "LBRACE", "STRING"}:
                self._parse_args()
                is_call = True
                continue
            if tok.type == "DOUBLECOLON":
                self._advance()
                self._skip_balanced({"COMMA", "RPAREN", "RBRACKET", "RBRACE"}, allow_suffix=True, stop_on_name=True)
                continue
            break
        if allow_call and not is_call:
            # For expression statement detection we need to know if last suffix included call.
            pass
        self._last_suffix_is_call = is_call

    def _parse_args(self) -> None:
        tok = self._current()
        if tok.type == "LPAREN":
            self._advance()
            if not self._check("RPAREN"):
                self._expression_list()
            self._consume("RPAREN", "Expected ')' after arguments")
        elif tok.type == "LBRACE":
            self._table_constructor()
        elif tok.type == "STRING":
            self._advance()
        else:
            raise SyntaxError("Invalid argument list", tok.line, tok.column)

    def _table_constructor(self) -> None:
        self._consume("LBRACE", "Expected '{' for table constructor")
        if not self._check("RBRACE"):
            while True:
                if self._match("LBRACKET"):
                    self._expression()
                    self._consume("RBRACKET", "Expected ']' in table constructor")
                    if self._match("ASSIGN"):
                        self._expression()
                    elif self._check("COLON"):
                        self._skip_type_annotation({"COMMA", "RBRACE"}, stop_on_name=False)
                    else:
                        raise SyntaxError("Expected '=' or ':' after table key", self._current().line, self._current().column)
                elif self._check("NAME") and self._peek_type() in {"ASSIGN", "COLON"}:
                    self._advance()
                    if self._match("ASSIGN"):
                        self._expression()
                    else:
                        self._skip_type_annotation({"COMMA", "RBRACE"}, stop_on_name=False)
                else:
                    self._expression()
                if self._match("COMMA", "SEMICOLON"):
                    if self._check("RBRACE"):
                        break
                    next_type = self._current().type
                    if next_type in {
                        "KW_LOCAL",
                        "KW_FUNCTION",
                        "KW_IF",
                        "KW_FOR",
                        "KW_WHILE",
                        "KW_REPEAT",
                        "KW_RETURN",
                        "KW_BREAK",
                        "KW_CONTINUE",
                        "KW_GOTO",
                        "KW_EXPORT",
                    } or (next_type == "NAME" and self._current().value == "type"):
                        break
                else:
                    break
        self._consume("RBRACE", "Expected '}' after table constructor")

    def _peek_type(self) -> str:
        if self.index + 1 < len(self.tokens):
            return self.tokens[self.index + 1].type
        return "EOF"

    def _prefix_expression(self):
        start_index = self.index
        self._last_suffix_is_call = False
        if self._match("LPAREN"):
            self._expression()
            self._consume("RPAREN", "Expected ')' in expression")
        elif self._match("NAME"):
            pass
        else:
            tok = self._current()
            raise SyntaxError("Expected expression", tok.line, tok.column)
        self._suffix_expression(allow_call=True)
        is_call = self._last_suffix_is_call
        class Target:
            def __init__(self, is_call: bool) -> None:
                self.is_call = is_call
        return Target(is_call)


def load_scripts(bundle_path: Path) -> List[tuple[str, str]]:
    with bundle_path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    entries: List[tuple[str, str]] = []
    if isinstance(data, list):
        for item in data:
            if not isinstance(item, dict):
                continue
            path = item.get("path") or item.get("name")
            content = item.get("content")
            if isinstance(path, str) and isinstance(content, str):
                entries.append((path, content))
    elif isinstance(data, dict):
        if "files" in data and isinstance(data["files"], list):
            for item in data["files"]:
                if not isinstance(item, dict):
                    continue
                path = item.get("path")
                content = item.get("content")
                if isinstance(path, str) and isinstance(content, str):
                    entries.append((path, content))
        else:
            for key, value in data.items():
                if isinstance(key, str) and isinstance(value, str):
                    entries.append((key, value))
    return entries


def build_snippet(source: str, error_line: int, context: int = 2) -> str:
    lines = source.splitlines()
    start = max(error_line - 1 - context, 0)
    end = min(error_line - 1 + context, len(lines) - 1)
    snippet_lines = []
    for idx in range(start, end + 1):
        prefix = "> " if idx == error_line - 1 else "  "
        snippet_lines.append(f"{prefix}{idx + 1:4d}: {lines[idx]}")
    return "\n".join(snippet_lines)


def analyze_script(path: str, source: str) -> Optional[dict]:
    try:
        lexer = Lexer(source)
        tokens = list(lexer.tokens())
        parser = Parser(tokens)
        parser.parse()
        return None
    except SyntaxError as exc:  # type: ignore[misc]
        snippet = build_snippet(source, exc.line)
        return {
            "path": path,
            "line": exc.line,
            "message": exc.message,
            "snippet": snippet,
        }


def main(argv: Sequence[str]) -> int:
    if len(argv) < 3:
        print("Usage: luau_syntax_checker.py <bundle.json> <report.json>", file=sys.stderr)
        return 1
    bundle_path = Path(argv[1])
    report_path = Path(argv[2])
    scripts = load_scripts(bundle_path)
    diagnostics = []
    for path, source in scripts:
        result = analyze_script(path, source)
        if result is not None:
            diagnostics.append(result)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    if diagnostics:
        with report_path.open("w", encoding="utf-8") as handle:
            json.dump(diagnostics, handle, indent=2)
            handle.write("\n")
    else:
        with report_path.open("w", encoding="utf-8") as handle:
            handle.write("Scan complete. 0 issue(s) found.\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
