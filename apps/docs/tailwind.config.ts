import type { Config } from "tailwindcss";

export default {
  content: [
    "./app/**/*.{js,jsx,ts,tsx}",
    "./node_modules/fumadocs-ui/components/**/*.{js,jsx,ts,tsx}",
    "./node_modules/fumadocs-ui/layouts/**/*.{js,jsx,ts,tsx}",
  ],
} satisfies Config;
