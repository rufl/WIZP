import type { ElectrobunConfig } from "electrobun";

const isPackageBuild = process.argv.some((arg) => arg === "build");
const bundleBrowserRuntime =
  process.env.WIZP_HOST_WEBVIEW !== "1" &&
  (process.env.WIZP_SELF_CONTAINED === "1" || isPackageBuild);
const backendFilename = process.platform === "win32" ? "wizp.exe" : "wizp";

export default {
  app: {
    name: "WIZP",
    identifier: "dev.wizp.app",
    version: "0.1.0",
    description: "Ultra-lightweight code editor powered by Zig + Monaco",
    fileAssociations: [
      {
        ext: ["txt", "md", "markdown", "json", "jsonc", "js", "jsx", "ts", "tsx", "css", "html", "xml", "yaml", "yml", "toml", "zig", "rs", "py", "sh"],
        name: "WIZP Text Document",
        role: "Editor",
      },
    ],
  },
  build: {
    bun: {
      // Main Electrobun process entry point
      entrypoint: "src/bun/index.ts",
    },
    copy: {
      [`zig-out/bin/${backendFilename}`]: backendFilename,
      "zig-out/frontend-dist": "frontend-dist",
    },
    watchIgnore: ["zig-out/**", ".zig-cache/**"],
    mac: {
      bundleCEF: bundleBrowserRuntime,
      defaultRenderer: bundleBrowserRuntime ? "cef" : "native",
    },
    linux: {
      bundleCEF: bundleBrowserRuntime,
      defaultRenderer: bundleBrowserRuntime ? "cef" : "native",
      // DINX targets broad Linux hardware and isolated X11 sessions; avoid
      // GLX context churn while retaining CEF's software compositor.
      chromiumFlags: {
        "disable-gpu": true,
        "disable-gpu-compositing": true,
      },
    },
    win: {
      bundleCEF: bundleBrowserRuntime,
      defaultRenderer: bundleBrowserRuntime ? "cef" : "native",
    },
  },
  runtime: {
    exitOnLastWindowClosed: true,
  },
} satisfies ElectrobunConfig;
