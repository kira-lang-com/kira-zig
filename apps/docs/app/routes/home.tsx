import { BookOpenText, Cable, Command, Cpu, FileCode2, Wrench } from "lucide-react";
import { HomeLayout } from "fumadocs-ui/layouts/home";
import { Link } from "react-router";
import type { Route } from "./+types/home";
import { baseOptions } from "@/lib/layout.shared";

const guideLinks = [
  {
    title: "Getting Started",
    href: "/docs/getting-started",
    description: "Install the bootstrapper, fetch LLVM, and run the first Kira programs.",
    icon: Wrench,
  },
  {
    title: "Language",
    href: "/docs/language",
    description: "Learn what the compiler understands today and where the executable subset stops.",
    icon: BookOpenText,
  },
  {
    title: "FFI",
    href: "/docs/ffi",
    description: "The C-ABI-only native library system: manifests, autobindings, and callbacks.",
    icon: Cable,
  },
  {
    title: "CLI",
    href: "/docs/cli",
    description: "The real kira-bootstrapper command surface and generated artifact flow.",
    icon: Command,
  },
];

const backendCards = [
  {
    icon: Cpu,
    title: "VM",
    body: "The default backend compiles Kira IR to bytecode and runs it in the repo's VM runtime.",
  },
  {
    icon: FileCode2,
    title: "LLVM Native",
    body: "The native path lowers the same IR through the LLVM C API and links a host executable.",
  },
  {
    icon: Cable,
    title: "Hybrid",
    body: "Keeps @Runtime functions in bytecode and @Native functions in a shared library — one process.",
  },
  {
    icon: Wrench,
    title: "Toolchain",
    body: "Managed LLVM installs under ~/.kira/toolchains/, fetched by kira-bootstrapper fetch-llvm.",
  },
];

const proofPoints = [
  "Managed Kira toolchain installs under ~/.kira/toolchains/<channel>/<version>/",
  "Pinned LLVM bundles under ~/.kira/toolchains/llvm/<llvm-version>/<host>/",
  "Generated bindings emitted as .kira files next to examples and tests",
  "Callbacks, Sokol proofs, and hybrid roundtrips all have corpus coverage",
];

export function meta({}: Route.MetaArgs) {
  return [
    { title: "Kira Documentation" },
    {
      name: "description",
      content:
        "English documentation for the current Kira Zig toolchain: language, compiler, execution model, toolchains, diagnostics, examples, and FFI.",
    },
  ];
}

export default function Home() {
  return (
    <HomeLayout {...baseOptions()}>
      <div className="mx-auto flex w-full max-w-5xl flex-1 flex-col gap-14 px-4 py-10 md:px-6 md:py-16">

        {/* ── Hero ─────────────────────────────────────────────── */}
        <section className="flex flex-col gap-7">
          <div className="kira-kicker">Kira language and toolchain</div>
          <h1 className="kira-display max-w-2xl text-4xl font-bold leading-[1.15] text-fd-foreground md:text-5xl">
            Read the current Kira system as it actually exists.
          </h1>
          <p className="max-w-xl text-base leading-7 text-fd-muted-foreground md:text-lg md:leading-8">
            A Zig-hosted compiler with VM, LLVM native, and hybrid backends. Managed LLVM
            toolchains and a manifest-driven C&nbsp;ABI FFI system. This documents what is
            implemented, not what is planned.
          </p>
          <div className="flex flex-wrap gap-3">
            <Link className="kira-button kira-button-primary" to="/docs/getting-started">
              Get Started
            </Link>
            <Link className="kira-button" to="/docs/language">
              Language
            </Link>
            <Link className="kira-button" to="/docs/ffi">
              FFI
            </Link>
            <Link className="kira-button" to="/docs/cli">
              CLI
            </Link>
          </div>
        </section>

        {/* ── Backends ─────────────────────────────────────────── */}
        <section>
          <h2 className="mb-4 text-xs font-bold uppercase tracking-widest text-fd-muted-foreground">
            Backends
          </h2>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            {backendCards.map(({ icon: Icon, title, body }) => (
              <article key={title} className="kira-panel flex flex-col gap-3">
                <span className="flex size-8 items-center justify-center rounded-lg border border-fd-border bg-fd-muted text-fd-primary">
                  <Icon className="size-4" />
                </span>
                <div>
                  <h3 className="kira-display text-sm font-semibold text-fd-foreground">{title}</h3>
                  <p className="mt-1 text-sm leading-6 text-fd-muted-foreground">{body}</p>
                </div>
              </article>
            ))}
          </div>
        </section>

        {/* ── Guides ───────────────────────────────────────────── */}
        <section>
          <h2 className="mb-4 text-xs font-bold uppercase tracking-widest text-fd-muted-foreground">
            Guides
          </h2>
          <div className="grid gap-3 sm:grid-cols-2">
            {guideLinks.map(({ icon: Icon, title, href, description }) => (
              <Link key={href} to={href} className="kira-link-card">
                <div className="mb-3 flex items-center gap-2.5">
                  <span className="flex size-8 items-center justify-center rounded-lg border border-fd-border bg-fd-muted text-fd-primary">
                    <Icon className="size-4" />
                  </span>
                  <h3 className="kira-display text-sm font-semibold text-fd-foreground">{title}</h3>
                </div>
                <p className="text-sm leading-6 text-fd-muted-foreground">{description}</p>
              </Link>
            ))}
          </div>
        </section>

        {/* ── In the repo today ─────────────────────────────────── */}
        <section>
          <h2 className="mb-4 text-xs font-bold uppercase tracking-widest text-fd-muted-foreground">
            In the repo today
          </h2>
          <ul className="grid gap-2 sm:grid-cols-2">
            {proofPoints.map((item) => (
              <li
                key={item}
                className="rounded-lg border border-fd-border bg-fd-card px-4 py-3 text-sm leading-6 text-fd-muted-foreground"
              >
                {item}
              </li>
            ))}
          </ul>
        </section>

      </div>
    </HomeLayout>
  );
}
