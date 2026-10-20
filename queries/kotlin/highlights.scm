; extends

; `$name` in a string: nvim-treesitter highlights only `${...}`
(string_literal
  (interpolation_identifier_start) @punctuation.special
  (interpolated_identifier) @variable)
