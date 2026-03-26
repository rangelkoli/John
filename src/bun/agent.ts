import { ChatOpenAI } from "@langchain/openai";
import { MemorySaver, START, StateGraph } from "@langchain/langgraph";
import { ToolNode } from "@langchain/langgraph/prebuilt";
import { HumanMessage, SystemMessage } from "@langchain/core/messages";
import type { BaseMessage } from "@langchain/core/messages";
import { DynamicStructuredTool } from "@langchain/core/tools";
import { z } from "zod";

interface AgentState {
  messages: BaseMessage[];
}

const getTimeSchema = z.object({});
const getTime = new DynamicStructuredTool({
  name: "get_time",
  description: "Get the current time",
  schema: getTimeSchema,
  func: async () => {
    const now = new Date();
    return now.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  },
});

const getDateSchema = z.object({});
const getDate = new DynamicStructuredTool({
  name: "get_date",
  description: "Get today's date",
  schema: getDateSchema,
  func: async () => {
    const now = new Date();
    return now.toLocaleDateString([], { weekday: "long", month: "long", day: "numeric" });
  },
});

const getFocusPlanSchema = z.object({
  duration: z.string().optional().describe("How long the user wants to focus"),
});
const getFocusPlan = new DynamicStructuredTool({
  name: "get_focus_plan",
  description: "Create a focused work plan for the user",
  schema: getFocusPlanSchema,
  func: async ({ duration = "one hour" }) => {
    return `Try a focused ${duration}: 5 minutes to define the goal, 45 minutes of uninterrupted work, 10 minutes to review and capture the next step.`;
  },
});

const getAgendaSchema = z.object({});
const getAgenda = new DynamicStructuredTool({
  name: "get_agenda",
  description: "Get a calm agenda plan for the day",
  schema: getAgendaSchema,
  func: async () => {
    return "Here's a calm agenda: pick one priority for the next 90 minutes, silence distractions, then take a short reset before your next task block.";
  },
});

const tools = [getTime, getDate, getFocusPlan, getAgenda];

const model = new ChatOpenAI({
  modelName: process.env.OLLAMA_MODEL || "qwen3.5:9b",
  configuration: {
    baseURL: process.env.OLLAMA_BASE_URL || "http://localhost:11434/v1",
  },
  apiKey: "ollama",
  temperature: 0.7,
}).bindTools(tools);
const toolNode = new ToolNode(tools);

function shouldContinue(state: AgentState): "tools" | "end" {
  const messages = state.messages;
  const lastMessage = messages[messages.length - 1];

  if (lastMessage._getType() === "ai" && "tool_calls" in lastMessage && lastMessage.tool_calls?.length) {
    return "tools";
  }

  return "end";
}

async function callModel(state: AgentState) {
  const messages = state.messages;
  const response = await model.invoke(messages);
  return { messages: [response] };
}

const workflow = new StateGraph<AgentState>({
  channels: {
    messages: {
      reducer: (x: BaseMessage[], y: BaseMessage[]) => x.concat(y),
    },
  },
});

workflow.addNode("agent", callModel);
workflow.addNode("tools", toolNode);

workflow.addEdge(START, "agent");
workflow.addConditionalEdges("agent", shouldContinue);
workflow.addEdge("tools", "agent");

const checkpointer = new MemorySaver();
const app = workflow.compile({ checkpointer });

const systemPrompt = `You are John Assistant, a helpful Siri-like desktop voice assistant. You provide quick, concise, and friendly responses.

Your personality:
- Professional yet warm and approachable
- Concise - keep responses brief and to the point
- Helpful and encouraging
- Focus on actionable advice

When responding:
- Keep answers under 2-3 sentences when possible
- Be direct and clear
- Use a friendly, conversational tone
- Provide practical, actionable information

You have access to tools for getting the time, date, creating focus plans, and providing agenda suggestions. Use them when appropriate.`;

export async function processUserMessage(userMessage: string, threadId: string = "default"): Promise<string> {
  const config = { configurable: { thread_id: threadId } };

  const state = await app.getState(config);

  let messages: BaseMessage[];
  if (!state || !state.values.messages || state.values.messages.length === 0) {
    messages = [
      new SystemMessage(systemPrompt),
      new HumanMessage(userMessage),
    ];
  } else {
    messages = [new HumanMessage(userMessage)];
  }

  const result = await app.invoke(
    { messages },
    config
  );

  const lastMessage = result.messages[result.messages.length - 1];
  return typeof lastMessage.content === "string" ? lastMessage.content : "";
}
