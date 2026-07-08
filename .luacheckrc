std = "lua54"

files["test_spec.lua"] = { std = "+busted" }
-- or a glob:
files["init.lua"] = { globals = { "hs" } }
