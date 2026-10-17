; extends

(multiline_comment) @fold

(value_arguments) @fold

(function_value_parameters) @fold

(try_expression
  "{" @fold
  "}" @fold)

(catch_block) @fold

(finally_block) @fold

(string_literal) @fold
