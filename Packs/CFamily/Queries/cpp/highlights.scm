; Generic identifier fallback
(identifier) @variable

; Constants (UPPERCASE pattern)
((identifier) @constant
 (#match? @constant "^[A-Z][A-Z\\d_]*$"))

; C Keywords
"break" @keyword
"case" @keyword
"const" @keyword
"continue" @keyword
"default" @keyword
"do" @keyword
"else" @keyword
"enum" @keyword
"extern" @keyword
"for" @keyword
"if" @keyword
"inline" @keyword
"return" @keyword
"sizeof" @keyword
"static" @keyword
"struct" @keyword
"switch" @keyword
"typedef" @keyword
"union" @keyword
"volatile" @keyword
"while" @keyword

; C++ Specific Keywords
[
 "catch"
 "class"
 "co_await"
 "co_return"
 "co_yield"
 "constexpr"
 "constinit"
 "consteval"
 "delete"
 "explicit"
 "final"
 "friend"
 "mutable"
 "namespace"
 "noexcept"
 "new"
 "override"
 "private"
 "protected"
 "public"
 "template"
 "throw"
 "try"
 "typename"
 "using"
 "concept"
 "requires"
 "virtual"
 "import"
 "export"
 "module"
] @keyword

; Preprocessor Directives
"#define" @keyword
"#elif" @keyword
"#else" @keyword
"#endif" @keyword
"#if" @keyword
"#ifdef" @keyword
"#ifndef" @keyword
"#include" @keyword
(preproc_directive) @keyword

; Operators
"--" @operator
"-" @operator
"-=" @operator
"->" @operator
"=" @operator
"!=" @operator
"*" @operator
"&" @operator
"&&" @operator
"+" @operator
"++" @operator
"+=" @operator
"<" @operator
"==" @operator
">" @operator
"||" @operator

; Delimiters
"." @delimiter
";" @delimiter

; Strings and Numbers
(string_literal) @string
(system_lib_string) @string
(raw_string_literal) @string
(null) @constant
(null "nullptr" @constant)
(number_literal) @number
(char_literal) @number

; Types
(field_identifier) @property
(statement_identifier) @label
(type_identifier) @type
(primitive_type) @type
(sized_type_specifier) @type
(auto) @type

; Namespace identifiers that start with uppercase (like type names)
((namespace_identifier) @type
 (#match? @type "^[A-Z]"))

; Built-in variables
(this) @variable.builtin

; Functions - C patterns
(call_expression
  function: (identifier) @function)
(call_expression
  function: (field_expression
    field: (field_identifier) @function))
(function_declarator
  declarator: (identifier) @function)
(preproc_function_def
  name: (identifier) @function.special)
(preproc_def
  name: (identifier) @constant)

; Functions - C++ specific patterns
(call_expression
  function: (qualified_identifier
    name: (identifier) @function))

(template_function
  name: (identifier) @function)

(template_method
  name: (field_identifier) @function)

(function_declarator
  declarator: (qualified_identifier
    name: (identifier) @function))

(function_declarator
  declarator: (field_identifier) @function)

; Modules
(module_name
  (identifier) @module)

; Comments
(comment) @comment
