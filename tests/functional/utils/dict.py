# Copyright (c) 2023-2024, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import itertools
import operator
import re
from typing import Any, Callable, Optional


ANY = object()
MISSING = object()


class Length:
    pretty = {
        "eq": "==",
        "gt": ">",
        "ge": ">=",
        "lt": "<",
        "le": "<=",
    }

    def __init__(self, size: int, op: Callable[[Any, Any], bool] = operator.eq):
        self.size = size
        self.op = op

    def __repr__(self):
        return f"{self.__class__.__name__}({self.pretty.get(self.op.__name__, '')}{self.size})"

    def __eq__(self, other: Any):
        return self.op(len(other), self.size)


class Contains:
    def __init__(self, items: set[Any]):
        self.items = items

    def __repr__(self):
        return f"{self.__class__.__name__}({self.items!r})"

    def __eq__(self, other: Any):
        return all(i in other for i in self.items)


class IfExists:
    def __init__(self, value: Any):
        self.value = value


class SubsetCompare:
    def __init__(self, expected: Any, path: Optional[str] = None):
        self.expected = expected
        self.path = path or ""

    def _message_ne(self, value: Any) -> str:
        message = ""
        if self.path:
            message = f"{self.path}: "
        return f"{message}{value!r} != {self.expected!r}"

    def _message_why(self, path: str, description: str) -> str:
        return f"{self.path}{path}: {description}"

    def __eq__(self, value: Any) -> bool:
        if self.expected is ANY:
            return True
        elif isinstance(self.expected, type):
            assert isinstance(value, self.expected), self._message_ne(value)
        elif isinstance(self.expected, dict):
            # TODO
            assert isinstance(value, dict), self._message_ne(value)
            for k, e in self.expected.items():
                path = f"[{k!r}]"
                if e is MISSING:
                    assert k not in value, self._message_why(path, "should be missing")
                    continue
                elif isinstance(e, IfExists):
                    if k not in value:
                        continue
                    e = e.value
                assert k in value, self._message_why(path, "is missing")
                assert self.__class__(e, self.path + path) == value[k]
        elif isinstance(self.expected, list):
            assert isinstance(value, list), self._message_ne(value)
            for i, (e, v) in enumerate(itertools.zip_longest(self.expected, value)):
                assert self.__class__(e, self.path + f"[{i}]") == v
        elif isinstance(self.expected, set):
            assert set(value) == self.expected, self._message_ne(value)
        elif isinstance(self.expected, re.Pattern):
            assert isinstance(value, str), self._message_ne(value)
            assert self.expected.search(value), self._message_ne(value)
        elif isinstance(self.expected, (Length, Contains)):
            assert self.expected == value, self._message_ne(value)
        else:
            assert value == self.expected, self._message_ne(value)

        return True


class ContainsMixin(dict):
    def has(self, **kwargs: Any):
        """
        >>> ContainsMixin({"foo": "bar"}).has(foo="bar")
        True
        """
        return self.contains(kwargs)

    def contains(self, other: dict[Any, Any]):
        """
        >>> ContainsMixin({"foo": "bar"}).contains({"foo": "bar"})
        True
        >>> ContainsMixin({"foo": "bar"}).contains({"foo": "baz"})
        Traceback (most recent call last):
        ...
        AssertionError: ['foo']: 'bar' != 'baz'

        >>> ContainsMixin({"foo": "baz"}).contains({"foo": re.compile(r"z$")})
        True
        >>> ContainsMixin({"foo": "bar"}).contains({"foo": re.compile(r"z$")})
        Traceback (most recent call last):
        ...
        AssertionError: ['foo']: 'bar' != re.compile('z$')

        >>> ContainsMixin({"foo": "bar"}).contains({"foo": {"bar": "baz"}})
        Traceback (most recent call last):
        ...
        AssertionError: ['foo']: 'bar' != {'bar': 'baz'}

        >>> ContainsMixin({"foo": [2, 1]}).contains({"foo": {1, 2}})
        True
        >>> ContainsMixin({"foo": [2, 1]}).contains({"foo": {1, 2, 3}})
        Traceback (most recent call last):
        ...
        AssertionError: ['foo']: [2, 1] != {1, 2, 3}

        >>> ContainsMixin({"foo": "bar"}).contains({"foo": ANY})
        True
        >>> ContainsMixin({"foo": "bar"}).contains({"bar": MISSING})
        True

        >>> ContainsMixin({"foo": ["bar"]}).contains({"foo": Length(1)})
        True
        >>> ContainsMixin({"foo": ["bar"]}).contains({"foo": Length(1, operator.gt)})
        Traceback (most recent call last):
        ...
        AssertionError: ['foo']: ['bar'] != Length(>1)

        >>> ContainsMixin({"foo": "bar"}).contains({"bar": IfExists("bar")})
        True
        >>> ContainsMixin({"foo": "bar"}).contains({"foo": IfExists("bar")})
        True
        >>> ContainsMixin({"foo": "bar"}).contains({"foo": IfExists("baz")})
        Traceback (most recent call last):
        ...
        AssertionError: ['foo']: 'bar' != 'baz'

        >>> ContainsMixin({"foo": ["bar", "baz"]}).contains({"foo": Contains({"bar"})})
        True
        >>> ContainsMixin({"foo": ["bar", "baz"]}).contains({"foo": Contains({"foobar"})})
        Traceback (most recent call last):
        ...
        AssertionError: ['foo']: ['bar', 'baz'] != Contains({'foobar'})
        """
        return SubsetCompare(other, getattr(self, "name", None)) == self

    def contains_if(self, condition: bool, other: dict[Any, Any]):
        if condition:
            return self.contains(other)
        return True

    def has_if(self, condition: bool, **kwargs: Any):
        if condition:
            return self.has(**kwargs)
        return True
