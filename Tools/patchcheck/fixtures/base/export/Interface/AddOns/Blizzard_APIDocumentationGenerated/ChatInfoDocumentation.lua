local ChatInfo =
{
	Name = "ChatInfo",
	Type = "System",
	Namespace = "C_ChatInfo",
	Environment = "All",

	Functions =
	{
	},

	Events =
	{
		{
			Name = "ChatMsgLoot",
			Type = "Event",
			LiteralName = "CHAT_MSG_LOOT",
			SynchronousEvent = true,
			Payload =
			{
				{ Name = "text", Type = "cstring", Nilable = false },
				{ Name = "languageName", Type = "cstring", Nilable = false, NeverSecret = true },
			},
		},
		{
			Name = "ChatMsgMoney",
			Type = "Event",
			LiteralName = "CHAT_MSG_MONEY",
			SynchronousEvent = true,
			Payload =
			{
				{ Name = "text", Type = "cstring", Nilable = false },
			},
		},
	},

	Tables =
	{
	},

	Predicates =
	{
	},
};

APIDocumentation:AddDocumentationTable(ChatInfo);
