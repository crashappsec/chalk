#!/usr/bin/env python
import person

if __name__ == "__main__":
    p = person.Person(name="aaa", age=12)
    print(p.toJson())
