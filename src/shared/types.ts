import type { RPCSchema } from "electrobun/bun";

export type JohnRPCType = {
	bun: RPCSchema<{
		requests: {
			processMessage: { params: { message: string }; response: { success: boolean; response?: string; error?: string } };
			resizeWindow: { params: { width: number; height: number }; response: void };
		};
		messages: {};
	}>;
	webview: RPCSchema<{
		requests: {};
		messages: {};
	}>;
};
