import type { Route } from "./+types/docs";
import { DocsLayout } from "fumadocs-ui/layouts/docs";
import {
  DocsBody,
  DocsDescription,
  DocsPage,
  DocsTitle,
} from "fumadocs-ui/layouts/docs/page";
import { source } from "@/lib/source";
import browserCollections from "collections/browser";
import { baseOptions } from "@/lib/layout.shared";
import { gitConfig } from "@/lib/shared";
import { useMDXComponents } from "@/components/mdx";
import NotFound from "./not-found";

const clientLoader = browserCollections.docs.createClientLoader({
  component(
    { toc, frontmatter, default: Mdx },
    { path }: { path: string },
  ) {
    return (
      <DocsPage toc={toc}>
        <title>{frontmatter.title}</title>
        <meta name="description" content={frontmatter.description} />
        <DocsTitle>{frontmatter.title}</DocsTitle>
        <DocsDescription>{frontmatter.description}</DocsDescription>
        <div className="flex flex-row flex-wrap items-center gap-2 border-b border-black/8 -mt-4 pb-6">
          <a
            className="inline-flex items-center gap-2 rounded-full border border-fd-border bg-fd-card px-3 py-1.5 text-sm font-medium text-fd-foreground transition hover:bg-fd-muted"
            href={`https://github.com/${gitConfig.user}/${gitConfig.repo}/blob/${gitConfig.branch}/apps/docs/content/docs/${path}`}
            target="_blank"
            rel="noreferrer"
          >
            View Source
          </a>
        </div>
        <DocsBody>
          <Mdx components={useMDXComponents()} />
        </DocsBody>
      </DocsPage>
    );
  },
});

export default function Page({ params }: Route.ComponentProps) {
  const slugs = (params["*"] ?? "").split("/").filter((v) => v.length > 0);
  const page = source.getPage(slugs);

  if (!page) return <NotFound />;

  return (
    <DocsLayout {...baseOptions()} tree={source.getPageTree()}>
      {clientLoader.useContent(page.path, { path: page.path })}
    </DocsLayout>
  );
}
