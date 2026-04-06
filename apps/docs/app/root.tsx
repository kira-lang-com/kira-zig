import {
  isRouteErrorResponse,
  Links,
  Meta,
  Outlet,
  Scripts,
  ScrollRestoration,
} from "react-router";
import { RootProvider } from "fumadocs-ui/provider/react-router";
import type { Route } from "./+types/root";
import "./app.css";
import SearchDialog from "@/components/search";
import NotFound from "./routes/not-found";
import { siteDescription } from "@/lib/shared";

export const links: Route.LinksFunction = () => [
  { rel: "icon", href: "/favicon.svg", type: "image/svg+xml" },
  { rel: "preconnect", href: "https://fonts.googleapis.com" },
  {
    rel: "preconnect",
    href: "https://fonts.gstatic.com",
    crossOrigin: "anonymous",
  },
  {
    rel: "stylesheet",
    href:
      "https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=IBM+Plex+Sans:wght@400;500;600;700&family=Space+Grotesk:wght@500;700&display=swap",
  },
];

export function Layout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <meta charSet="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="description" content={siteDescription} />
        <meta name="theme-color" content="#b76418" />
        <Meta />
        <Links />
      </head>
      <body className="flex min-h-screen flex-col kira-shell">
        <RootProvider search={{ SearchDialog }}>{children}</RootProvider>
        <ScrollRestoration />
        <Scripts />
      </body>
    </html>
  );
}

export default function App() {
  return <Outlet />;
}

export function ErrorBoundary({ error }: Route.ErrorBoundaryProps) {
  let message = "Unexpected Error";
  let details = "The documentation site hit an unexpected failure.";
  let stack: string | undefined;

  if (isRouteErrorResponse(error)) {
    if (error.status === 404) return <NotFound />;
    details = error.statusText;
  } else if (import.meta.env.DEV && error instanceof Error) {
    details = error.message;
    stack = error.stack;
  }

  return (
    <main className="mx-auto flex w-full max-w-5xl flex-1 flex-col gap-4 px-4 py-16">
      <h1 className="kira-display text-4xl font-bold">{message}</h1>
      <p className="max-w-3xl text-lg text-fd-muted-foreground">{details}</p>
      {stack ? (
        <pre className="overflow-x-auto rounded-2xl border border-black/10 bg-white/70 p-4 text-sm shadow-sm">
          <code>{stack}</code>
        </pre>
      ) : null}
    </main>
  );
}
