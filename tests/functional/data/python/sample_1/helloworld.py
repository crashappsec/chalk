#!/usr/bin/env python
# dummy comment second line
def main():
    print("Hello World")
    # this is added for semgrep test
    test_var = "aaa"
    if test_var is "bbb":
        print("this should never print")


if __name__ == "__main__":
    main()
