export const HIGHLIGHTS = `

(identifier) @variable


((identifier) @type
  (#lua-match? @type "^[A-Z]"))

((identifier) @constant
  (#lua-match? @constant "^_*[A-Z][A-Z%d_]*$"))

((identifier) @variable.builtin
  (#any-of? @variable.builtin
    "arguments" "module" "window" "document" "globalThis"
    "process" "exports" "require" "__dirname" "__filename"
    "self"))

((identifier) @type.builtin
  (#any-of? @type.builtin
    "Object" "Function" "Boolean" "Symbol" "Number" "Math" "Date" "String" "RegExp"
    "Map" "Set" "WeakMap" "WeakSet" "Promise" "Proxy" "Reflect" "Intl" "BigInt"
    "Array" "Buffer" "Pointer" "ArrayBuffer" "DataView"
    "Int8Array" "Uint8Array" "Uint8ClampedArray" "Int16Array" "Uint16Array"
    "Int32Array" "Uint32Array" "Float32Array" "Float64Array" "BigInt64Array" "BigUint64Array"
    "Error" "EvalError" "RangeError" "ReferenceError" "SyntaxError" "TypeError" "URIError"
    "URL" "URLSearchParams" "TextEncoder" "TextDecoder" "AbortController" "AbortSignal"
    "Blob" "File" "FileReader" "FormData" "Headers" "Request" "Response"
    "ReadableStream" "WritableStream" "TransformStream"
    "console" "JSON"))

((identifier) @function.builtin
  (#any-of? @function.builtin
    "eval" "isFinite" "isNaN" "parseFloat" "parseInt"
    "decodeURI" "decodeURIComponent" "encodeURI" "encodeURIComponent"
    "require"))

((identifier) @number
  (#any-of? @number "NaN" "Infinity"))


(type_identifier) @type

(primitive_type) @type.builtin

(metascript_type) @type.builtin

(type_annotation
  ":" @punctuation.delimiter)

(type_parameters
  [
    "<"
    ">"
  ] @punctuation.bracket)



(discriminated_variant
  key: (identifier) @variable.member)

(object_type_property
  name: (identifier) @variable.member)

(parenthesized_type
  [
    "("
    ")"
  ] @punctuation.bracket)

(generic_type
  (type_identifier) @type)

(array_type
  [
    "["
    "]"
  ] @punctuation.bracket)

(object_type
  [
    "{"
    "}"
  ] @punctuation.bracket)

(function_type
  "=>" @punctuation.special)

(function_type_parameter
  name: (identifier) @variable.parameter)


(function_declaration
  name: (_) @function)

(method_declaration
  name: (_) @function.method)

(function_declaration
  name: (identifier) @function.builtin
  (#lua-match? @function.builtin "^on[A-Z]"))

(method_declaration
  name: (identifier) @function.builtin
  (#lua-match? @function.builtin "^on[A-Z]"))

(variable_declaration
  name: (identifier) @function
  (arrow_function))

(variable_declaration
  name: (identifier) @function
  (type_annotation)
  (arrow_function))


(interface_property
  name: (identifier) @variable.member)

(interface_method
  name: (identifier) @function.method)

(property_declaration
  name: (identifier) @variable.member)

(enum_member
  (identifier) @constant)

(extern_enum_member
  (identifier) @constant)

(type_alias_declaration
  name: (type_identifier) @type)


(call_expression
  function: (identifier) @function.call)

(call_expression
  function: (member_expression
    property: (_) @function.method.call))

(generic_call_expression
  function: (identifier) @function.call)

(generic_call_expression
  function: (member_expression
    property: (_) @function.method.call))

(call_expression
  function: (await_expression
    (identifier) @function.call))

(call_expression
  function: (await_expression
    (member_expression
      property: (_) @function.method.call)))

(call_expression
  function: (identifier) @function.builtin
  (#lua-match? @function.builtin "^on[A-Z]"))

(call_expression
  function: (member_expression
    property: (identifier) @function.builtin)
  (#lua-match? @function.builtin "^on[A-Z]"))

(new_expression
  (identifier) @constructor)

(new_expression
  (member_expression
    property: (_) @constructor))


(member_expression
  property: (_) @variable.member)

(pair
  key: (identifier) @variable.member)

(shorthand_property
  (identifier) @variable.member)


(parameter
  name: (_) @variable.parameter)

(arrow_function
  parameters: (identifier) @variable.parameter)

(arrow_function_parameter
  name: (identifier) @variable.parameter)

(rest_parameter
  "..." @operator
  name: (identifier) @variable.parameter)

(pattern_element
  name: (identifier) @variable.parameter)

(pattern_property
  name: (identifier) @variable.parameter)

(pattern_property
  key: (identifier) @variable.member
  value: (identifier) @variable.parameter)

(rest_pattern
  "..." @operator
  name: (identifier) @variable.parameter)

(this_parameter
  "this" @variable.builtin)

(this_parameter
  "typeof" @keyword.operator)

(this_parameter
  name: (_) @variable.parameter)

(this_parameter
  receiver_type: (type
    (primitive_type) @type.builtin))


(variable_declaration
  name: (identifier) @variable)

(labeled_statement
  label: (identifier) @label)


(match_expression
  "match" @keyword.conditional)

(match_or_pattern
  "|" @punctuation.delimiter)

(match_array_pattern
  [
    "["
    "]"
  ] @punctuation.bracket)

(match_literal_pattern
  (string) @string)
(match_literal_pattern
  (number) @number)
(match_literal_pattern
  (boolean) @boolean)

(match_arm
  "=>" @punctuation.special)

(match_wildcard) @variable.builtin

(match_binding_pattern
  (identifier) @variable.parameter)

(match_arm
  guard: (_) @keyword.conditional)


(macro_decorator
  "@" @attribute
  name: (identifier) @attribute)

(macro_comptime
  "@comptime" @attribute)

(macro_target_block
  "@target" @attribute)

(macro_emit_statement
  "@emit" @attribute)

(macro_emit_expr
  "@emit" @attribute)

(macro_extern_statement
  "@extern" @attribute)

(macro_declaration
  name: (identifier) @function.macro)

(extern_macro
  name: (macro_name
    "@" @attribute
    (identifier) @attribute))

(macro_directive_statement
  (macro_decorator
    "@" @attribute
    name: (identifier) @attribute))


(extern_declaration
  "extern" @keyword)

(extern_function
  name: (_) @function)

(extern_method
  "extern" @keyword
  name: (_) @function.method
  "from" @keyword.import)

(operator_identifier) @function

(class_extern_method
  (macro_decorator
    "@" @attribute
    name: (identifier) @attribute))
(class_extern_method
  name: (_) @function.method)
(class_extern_method
  "static" @keyword.modifier)
(class_extern_method
  "extern" @keyword)
(class_extern_method
  "from" @keyword.import)

(extern_class
  "from" @keyword.import)

(extern_var
  "from" @keyword.import)

(extern_const
  "from" @keyword.import)

(extern_enum
  "from" @keyword.import)

(extern_macro
  "from" @keyword.import)

(extern_function
  "from" @keyword.import)


(test_declaration
  name: (string) @string)


[
  (this)
] @variable.builtin

[
  (null)
  (undefined)
] @constant.builtin

(boolean) @boolean

(number) @number

(string) @string

(template_string) @string

(template_string
  "\${" @punctuation.special
  "}" @punctuation.special)

(comment) @comment @spell

((comment) @comment.documentation
  (#lua-match? @comment.documentation "^/[*][*][^*].*[*]/$"))


[
  "if"
  "else"
  "switch"
  "case"
  "match"
  "when"
] @keyword.conditional

(switch_default
  "default" @keyword.conditional)


[
  "for"
  "of"
  "in"
  "do"
  "while"
  "continue"
] @keyword.repeat


"return" @keyword.return


"function" @keyword.function


[
  "new"
  "typeof"
] @keyword.operator

(type_assertion_expression
  "as" @keyword.operator)


[
  "try"
  "catch"
] @keyword.exception


[
  "import"
  "export"
] @keyword.import

(import_statement
  "from" @keyword.import)
(import_statement
  "as" @keyword.import)
(export_statement
  "from" @keyword.import)


[
  "interface"
  "enum"
  "type"
  "struct"
  "class"
  "actor"
] @keyword.type


(function_declaration
  "async" @keyword.coroutine)

(arrow_function
  "async" @keyword.coroutine)

(await_expression
  "await" @keyword.coroutine)

(for_of_statement
  "await" @keyword.coroutine)


[
  "readonly"
  "static"
] @keyword.modifier


[
  "const"
  "let"
  "var"
  "extends"
  "implements"
  "break"
  "default"
] @keyword

(export_statement
  "default" @keyword)


[
  "extern"
  "macro"
  "distinct"
] @keyword

[
  "defer"
  "move"
  "borrow"
  "out"
] @keyword

"test" @keyword

"expect" @keyword

(try_expression
  "try" @keyword.exception)
(try_expression
  "catch" @keyword.exception)

(defer_statement
  "defer" @keyword)

(expect_statement
  "expect" @keyword)

(unreachable_statement
  "unreachable" @keyword)


[
  "--"
  "-"
  "-="
  "+"
  "++"
  "+="
  "*"
  "**"
  "*="
  "/"
  "/="
  "%"
  "%="
  "="
  "=="
  "==="
  "!="
  "!=="
  "<"
  "<="
  ">"
  ">="
  "<<"
  "<<="
  ">>"
  ">>="
  ">>>"
  ">>>="
  "&&"
  "||"
  "&"
  "&="
  "|"
  "|="
  "^"
  "^="
  "~"
  "!"
  "?"
  "??"
  "..."
  ".."
  "|>"
] @operator

(ternary_expression
  [
    "?"
    ":"
  ] @keyword.conditional.ternary)

(binary_expression
  "/" @operator)

(arrow_function
  "=>" @punctuation.special)

(match_arm
  "=>" @punctuation.special)


[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket


[
  ";"
  "."
  ","
  ":"
] @punctuation.delimiter


(jsx_opening_element
  name: (identifier) @tag)

(jsx_closing_element
  name: (identifier) @tag)

(jsx_self_closing_element
  name: (identifier) @tag)

(jsx_member_expression
  object: (identifier) @tag
  property: (identifier) @tag)

(jsx_namespaced_name
  (identifier) @tag)

(jsx_attribute
  name: (identifier) @tag.attribute)

(jsx_attribute
  value: (string) @string)

(jsx_text) @string

(jsx_expression_container
  "{" @punctuation.special
  "}" @punctuation.special)

(jsx_spread_attribute
  "{" @punctuation.special
  "..." @operator
  "}" @punctuation.special)

(jsx_fragment
  "<" @punctuation.bracket
  ">" @punctuation.bracket)

(jsx_opening_element
  "<" @punctuation.bracket
  ">" @punctuation.bracket)

(jsx_closing_element
  "<" @punctuation.bracket
  "/" @punctuation.bracket
  ">" @punctuation.bracket)

(jsx_self_closing_element
  "<" @punctuation.bracket
  "/" @punctuation.bracket
  ">" @punctuation.bracket)
`;
