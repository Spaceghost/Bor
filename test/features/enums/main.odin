package enums

Mode :: enum u32 {
	Idle,
	Playing = 4,
	Paused,
}

@(export)
bor_test_enum_value :: proc "c" () -> u32 {
	mode := Mode.Playing
	return u32(mode) + u32(Mode.Paused)
}
