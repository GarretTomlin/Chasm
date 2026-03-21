(module
  (func $main
    (call $print (i64.const 0))
    (call $print (i64.add (i64.const 1) (i64.const 19)))
  )
  (export "main" (func $main))
)
