import re
from typing import Any


class ContainsMixin(dict):
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
        """
        for key, expected in sorted(other.items()):
            assert key in self, f"self[{key!r}] is missing"
            value = self[key]
            message = f"{{{key!r}: {value!r}}} != {{{key!r}: {expected!r}}}"
            if isinstance(expected, dict):
                assert isinstance(value, dict), message
                assert self.__class__(value).contains(expected)
            elif isinstance(expected, set):
                assert set(value) == expected, message
            elif isinstance(expected, re.Pattern):
                assert expected.search(value), message
            else:
                assert value == expected, message
        return True
