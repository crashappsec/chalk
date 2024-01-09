# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import operator
import re
from typing import Any, Callable


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
        AssertionError: {'foo': 'bar'} != {'foo': 'baz'}

        >>> ContainsMixin({"foo": "baz"}).contains({"foo": re.compile(r"z$")})
        True
        >>> ContainsMixin({"foo": "bar"}).contains({"foo": re.compile(r"z$")})
        Traceback (most recent call last):
        ...
        AssertionError: {'foo': 'bar'} != {'foo': re.compile('z$')}

        >>> ContainsMixin({"foo": "bar"}).contains({"foo": {"bar": "baz"}})
        Traceback (most recent call last):
        ...
        AssertionError: {'foo': 'bar'} != {'foo': {'bar': 'baz'}}

        >>> ContainsMixin({"foo": [2, 1]}).contains({"foo": {1, 2}})
        True
        >>> ContainsMixin({"foo": [2, 1]}).contains({"foo": {1, 2, 3}})
        Traceback (most recent call last):
        ...
        AssertionError: {'foo': [2, 1]} != {'foo': {1, 2, 3}}

        >>> ContainsMixin({"foo": "bar"}).contains({"foo": ANY})
        True
        >>> ContainsMixin({"foo": "bar"}).contains({"bar": MISSING})
        True

        >>> ContainsMixin({"foo": ["bar"]}).contains({"foo": Length(1)})
        True
        >>> ContainsMixin({"foo": ["bar"]}).contains({"foo": Length(1, operator.gt)})
        Traceback (most recent call last):
        ...
        AssertionError: {'foo': ['bar']} != {'foo': Length(>1)}

        >>> ContainsMixin({"foo": "bar"}).contains({"bar": IfExists("bar")})
        True
        >>> ContainsMixin({"foo": "bar"}).contains({"foo": IfExists("bar")})
        True
        >>> ContainsMixin({"foo": "bar"}).contains({"foo": IfExists("baz")})
        Traceback (most recent call last):
        ...
        AssertionError: {'foo': 'bar'} != {'foo': 'baz'}

        >>> ContainsMixin({"foo": ["bar", "baz"]}).contains({"foo": Contains({"bar"})})
        True
        >>> ContainsMixin({"foo": ["bar", "baz"]}).contains({"foo": Contains({"foobar"})})
        Traceback (most recent call last):
        ...
        AssertionError: {'foo': ['bar', 'baz']} != {'foo': Contains({'foobar'})}
        """
        for key, expected in sorted(other.items()):
            value = self.get(key)
            if expected is MISSING:
                assert key not in self, f"{{{key!r}: {value!r}}} should be missing"
                continue
            elif isinstance(expected, IfExists):
                if key not in self:
                    continue
                expected = expected.value

            assert key in self, f"[{key!r}] is missing"
            value = self[key]
            message = f"{{{key!r}: {value!r}}} != {{{key!r}: {expected!r}}}"
            if expected is ANY:
                pass  # dont assert anything about the value
            elif isinstance(expected, type):
                assert isinstance(value, expected), message
            elif isinstance(expected, dict):
                assert isinstance(value, dict), message
                assert self.__class__(value).contains(expected)
            elif isinstance(expected, set):
                assert set(value) == expected, message
            elif isinstance(expected, re.Pattern):
                assert expected.search(value), message
            elif isinstance(expected, (Length, Contains)):
                assert expected == value, message
            else:
                assert value == expected, message
        return True

    def contains_if(self, condition: bool, other: dict[Any, Any]):
        if condition:
            return self.contains(other)
        return True

    def has_if(self, condition: bool, **kwargs: Any):
        if condition:
            return self.has(**kwargs)
        return True
