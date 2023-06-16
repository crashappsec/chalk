# dummy comment first line
import json


class Person:
    name: str
    age: int

    def __init__(self, name: str, age: int):
        self.name = name
        self.age = age

    def hello(self):
        print("hello my name is %s", self.name)

    def toJson(self) -> str:
        return json.dumps(
            self,
            default=lambda o: o.__dict__,
        )
