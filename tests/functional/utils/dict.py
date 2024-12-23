# Copyright (c) 2023-2024, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import itertools
import operator
import re
from datetime import datetime
from typing import Any, Callable, Iterable, Optional, cast


ANY = object()
MISSING = object()


class Iso8601:
    def __eq__(self, other: Any):
        if isinstance(other, datetime):
            return True
        try:
            datetime.fromisoformat(other)
        except ValueError:
            return False
        else:
            return True


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


class Values:
    def __init__(self, values: Any):
        self.values = values

    def __repr__(self):
        return f"{self.__class__.__name__}({self.values!r})"


class Contains:
    def __init__(self, items: set[Any] | list[Any]):
        self.items = ContainsList(items)

    def __repr__(self):
        return f"{self.__class__.__name__}({self.items!r})"

    def __eq__(self, others: Any):
        def check(expected, others):
            if isinstance(expected, ContainsMixin):
                errors = []
                for other in others:
                    try:
                        return SubsetCompare(expected) == other
                    except AssertionError as e:
                        errors.append(str(e))
                raise AssertionError(errors)
            else:
                return expected in others

        return all(check(i, others) for i in self.items)


class IfExists:
    def __init__(self, value: Any):
        self.value = value

    def __repr__(self):
        return f"{self.__class__.__name__}({self.value!r})"


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
            try:
                eq = self.expected == value
            except AssertionError as e:
                raise AssertionError(self._message_why("", str(e))) from e
            else:
                assert eq, self._message_ne(value)
        elif isinstance(self.expected, Values):
            assert isinstance(value, dict), self._message_ne(value)
            values = list(value.values())
            assert (
                self.__class__(self.expected.values, f"Values({self.path})") == values
            )
        elif isinstance(self.expected, Iso8601):
            assert self.expected == value, self._message_ne(value)
        else:
            assert value == self.expected, self._message_ne(value)
        return True

    def __contains__(self, item: Any) -> bool:
        for i in cast(Iterable[Any], self):
            if i == item:
                return True
        return False


class ContainsMixin:
    def has(self, **kwargs: Any):
        """
        >>> ContainsDict({"foo": "bar"}).has(foo="bar")
        True
        """
        return self.contains(kwargs)

    def contains(self, other: dict[Any, Any]):
        """
        >>> ContainsDict({"foo": "bar"}).contains({"foo": "bar"})
        True
        >>> ContainsDict({"foo": "bar"}).contains({"foo": "baz"})
        Traceback (most recent call last):
        ...
        AssertionError: ['foo']: 'bar' != 'baz'

        >>> ContainsDict({"foo": "baz"}).contains({"foo": re.compile(r"z$")})
        True
        >>> ContainsDict({"foo": "bar"}).contains({"foo": re.compile(r"z$")})
        Traceback (most recent call last):
        ...
        AssertionError: ['foo']: 'bar' != re.compile('z$')

        >>> ContainsDict({"foo": "bar"}).contains({"foo": {"bar": "baz"}})
        Traceback (most recent call last):
        ...
        AssertionError: ['foo']: 'bar' != {'bar': 'baz'}

        >>> ContainsDict({"foo": [2, 1]}).contains({"foo": {1, 2}})
        True
        >>> ContainsDict({"foo": [2, 1]}).contains({"foo": {1, 2, 3}})
        Traceback (most recent call last):
        ...
        AssertionError: ['foo']: [2, 1] != {1, 2, 3}

        >>> ContainsDict({"foo": "bar"}).contains({"foo": ANY})
        True
        >>> ContainsDict({"foo": "bar"}).contains({"bar": MISSING})
        True

        >>> ContainsDict({"foo": ["bar"]}).contains({"foo": Length(1)})
        True
        >>> ContainsDict({"foo": ["bar"]}).contains({"foo": Length(1, operator.gt)})
        Traceback (most recent call last):
        ...
        AssertionError: ['foo']: ['bar'] != Length(>1)

        >>> ContainsDict({"foo": "bar"}).contains({"bar": IfExists("bar")})
        True
        >>> ContainsDict({"foo": "bar"}).contains({"foo": IfExists("bar")})
        True
        >>> ContainsDict({"foo": "bar"}).contains({"foo": IfExists("baz")})
        Traceback (most recent call last):
        ...
        AssertionError: ['foo']: 'bar' != 'baz'

        >>> ContainsDict({"foo": ["bar", "baz"]}).contains({"foo": Contains({"bar"})})
        True
        >>> ContainsDict({"foo": ["bar", "baz"]}).contains({"foo": Contains({"foobar"})})
        Traceback (most recent call last):
        ...
        AssertionError: ['foo']: ['bar', 'baz'] != Contains(['foobar'])

        >>> ContainsDict({"foo": [{1: 2}, {1: 2, "bar": "baz"}]}).contains({"foo": Contains([{"bar": "baz"}])})
        True
        >>> ContainsDict({"foo": [{1: 2}, {1: 2, "bar": "baz"}]}).contains({"foo": Contains([{"baz": "baz"}])})
        Traceback (most recent call last):
        ...
        AssertionError: ['foo']: ["['baz']: is missing", "['baz']: is missing"]
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

    @classmethod
    def as_contains(cls, x: Any):
        if isinstance(x, (ContainsDict, ContainsList)):
            return x
        elif isinstance(x, dict):
            return ContainsDict(x)
        elif isinstance(x, list):
            return [cls.as_contains(i) for i in x]
        else:
            return x


class ContainsDict(ContainsMixin, dict): ...


class ContainsList(ContainsMixin, list):
    def __init__(self, items: Optional[Iterable[Any]] = None):
        super().__init__([ContainsMixin.as_contains(i) for i in items or []])
