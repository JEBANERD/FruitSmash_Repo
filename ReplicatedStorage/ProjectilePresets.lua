return {
	_Default = {
		Speed = 10,           -- was 120; slower so players can hit
		Damage = 10,
		Path = "Linear",
		ControlOffset = 15,
		Amplitude = 3,
		Frequency = 2,
	},

	Apple = {
		Speed = 10,
		Damage = 10,
		Path = "Linear",
	},

	Banana = {
		Speed = 10,
		Damage = 12,
		Path = "ZigZag",
		Amplitude = 4,
		Frequency = 2.0,
	},

	Orange = {
		Speed = 10,
		Damage = 16,
		Path = "Bounce",
		ControlOffset = 20,
	},
}
