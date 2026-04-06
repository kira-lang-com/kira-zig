import type { Config } from "@react-router/dev/config";
import { createGetUrl, getSlugs } from "fumadocs-core/source";
import { glob } from "tinyglobby";

const getUrl = createGetUrl("/docs");

export default {
  ssr: true,
  future: {
    v8_middleware: true,
  },
  async prerender({ getStaticPaths }) {
    const paths: string[] = [];

    for (const path of getStaticPaths()) {
      paths.push(path);
    }

    for (const entry of await glob("**/*.mdx", { cwd: "content/docs" })) {
      const slugs = getSlugs(entry);
      paths.push(getUrl(slugs), `/llms.mdx/docs/${[...slugs, "content.md"].join("/")}`);
    }

    return paths;
  },
} satisfies Config;
