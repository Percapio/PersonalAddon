local Unit =
{
	Name = "Unit",
	Type = "System",
	Environment = "All",

	Functions =
	{
		{
			Name = "UnitThreatSituation",
			Type = "Function",
			SecretWhenUnitThreatStateRestricted = true,
			SecretArguments = "AllowedWhenUntainted",

			Arguments =
			{
				{ Name = "unit", Type = "UnitToken", Nilable = false },
				{ Name = "mobGUID", Type = "UnitToken", Nilable = true },
			},

			Returns =
			{
				{ Name = "result", Type = "number", Nilable = true },
			},
		},
	},

	Events =
	{
	},

	Tables =
	{
	},

	Predicates =
	{
	},
};

APIDocumentation:AddDocumentationTable(Unit);
