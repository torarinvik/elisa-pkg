# Repository instructions

- Keep every source file at or below 600 lines. Split larger files by responsibility.
- Organize code into subfolder whenever a folder contains more than 20 files
- Regularly clean up repo to make it look as professional as possible
- Make sure documentation is up to date at all time
- Do not commit temporary scripts or temporary documentation.

* Use expression based style that can be enforced by the compiler such as loop expressions and block expressions, firs consider comprehensions like array comprehensions, when they aren't flexible enough use expression based loops
* Use modules including submodules with good public/private hygiene

* Make sure functions are reasonably sized and no larger than necessary
* Keep total amount of struct fields less than 20, split up and prefer composition with more is needed
* Avoid abbreviations, use explicit names eg. instead of mat_expr use matrix_expression.
* Make all code as readable as possible, the code should be easy for people to understand that have no knowledge of the codebase or what the code does
* Use refinement types and dafny style contracts on all code unless they obviously have no use for it.
* Prefer reusable refinement types rather than anonymous refinement types unless they are only to be used once
* Use # for single line comments and """ for multi line comments
* Prefer zero overhead threading of mutable datatypes instead of in place mutation of mutable references
  * def foo(an_array: mutable darray[u8]) ->  darray[u8]

* Use block expressions to encapsulate data

* Use the -Wnever-leak=strict compiler flag
