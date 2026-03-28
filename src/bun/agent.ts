import { createDeepAgent } from "deepagents";
import { tool, HumanMessage } from "langchain";
import { ChatOpenAI } from "@langchain/openai";
import { MemorySaver } from "@langchain/langgraph";
import { z } from "zod";
import type { AIProvider } from "../shared/types";

// Helper to run shell commands
async function shell(cmd: string): Promise<string> {
  const proc = Bun.spawn(["bash", "-c", cmd], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const stdout = await new Response(proc.stdout).text();
  const stderr = await new Response(proc.stderr).text();
  await proc.exited;
  if (proc.exitCode !== 0 && stderr.trim()) {
    throw new Error(stderr.trim());
  }
  return stdout.trim();
}

// ─── Time & Date ───

const getTime = tool(
  async () => {
    return new Date().toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  },
  {
    name: "get_time",
    description: "Get the current time",
    schema: z.object({}),
  }
);

const getDate = tool(
  async () => {
    return new Date().toLocaleDateString([], { weekday: "long", month: "long", day: "numeric", year: "numeric" });
  },
  {
    name: "get_date",
    description: "Get today's date",
    schema: z.object({}),
  }
);

// ─── App & URL Launcher ───

const openApp = tool(
  async ({ appName }) => {
    await shell(`open -a "${appName}"`);
    return `Opened ${appName}.`;
  },
  {
    name: "open_application",
    description: "Open a macOS application by name (e.g. Safari, Notes, Calculator, Finder, Terminal, Messages, Mail, Music, Spotify, Slack, Discord)",
    schema: z.object({
      appName: z.string().describe("The name of the application to open"),
    }),
  }
);

const openURL = tool(
  async ({ url }) => {
    await shell(`open "${url}"`);
    return `Opened ${url} in your browser.`;
  },
  {
    name: "open_url",
    description: "Open a URL in the default web browser",
    schema: z.object({
      url: z.string().describe("The URL to open"),
    }),
  }
);

const webSearch = tool(
  async ({ query }) => {
    const encoded = encodeURIComponent(query);
    await shell(`open "https://www.google.com/search?q=${encoded}"`);
    return `Searching the web for "${query}".`;
  },
  {
    name: "web_search",
    description: "Search the web using the default browser. Use this when the user asks to search for something online.",
    schema: z.object({
      query: z.string().describe("The search query"),
    }),
  }
);

// ─── Timers & Reminders ───

const setTimer = tool(
  async ({ seconds, label = "Timer" }) => {
    const script = `sleep ${seconds} && osascript -e 'display notification "${label} is done!" with title "John Assistant" sound name "Glass"'`;
    Bun.spawn(["bash", "-c", script], { stdout: "ignore", stderr: "ignore" });
    const mins = Math.floor(seconds / 60);
    const secs = seconds % 60;
    const display = mins > 0 ? `${mins} minute${mins !== 1 ? "s" : ""}${secs > 0 ? ` and ${secs} second${secs !== 1 ? "s" : ""}` : ""}` : `${secs} second${secs !== 1 ? "s" : ""}`;
    return `Timer set for ${display}. I'll notify you when it's done.`;
  },
  {
    name: "set_timer",
    description: "Set a timer for a specified duration. When it goes off, a notification will appear.",
    schema: z.object({
      seconds: z.number().describe("Timer duration in seconds"),
      label: z.string().optional().describe("Optional label for the timer"),
    }),
  }
);

const setReminder = tool(
  async ({ message, delayMinutes }) => {
    const delaySecs = Math.round(delayMinutes * 60);
    const script = `sleep ${delaySecs} && osascript -e 'display notification "${message}" with title "John Reminder" sound name "Glass"'`;
    Bun.spawn(["bash", "-c", script], { stdout: "ignore", stderr: "ignore" });
    return `Reminder set: "${message}" in ${delayMinutes} minute${delayMinutes !== 1 ? "s" : ""}.`;
  },
  {
    name: "set_reminder",
    description: "Set a reminder with a message. Creates a macOS notification after the specified delay.",
    schema: z.object({
      message: z.string().describe("The reminder message"),
      delayMinutes: z.number().describe("Minutes from now to show the reminder"),
    }),
  }
);

// ─── Weather ───

const getWeather = tool(
  async ({ location = "" }) => {
    const loc = location ? encodeURIComponent(location) : "";
    const result = await shell(`curl -s "wttr.in/${loc}?format=%l:+%C+%t+%h+humidity+%w+wind"`);
    return result || "Could not fetch weather data.";
  },
  {
    name: "get_weather",
    description: "Get the current weather for a location. If no location is given, uses auto-detected location.",
    schema: z.object({
      location: z.string().optional().describe("City name or location (e.g. 'New York', 'London')"),
    }),
  }
);

// ─── System Controls ───

const setVolume = tool(
  async ({ level, mute }) => {
    if (mute === true) {
      await shell(`osascript -e 'set volume with output muted'`);
      return "Volume muted.";
    }
    if (mute === false) {
      await shell(`osascript -e 'set volume without output muted'`);
      return "Volume unmuted.";
    }
    if (level !== undefined) {
      const macLevel = Math.round((level / 100) * 7);
      await shell(`osascript -e 'set volume output volume ${level}' -e 'set volume ${macLevel}'`);
      return `Volume set to ${level}%.`;
    }
    return "Please specify a volume level or mute/unmute.";
  },
  {
    name: "set_volume",
    description: "Set the system volume level (0-100) or mute/unmute",
    schema: z.object({
      level: z.number().min(0).max(100).optional().describe("Volume level from 0 to 100"),
      mute: z.boolean().optional().describe("Set to true to mute, false to unmute"),
    }),
  }
);

const getVolume = tool(
  async () => {
    const result = await shell(`osascript -e 'output volume of (get volume settings)'`);
    return `Current volume is ${result}%.`;
  },
  {
    name: "get_volume",
    description: "Get the current system volume level",
    schema: z.object({}),
  }
);

const toggleDarkMode = tool(
  async ({ enable }) => {
    if (enable === undefined) {
      await shell(`osascript -e 'tell app "System Events" to tell appearance preferences to set dark mode to not dark mode'`);
      return "Dark mode toggled.";
    }
    await shell(`osascript -e 'tell app "System Events" to tell appearance preferences to set dark mode to ${enable}'`);
    return enable ? "Dark mode enabled." : "Light mode enabled.";
  },
  {
    name: "toggle_dark_mode",
    description: "Toggle macOS dark mode on or off",
    schema: z.object({
      enable: z.boolean().optional().describe("true for dark mode, false for light mode. Omit to toggle."),
    }),
  }
);

const toggleDoNotDisturb = tool(
  async ({ enable }) => {
    if (enable) {
      await shell(`shortcuts run "Turn On Do Not Disturb" 2>/dev/null || osascript -e 'display notification "Please enable Do Not Disturb manually" with title "John Assistant"'`);
      return "Do Not Disturb enabled.";
    }
    await shell(`shortcuts run "Turn Off Do Not Disturb" 2>/dev/null || osascript -e 'display notification "Please disable Do Not Disturb manually" with title "John Assistant"'`);
    return "Do Not Disturb disabled.";
  },
  {
    name: "toggle_do_not_disturb",
    description: "Toggle Do Not Disturb / Focus mode on macOS",
    schema: z.object({
      enable: z.boolean().describe("true to enable Do Not Disturb, false to disable"),
    }),
  }
);

// ─── System Info ───

const getBatteryStatus = tool(
  async () => {
    const result = await shell(`pmset -g batt | grep -Eo '\\d+%; \\w+'`);
    return result ? `Battery: ${result}.` : "Could not read battery status (desktop Mac or unavailable).";
  },
  {
    name: "get_battery_status",
    description: "Get the current battery level and charging status of the Mac",
    schema: z.object({}),
  }
);

const getSystemInfo = tool(
  async () => {
    const [version, uptime, memory, disk] = await Promise.all([
      shell(`sw_vers -productVersion`),
      shell(`uptime | sed 's/.*up /up /' | sed 's/,.*//'`),
      shell(`memory_pressure | head -1`),
      shell(`df -h / | tail -1 | awk '{print $4 " free of " $2}'`),
    ]);
    return `macOS ${version}, ${uptime}, Memory: ${memory}, Disk: ${disk}`;
  },
  {
    name: "get_system_info",
    description: "Get basic system information: macOS version, uptime, memory, and disk space",
    schema: z.object({}),
  }
);

const getScreenBrightness = tool(
  async () => {
    try {
      const result = await shell(`osascript -e 'tell application "System Events" to get value of slider 1 of group 1 of group 2 of toolbar 1 of window 1 of application process "System Preferences"' 2>/dev/null || echo "unavailable"`);
      if (result === "unavailable") {
        return "Screen brightness control requires the brightness CLI tool or System Settings access.";
      }
      return `Screen brightness: ${Math.round(parseFloat(result) * 100)}%`;
    } catch {
      return "Could not read screen brightness.";
    }
  },
  {
    name: "get_screen_brightness",
    description: "Get the current screen brightness level",
    schema: z.object({}),
  }
);

// ─── Clipboard ───

const getClipboard = tool(
  async () => {
    const content = await shell(`pbpaste`);
    return content ? `Clipboard contents: ${content.slice(0, 500)}` : "Clipboard is empty.";
  },
  {
    name: "get_clipboard",
    description: "Get the current contents of the clipboard (text only)",
    schema: z.object({}),
  }
);

const setClipboard = tool(
  async ({ text }) => {
    const proc = Bun.spawn(["pbcopy"], { stdin: "pipe" });
    proc.stdin.write(text);
    proc.stdin.end();
    await proc.exited;
    return "Text copied to clipboard.";
  },
  {
    name: "set_clipboard",
    description: "Copy text to the clipboard",
    schema: z.object({
      text: z.string().describe("The text to copy to the clipboard"),
    }),
  }
);

// ─── Music / Media ───

const musicControl = tool(
  async ({ action, app = "Music" }) => {
    const commands: Record<string, string> = {
      play: "play",
      pause: "pause",
      next: "next track",
      previous: "previous track",
    };
    await shell(`osascript -e 'tell application "${app}" to ${commands[action]}'`);
    return `${action.charAt(0).toUpperCase() + action.slice(1)} on ${app}.`;
  },
  {
    name: "music_control",
    description: "Control music playback (play, pause, next, previous). Works with Apple Music and Spotify.",
    schema: z.object({
      action: z.enum(["play", "pause", "next", "previous"]).describe("The playback action"),
      app: z.enum(["Music", "Spotify"]).optional().describe("Which music app to control. Defaults to Music."),
    }),
  }
);

const getNowPlaying = tool(
  async ({ app = "Music" }) => {
    try {
      const name = await shell(`osascript -e 'tell application "${app}" to get name of current track'`);
      const artist = await shell(`osascript -e 'tell application "${app}" to get artist of current track'`);
      return `Now playing: "${name}" by ${artist} on ${app}.`;
    } catch {
      return `No track is currently playing on ${app}, or ${app} is not open.`;
    }
  },
  {
    name: "get_now_playing",
    description: "Get the currently playing song from Apple Music or Spotify",
    schema: z.object({
      app: z.enum(["Music", "Spotify"]).optional().describe("Which music app to check. Defaults to Music."),
    }),
  }
);

// ─── Notifications ───

const sendNotification = tool(
  async ({ title, message }) => {
    await shell(`osascript -e 'display notification "${message}" with title "${title}" sound name "Glass"'`);
    return `Notification sent: "${title}".`;
  },
  {
    name: "send_notification",
    description: "Show a macOS notification with a title and message",
    schema: z.object({
      title: z.string().describe("Notification title"),
      message: z.string().describe("Notification message body"),
    }),
  }
);

// ─── Calculator ───

const calculate = tool(
  async ({ expression }) => {
    try {
      const result = await shell(`python3 -c "from math import *; print(${expression})"`);
      return `${expression} = ${result}`;
    } catch {
      return `Could not evaluate: ${expression}. Please check the expression.`;
    }
  },
  {
    name: "calculate",
    description: "Evaluate a math expression. Supports basic arithmetic, trigonometry, logarithms, etc.",
    schema: z.object({
      expression: z.string().describe("The math expression to evaluate (e.g. '2 + 2', 'sqrt(144)', 'sin(3.14)')"),
    }),
  }
);

// ─── File Search ───

const findFiles = tool(
  async ({ query, folder }) => {
    const onlyIn = folder ? ` -onlyin "${folder}"` : "";
    const results = await shell(`mdfind${onlyIn} -name "${query}" | head -10`);
    return results || `No files found matching "${query}".`;
  },
  {
    name: "find_files",
    description: "Search for files on the Mac by name using Spotlight (mdfind). Good for finding documents, images, etc.",
    schema: z.object({
      query: z.string().describe("The filename or search term to look for"),
      folder: z.string().optional().describe("Optional folder to search in (e.g. ~/Documents)"),
    }),
  }
);

// ─── Productivity ───

const getFocusPlan = tool(
  async ({ duration = "one hour" }) => {
    return `Try a focused ${duration}: 5 minutes to define the goal, 45 minutes of uninterrupted work, 10 minutes to review and capture the next step.`;
  },
  {
    name: "get_focus_plan",
    description: "Create a focused work plan for the user",
    schema: z.object({
      duration: z.string().optional().describe("How long the user wants to focus"),
    }),
  }
);

const getAgenda = tool(
  async () => {
    return "Here's a calm agenda: pick one priority for the next 90 minutes, silence distractions, then take a short reset before your next task block.";
  },
  {
    name: "get_agenda",
    description: "Get a calm agenda plan for the day",
    schema: z.object({}),
  }
);

// ─── Wifi ───

const getWifiNetwork = tool(
  async () => {
    try {
      const ssid = await shell(`networksetup -getairportnetwork en0 | sed 's/Current Wi-Fi Network: //'`);
      return ssid ? `Connected to: ${ssid}` : "Not connected to Wi-Fi.";
    } catch {
      return "Could not determine Wi-Fi status.";
    }
  },
  {
    name: "get_wifi_network",
    description: "Get the name of the currently connected Wi-Fi network",
    schema: z.object({}),
  }
);

// ─── Screenshot ───

const takeScreenshot = tool(
  async ({ area = "fullscreen" }) => {
    const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
    const path = `~/Desktop/screenshot-${timestamp}.png`;
    if (area === "selection") {
      await shell(`screencapture -i ${path}`);
    } else {
      await shell(`screencapture ${path}`);
    }
    return `Screenshot saved to Desktop.`;
  },
  {
    name: "take_screenshot",
    description: "Take a screenshot and save it to the Desktop",
    schema: z.object({
      area: z.enum(["fullscreen", "selection"]).optional().describe("'fullscreen' for the entire screen, 'selection' to let the user select an area. Defaults to fullscreen."),
    }),
  }
);

// ─── All Tools ───

const allTools = [
  // Time & Date
  getTime, getDate,
  // Launcher
  openApp, openURL, webSearch,
  // Timers & Reminders
  setTimer, setReminder,
  // Weather
  getWeather,
  // System Controls
  setVolume, getVolume, toggleDarkMode, toggleDoNotDisturb,
  // System Info
  getBatteryStatus, getSystemInfo, getScreenBrightness, getWifiNetwork,
  // Clipboard
  getClipboard, setClipboard,
  // Music
  musicControl, getNowPlaying,
  // Notifications
  sendNotification,
  // Calculator
  calculate,
  // Files
  findFiles,
  // Screenshot
  takeScreenshot,
  // Productivity
  getFocusPlan, getAgenda,
];

// ─── System Prompt ───

const systemPrompt = `You are John Assistant, a helpful Siri-like desktop voice assistant for macOS. You provide quick, concise, and friendly responses.

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

You have access to many tools similar to Siri:
- Time & Date: get current time and date
- App Launcher: open any macOS app or URL, search the web
- Timers & Reminders: set timers and reminders with notifications
- Weather: get current weather for any location
- System Controls: volume, dark mode, Do Not Disturb
- System Info: battery, disk space, Wi-Fi, system details
- Clipboard: read and write clipboard contents
- Music: play/pause/skip, see what's playing (Apple Music & Spotify)
- Calculator: evaluate math expressions
- File Search: find files using Spotlight
- Screenshots: capture the screen
- Notifications: send macOS notifications
- Productivity: focus plans and agenda suggestions

Always use the appropriate tool when the user's request matches one. For example, if they ask "what time is it", use get_time. If they say "open Safari", use open_application.`;

// ─── Model Factories ───

function createLocalModel() {
  return new ChatOpenAI({
    modelName: process.env.OLLAMA_MODEL || "qwen3.5:9b",
    configuration: {
      baseURL: process.env.OLLAMA_BASE_URL || "http://localhost:11434/v1",
    },
    apiKey: "ollama",
    temperature: 0.7,
  });
}

function getModelForProvider(provider: AIProvider) {
  if (provider === "local") {
    // Ollama uses ChatOpenAI with custom baseURL since deepagents
    // doesn't natively configure Ollama's OpenAI-compatible endpoint
    return createLocalModel();
  }
  // OpenRouter also uses the OpenAI-compatible API
  const apiKey = process.env.OPENROUTER_API_KEY;
  if (!apiKey) {
    throw new Error("OPENROUTER_API_KEY is not set. Add it to your .env file.");
  }
  return new ChatOpenAI({
    modelName: process.env.OPENROUTER_MODEL || "anthropic/claude-sonnet-4",
    configuration: {
      baseURL: "https://openrouter.ai/api/v1",
    },
    apiKey,
    temperature: 0.7,
  });
}

// ─── Deep Agent ───

const checkpointer = new MemorySaver();

// Cache agents per provider
const agents: Record<string, ReturnType<typeof createDeepAgent>> = {};

function getAgent(provider: AIProvider) {
  if (!agents[provider]) {
    agents[provider] = createDeepAgent({
      model: getModelForProvider(provider),
      tools: allTools,
      systemPrompt,
      checkpointer,
      name: `john-${provider}`,
    });
  }
  return agents[provider];
}

// ─── Ollama Health Check ───

async function checkOllamaConnection(): Promise<void> {
  const baseURL = process.env.OLLAMA_BASE_URL || "http://localhost:11434/v1";
  const healthURL = baseURL.replace(/\/v1\/?$/, "");

  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 5000);
    const res = await fetch(healthURL, { signal: controller.signal });
    clearTimeout(timeout);
    if (!res.ok) {
      throw new Error(`Ollama responded with status ${res.status}`);
    }
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    if (message.includes("abort")) {
      throw new Error("Ollama is running but took too long to respond. Please try again.");
    }
    throw new Error(`Cannot connect to Ollama at ${healthURL}. Please make sure Ollama is running.`);
  }
}

// ─── Public API ───

export async function processUserMessage(
  userMessage: string,
  provider: AIProvider = "openrouter",
  threadId: string = "default"
): Promise<string> {
  if (provider === "local") {
    await checkOllamaConnection();
  }

  const agent = getAgent(provider);
  const config = { configurable: { thread_id: `${provider}-${threadId}` } };

  const result = await agent.invoke(
    { messages: [new HumanMessage(userMessage)] },
    config
  );

  const messages = result.messages;
  if (!messages || messages.length === 0) {
    return "I'm sorry, I didn't get a response. Please try again.";
  }

  const lastMessage = messages[messages.length - 1];

  // Handle content as string
  if (typeof lastMessage.content === "string") {
    return lastMessage.content;
  }

  // Handle content as array of content blocks (common with Anthropic/Deep Agents)
  if (Array.isArray(lastMessage.content)) {
    const textParts = lastMessage.content
      .filter((block: { type: string }) => block.type === "text")
      .map((block: { text: string }) => block.text);
    return textParts.join("\n") || "";
  }

  return "";
}

export async function streamUserMessage(
  userMessage: string,
  onChunk: (text: string) => void,
  provider: AIProvider = "openrouter",
  threadId: string = "default"
): Promise<string> {
  if (provider === "local") {
    await checkOllamaConnection();
  }

  const agent = getAgent(provider);
  const config = { configurable: { thread_id: `${provider}-${threadId}` } };

  let fullResponse = "";

  const stream = await agent.stream(
    { messages: [new HumanMessage(userMessage)] },
    { ...config, streamMode: "messages" }
  );

  for await (const [message, metadata] of stream) {
    // Only emit AI message chunks (not tool calls/results)
    if (message._getType?.() === "ai" || message.constructor?.name === "AIMessageChunk") {
      let text = "";
      if (typeof message.content === "string") {
        text = message.content;
      } else if (Array.isArray(message.content)) {
        text = message.content
          .filter((block: any) => block.type === "text")
          .map((block: any) => block.text)
          .join("");
      }
      if (text) {
        fullResponse += text;
        onChunk(text);
      }
    }
  }

  return fullResponse || "I'm sorry, I didn't get a response. Please try again.";
}
