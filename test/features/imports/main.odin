package imports

import helper "./helper"

@(export)
bor_test_imports :: proc "c" () -> u32 {
	return helper.answer()
}
