#!/usr/bin/env python3
"""Validate the curated real-extension smoke runner.

By default this remains a fast local contract check. When
WIZP_REAL_EXTENSION_NETWORK=1 is set, it also downloads curated OpenVSX packages,
opens the VSIX archives, verifies package.json/manifests, and writes a report.
"""

from __future__ import annotations

import json
import os
import platform
import selectors
import signal
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import PurePosixPath
from pathlib import Path


WORKSPACE_ROOT = Path(__file__).resolve().parents[2]
LEDGER = WORKSPACE_ROOT / "docs" / "vscode-parity" / "KNOWN_EXTENSIONS.md"
TIERS = WORKSPACE_ROOT / "docs" / "vscode-parity" / "EXTENSION_COMPATIBILITY.md"
PROJECT_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = PROJECT_ROOT / ".github" / "workflows" / "parity-hardening.yml"
REPORT = PROJECT_ROOT / "build" / "parity-real-extensions" / "real-extension-report.json"
OPENVSX_TOP_REPORT = PROJECT_ROOT / "build" / "vscode-parity" / "openvsx-top-extensions.json"
OPENVSX_METADATA_CACHE = PROJECT_ROOT / "build" / "parity-real-extensions" / "openvsx-metadata"
BIN = PROJECT_ROOT / "zig-out" / "bin" / "wizp"
RPC_URL = "http://127.0.0.1:9876/api/rpc"
LANE_BASELINE_LANES = [
    "language/tooling",
    "debug/tooling",
    "scm/cloud/remote",
    "ai/agent",
    "extension pack",
]
SUPPORTED_LANGUAGE_CONTRIBUTION_KEYS = [
    "languages",
    "grammars",
    "snippets",
    "viewsContainers",
    "views",
    "viewsWelcome",
    "breakpoints",
    "jsonValidation",
    "resourceLabelFormatters",
    "problemMatchers",
    "taskDefinitions",
    "debuggers",
    "iconThemes",
    "walkthroughs",
    "themes",
    "semanticTokenScopes",
    "semanticTokenTypes",
    "semanticTokenModifiers",
    "customEditors",
    "languageModelTools",
    "yamlValidation",
    "debugVisualizers",
    "javaExtensions",
    "javaBuildFilePatterns",
    "javaBuildTools",
    "javaShortcuts",
    "chatParticipants",
    "chatSessions",
    "icons",
    "mcpServerDefinitionProviders",
]
CURATED = {
    "editorconfig.editorconfig",
    "streetsidesoftware.code-spell-checker",
    "christian-kohler.path-intellisense",
    "christian-kohler.npm-intellisense",
    "formulahendry.auto-close-tag",
    "naumovs.color-highlight",
}

PRESERVED_REPORT_FIELDS = (
    "packages",
    "topOpenVSXLoadability",
    "topOpenVSXThemeIcon",
    "topOpenVSXLaneBaseline",
    "topOpenVSXExtensionPacks",
    "topOpenVSXFormatterRuntime",
    "topOpenVSXLanguageRuntime",
    "topOpenVSXTop20Runtime",
    "officialCodex",
    "loadability",
    "runtimeCommand",
    "runtimeProvider",
    "runtimeNpmProvider",
    "runtimeAutoCloseTag",
    "runtimeColorHighlight",
    "cspellRuntimeProbe",
)
RUNTIME_COMMAND = {
    "extensionId": "editorconfig.editorconfig",
    "command": "EditorConfig.generate",
    "expectedFile": ".editorconfig",
}
RUNTIME_PROVIDER = {
    "extensionId": "christian-kohler.path-intellisense",
    "languageId": "javascript",
    "file": "app.js",
}
RUNTIME_NPM_PROVIDER = {
    "extensionId": "christian-kohler.npm-intellisense",
    "languageId": "javascript",
    "file": "npm-app.js",
}
RUNTIME_AUTO_CLOSE_TAG = {
    "extensionId": "formulahendry.auto-close-tag",
    "command": "auto-close-tag.closeTag",
    "languageId": "html",
    "file": "index.html",
}
RUNTIME_COLOR_HIGHLIGHT = {
    "extensionId": "naumovs.color-highlight",
    "command": "extension.colorHighlight",
    "languageId": "javascript",
    "file": "colors.js",
}
CSPELL_RUNTIME_PROBE = {
    "extensionId": "streetsidesoftware.code-spell-checker",
    "commands": [
        "cSpell.displayCSpellInfo",
        "cSpell.openIssuesPanel",
    ],
}
PRETTIER_RUNTIME = {
    "extensionId": "esbenp.prettier-vscode",
    "languageId": "javascript",
    "file": "prettier-smoke.js",
    "source": "const smoke={foo:'bar',items:[1,2,3]};\nconsole.log(smoke)\n",
}
RUFF_RUNTIME = {
    "extensionId": "charliermarsh.ruff",
    "languageId": "python",
    "file": "ruff_smoke.py",
    "source": "import os\n\n\ndef add(left:int,right:int)->int:\n    return left+right\n\nprint(add(1,2))\n",
    "commands": [
        "ruff.executeAutofix",
        "ruff.executeFormat",
        "ruff.executeOrganizeImports",
        "ruff.debugInformation",
        "ruff.restart",
    ],
}
ESLINT_RUNTIME = {
    "extensionId": "dbaeumer.vscode-eslint",
    "languageId": "javascript",
    "file": "eslint-smoke.js",
    "source": "const unused = 1\nconsole.log('wizp')\n",
    "commands": [
        "eslint.executeAutofix",
        "eslint.showOutputChannel",
        "eslint.restart",
    ],
}
INTELEPHENSE_RUNTIME = {
    "extensionId": "bmewburn.vscode-intelephense-client",
    "languageId": "php",
    "file": "diagnostics-smoke.php",
    "badSource": "<?php\nfunction takes_int(int $value): int { return $value; }\n$result = missing_function($undefinedValue);\n",
    "fixedSource": "<?php\nfunction takes_int(int $value): int { return $value; }\n$result = takes_int(1);\n",
}
PYRIGHT_LANGUAGE_RUNTIME = {
    "extensionId": "ms-pyright.pyright",
    "languageId": "python",
    "file": "pyright_smoke.py",
    "source": "def add(left: int, right: int) -> int:\n    return left + right\n\nvalue = add(1, 2)\n",
}
YAML_LANGUAGE_RUNTIME = {
    "extensionId": "redhat.vscode-yaml",
    "languageId": "yaml",
    "file": "yaml-smoke.yaml",
    "source": "name: wizp\nitems:\n  - alpha\n  - beta\n",
}
CLANGD_DEGRADED_RUNTIME = {
    "extensionId": "llvm-vs-code-extensions.vscode-clangd",
    "languageId": "cpp",
    "file": "clangd-smoke.cpp",
    "source": "int add(int left, int right) { return left + right; }\nint main() { return add(1, 2); }\n",
    "missingPath": "/tmp/wizp-missing-clangd-binary",
}
TAILWIND_LANGUAGE_RUNTIME = {
    "extensionId": "bradlc.vscode-tailwindcss",
    "languageId": "html",
    "file": "tailwind-smoke.html",
    "source": '<div class="text-red-500 hover:bg-blue-100">\n  Tailwind smoke\n</div>\n',
    "configFile": "tailwind.config.js",
    "configSource": "module.exports = { content: ['./tailwind-smoke.html'], theme: { extend: {} }, plugins: [] };\n",
}
VUE_LANGUAGE_RUNTIME = {
    "extensionId": "Vue.volar",
    "languageId": "vue",
    "file": "src/App.vue",
    "source": '<template>\n  <main>{{ message }}</main>\n</template>\n\n<script setup lang="ts">\nconst message: string = "wizp"\n</script>\n',
    "packageJson": '{"private":true,"dependencies":{"vue":"^3.5.0"},"devDependencies":{"typescript":"^5.6.0"}}\n',
    "tsconfig": '{"compilerOptions":{"target":"ES2022","module":"ESNext","moduleResolution":"Bundler","strict":true},"include":["src/**/*.vue"]}\n',
}
PYREFLY_DEGRADED_RUNTIME = {
    "extensionId": "meta.pyrefly",
    "languageId": "python",
    "file": "pyrefly_smoke.py",
    "source": "def add(left: int, right: int) -> int:\n    return left + right\n\nvalue = add(1, 2)\n",
}
TOP20_PYTHON_RUNTIME_TARGETS = {
    "python": {
        "extensionId": "ms-python.python",
        "event": "onLanguage:python",
        "languageId": "python",
        "file": "python_main_smoke.py",
        "source": 'print("wizp")\n',
        "configuration": {
            "python": {
                "experiments": {"enabled": False},
                "terminal": {"activateEnvironment": False},
                "analysis": {"downloadChannel": "off"},
            }
        },
        "activationTimeoutMs": 10000,
        "activationEventTimeout": 25.0,
        "maxSpawnedProcesses": 0,
        "maxForkedProcesses": 0,
        "maxNetworkAudit": 0,
        "allowActivationHostTimeout": True,
        "expectedDebuggerTypes": ["python"],
        "status": "python-extension-host-timeout-recovered",
        "blockedStatus": "blocked-python-extension-activation",
    },
    "debugpy": {
        "extensionId": "ms-python.debugpy",
        "event": "onLanguage:python",
        "languageId": "python",
        "file": "debugpy_smoke.py",
        "source": 'print("wizp")\n',
        "configuration": {
            "python": {
                "experiments": {"enabled": False},
                "terminal": {"activateEnvironment": False},
            }
        },
        "expectedProviderCounts": {
            "portAttributes": 1,
            "debugVisualizationTree": 1,
            "debugVisualizations": 1,
        },
        "status": "debugpy-debug-provider-runtime-verified",
        "blockedStatus": "blocked-debugpy-debug-provider",
    },
    "pythonEnvs": {
        "extensionId": "ms-python.vscode-python-envs",
        "event": "onLanguage:python",
        "languageId": "python",
        "file": "envs_smoke.py",
        "source": 'print("wizp")\n',
        "configuration": {
            "python": {
                "experiments": {"enabled": False},
                "terminal": {"activateEnvironment": False},
            }
        },
        "expectedProviderCounts": {
            "completions": 1,
        },
        "expectedUiMarkers": [
            "Registering pyenv manager",
            "Registering pipenv manager",
            "Registering poetry manager",
        ],
        "maxSpawnedProcesses": 2,
        "status": "python-envs-manager-runtime-bounded",
        "blockedStatus": "blocked-python-envs-manager",
    },
}
PYTHON_PACK_EXTENSION_ID = "ms-python.python"
PYTHON_PACK_AVAILABLE_CHILDREN = {
    "debugpy": "ms-python.debugpy",
    "pythonEnvs": "ms-python.vscode-python-envs",
}
PYTHON_PACK_UNAVAILABLE_CHILDREN = ["ms-python.vscode-pylance"]
TOP20_JAVA_RUNTIME_TARGETS = {
    "javaDependency": {
        "extensionId": "vscjava.vscode-java-dependency",
        "event": "onLanguage:java",
        "languageId": "java",
        "file": "src/main/java/App.java",
        "source": 'public class App { public static void main(String[] args) { System.out.println("wizp"); } }\n',
        "workspaceFiles": {
            "pom.xml": "<project><modelVersion>4.0.0</modelVersion><groupId>wizp</groupId><artifactId>smoke</artifactId><version>1</version></project>\n",
        },
        "configuration": {
            "java": {
                "home": "/tmp/wizp-missing-java-home",
                "jdt": {"ls": {"java": {"home": "/tmp/wizp-missing-java-home"}}},
            },
            "maven": {"executable": {"path": "/tmp/wizp-missing-mvn"}},
        },
        "allowAlreadyActive": True,
        "expectedUiMarkers": ["javaProjectExplorer"],
        "status": "java-dependency-activation-bounded",
        "blockedStatus": "blocked-java-dependency-activation",
    },
    "javaDebug": {
        "extensionId": "vscjava.vscode-java-debug",
        "event": "onDebugInitialConfigurations",
        "languageId": "java",
        "file": "src/main/java/App.java",
        "source": 'public class App { public static void main(String[] args) { System.out.println("wizp"); } }\n',
        "workspaceFiles": {
            "pom.xml": "<project><modelVersion>4.0.0</modelVersion><groupId>wizp</groupId><artifactId>smoke</artifactId><version>1</version></project>\n",
        },
        "configuration": {
            "java": {
                "home": "/tmp/wizp-missing-java-home",
                "jdt": {"ls": {"java": {"home": "/tmp/wizp-missing-java-home"}}},
            }
        },
        "expectedDebuggerTypes": ["java"],
        "expectedUiCommands": ["java.debug.breakpoints.exceptionTypes"],
        "status": "java-debug-activation-bounded",
        "blockedStatus": "blocked-java-debug-activation",
    },
    "javaMaven": {
        "extensionId": "vscjava.vscode-maven",
        "event": "workspaceContains:pom.xml",
        "languageId": "xml",
        "file": "pom.xml",
        "source": "<project><modelVersion>4.0.0</modelVersion><groupId>wizp</groupId><artifactId>smoke</artifactId><version>1</version></project>\n",
        "configuration": {
            "java": {
                "home": "/tmp/wizp-missing-java-home",
                "jdt": {"ls": {"java": {"home": "/tmp/wizp-missing-java-home"}}},
            },
            "maven": {"executable": {"path": "/tmp/wizp-missing-mvn"}},
        },
        "allowAlreadyActive": True,
        "status": "java-maven-activation-bounded",
        "blockedStatus": "blocked-java-maven-activation",
    },
    "javaGradle": {
        "extensionId": "vscjava.vscode-gradle",
        "event": "workspaceContains:build.gradle",
        "languageId": "groovy",
        "file": "build.gradle",
        "source": "plugins { id 'java' }\nrepositories { mavenCentral() }\n",
        "workspaceFiles": {
            "settings.gradle": "pluginManagement { repositories { gradlePluginPortal(); mavenCentral() } }\ndependencyResolutionManagement { repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS); repositories { mavenCentral() } }\nrootProject.name='wizp-smoke'\n",
        },
        "configuration": {
            "java": {
                "home": "/tmp/wizp-missing-java-home",
                "jdt": {"ls": {"java": {"home": "/tmp/wizp-missing-java-home"}}},
            },
            "gradle": {"javaDebug": {"cleanOutput": False}},
        },
        "allowAlreadyActive": True,
        "expectedUiMarkers": ["gradleTasksView", "gradleDaemonsView", "recentTasksView", "gradleDefaultProjectsView"],
        "status": "java-gradle-activation-bounded",
        "blockedStatus": "blocked-java-gradle-activation",
    },
    "javaTest": {
        "extensionId": "vscjava.vscode-java-test",
        "event": "onLanguage:java",
        "languageId": "java",
        "file": "src/test/java/AppTest.java",
        "source": "class AppTest { @org.junit.jupiter.api.Test void ok() {} }\n",
        "workspaceFiles": {
            "pom.xml": "<project><modelVersion>4.0.0</modelVersion><groupId>wizp</groupId><artifactId>smoke</artifactId><version>1</version></project>\n",
        },
        "configuration": {
            "java": {
                "home": "/tmp/wizp-missing-java-home",
                "jdt": {"ls": {"java": {"home": "/tmp/wizp-missing-java-home"}}},
            }
        },
        "allowAlreadyActive": True,
        "status": "java-test-activation-bounded",
        "blockedStatus": "blocked-java-test-activation",
    },
}
TOP20_CLOUD_REMOTE_RUNTIME_TARGETS = {
    "containers": {
        "extensionId": "ms-azuretools.vscode-containers",
        "event": "onLanguage:dockerfile",
        "languageId": "dockerfile",
        "file": "Dockerfile",
        "source": "FROM scratch\n",
        "configuration": {
            "containers": {
                "containerCommand": "/tmp/wizp-missing-docker",
                "orchestratorCommand": "/tmp/wizp-missing-docker-compose",
            }
        },
        "activationTimeoutMs": 20000,
        "activationEventTimeout": 30.0,
        "expectedDebuggerTypes": ["docker"],
        "maxForkedProcesses": 2,
        "status": "containers-missing-docker-bounded",
        "blockedStatus": "blocked-containers-activation",
    },
    "gitlens": {
        "extensionId": "eamodio.gitlens",
        "event": "onStartupFinished",
        "languageId": "plaintext",
        "file": "README.md",
        "source": "# gitlens smoke\n",
        "workspaceFiles": {".gitignore": "node_modules\n"},
        "configuration": {
            "gitlens": {
                "ai": {"enabled": False},
                "plusFeatures": {"enabled": False},
                "telemetry": {"enabled": False},
            }
        },
        "activationTimeoutMs": 20000,
        "activationEventTimeout": 30.0,
        "maxSpawnedProcesses": 2,
        "expectedNetworkAudit": ["https://configs.gitkraken.dev/gitlens/product.json"],
        "status": "gitlens-offline-startup-bounded",
        "blockedStatus": "blocked-gitlens-activation",
    },
}
TOP20_PHP_RUNTIME_TARGETS = {
    "phpComposer": {
        "extensionId": "devsense.composer-php-vscode",
        "event": "workspaceContains:composer.json",
        "languageId": "json",
        "file": "composer.json",
        "source": '{"require": {}}\n',
        "configuration": {
            "composer": {"bin": "/tmp/wizp-missing-composer.phar"},
            "php": {"executablePath": "/tmp/wizp-missing-php-binary"},
        },
        "activationTimeoutMs": 3000,
        "activationEventTimeout": 12.0,
        "maxSpawnedProcesses": 0,
        "maxForkedProcesses": 0,
        "maxNetworkAudit": 1,
        "status": "composer-workspace-activation-bounded",
        "blockedStatus": "blocked-composer-activation",
    },
    "phpProfiler": {
        "extensionId": "devsense.profiler-php-vscode",
        "event": "onCommand:phpprofiler.openfile",
        "languageId": "php",
        "file": "profile-smoke.php",
        "source": '<?php echo "wizp";\n',
        "maxSpawnedProcesses": 0,
        "maxForkedProcesses": 0,
        "maxNetworkAudit": 1,
        "status": "php-profiler-command-activation-audited-telemetry",
        "blockedStatus": "blocked-php-profiler-activation",
    },
    "phpTools": {
        "extensionId": "devsense.phptools-vscode",
        "event": "onLanguage:php",
        "languageId": "php",
        "file": "index.php",
        "source": "<?php\nfunction add($a, $b) { return $a + $b; }\necho add(1, 2);\n",
        "configuration": {"php": {"executablePath": "/tmp/wizp-missing-php-binary"}},
        "activationTimeoutMs": 10000,
        "activationEventTimeout": 25.0,
        "maxSpawnedProcesses": 2,
        "maxForkedProcesses": 2,
        "maxNetworkAudit": 0,
        "allowActivationHostTimeout": True,
        "expectedDebuggerTypes": ["php"],
        "status": "phptools-missing-php-bounded",
        "blockedStatus": "blocked-phptools-activation",
    },
}
TOP20_AI_AGENT_RUNTIME_TARGETS = {
    "claudeCode": {
        "extensionId": "Anthropic.claude-code",
        "event": "startup",
        "languageId": "plaintext",
        "file": "README.md",
        "source": "# claude smoke\n",
        "configuration": {"claudeCode": {"disableLoginPrompt": True, "useTerminal": False}},
        "activationTimeoutMs": 10000,
        "activationEventTimeout": 25.0,
        "maxSpawnedProcesses": 0,
        "maxForkedProcesses": 0,
        "maxNetworkAudit": 0,
        "allowActivationHostTimeout": True,
        "status": "claude-code-startup-host-timeout-recovered",
        "blockedStatus": "blocked-claude-code-activation",
    },
}
TOP20_TARGETED_RUNTIME_TARGETS = {
    **TOP20_PYTHON_RUNTIME_TARGETS,
    **TOP20_JAVA_RUNTIME_TARGETS,
    **TOP20_CLOUD_REMOTE_RUNTIME_TARGETS,
    **TOP20_PHP_RUNTIME_TARGETS,
    **TOP20_AI_AGENT_RUNTIME_TARGETS,
}
RUST_ANALYZER_DEGRADED_RUNTIME = {
    "extensionId": "rust-lang.rust-analyzer",
    "languageId": "rust",
    "file": "src/main.rs",
    "source": "fn main() {\n    println!(\"wizp\");\n}\n",
    "cargoToml": "[package]\nname = \"wizp_ra_smoke\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n",
    "missingPath": "/tmp/wizp-missing-rust-analyzer-binary",
}
REDHAT_JAVA_BOUNDED_RUNTIME = {
    "extensionId": "redhat.java",
    "languageId": "java",
    "file": "src/main/java/Smoke.java",
    "source": 'public class Smoke { public static void main(String[] args) { System.out.println("wizp"); } }\n',
    "pomXml": '<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion><groupId>wizp</groupId><artifactId>smoke</artifactId><version>0.1.0</version></project>\n',
    "missingJavaHome": "/tmp/wizp-missing-java-home",
}
GO_DEGRADED_RUNTIME = {
    "extensionId": "golang.Go",
    "languageId": "go",
    "file": "main.go",
    "source": 'package main\n\nimport "fmt"\n\nfunc main() { fmt.Println("wizp") }\n',
    "goMod": "module wizp_smoke\n\ngo 1.22\n",
    "missingGo": "/tmp/wizp-missing-go-binary",
    "missingGopls": "/tmp/wizp-missing-gopls-binary",
}
RUBY_LSP_DEGRADED_RUNTIME = {
    "extensionId": "Shopify.ruby-lsp",
    "languageId": "ruby",
    "file": "smoke.rb",
    "source": 'def hello(name)\n  "hello #{name}"\nend\n\nputs hello("wizp")\n',
    "gemfile": 'source "https://rubygems.org"\n',
    "gemfileLock": "GEM\n  specs:\n\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n\nBUNDLED WITH\n   2.5.0\n",
    "missingRuby": "/tmp/wizp-missing-ruby-binary",
}
DART_CODE_DEGRADED_RUNTIME = {
    "extensionId": "Dart-Code.dart-code",
    "languageId": "dart",
    "file": "lib/main.dart",
    "source": "void main() {\n  print('wizp');\n}\n",
    "pubspec": "name: wizp_dart_smoke\nenvironment:\n  sdk: '>=3.0.0 <4.0.0'\n",
    "analysisOptions": "analyzer:\n  exclude:\n    - build/**\n",
    "missingDartSdk": "/tmp/wizp-missing-dart-sdk",
    "missingFlutterSdk": "/tmp/wizp-missing-flutter-sdk",
}
OFFICIAL_CODEX = {
    "extensionId": "openai.chatgpt",
    "requiredCommands": [
        "chatgpt.implementTodo",
        "chatgpt.openSidebar",
        "chatgpt.openCommandMenu",
        "chatgpt.newCodexPanel",
        "chatgpt.addToThread",
        "chatgpt.addFileToThread",
        "chatgpt.newChat",
        "chatgpt.showLspMcpCliArgs",
        "chatgpt.dumpNuxState",
        "chatgpt.resetNuxState",
    ],
    "cliExecutableSetting": "chatgpt.cliExecutable",
    "openOnStartupSetting": "chatgpt.openOnStartup",
    "chatSessionType": "openai-codex",
    "chatSessionName": "Codex",
    "webviewViews": [
        "chatgpt.sidebarView",
        "chatgpt.sidebarSecondaryView",
    ],
    "uiWorkflowCommands": [
        "chatgpt.openSidebar",
        "chatgpt.openCommandMenu",
        "chatgpt.newCodexPanel",
        "chatgpt.showLspMcpCliArgs",
        "chatgpt.dumpNuxState",
        "chatgpt.resetNuxState",
    ],
    "contextWorkflowCommands": [
        "chatgpt.addToThread",
        "chatgpt.addFileToThread",
    ],
    "authenticatedTurnCommands": [
        "chatgpt.implementTodo",
        "chatgpt.newChat",
    ],
}


def _free_port() -> int:
    requested = os.environ.get("WIZP_REAL_EXTENSION_PORT")
    if requested:
        parsed = int(requested)
        if parsed < 1024 or parsed > 65535:
            raise AssertionError(f"invalid WIZP_REAL_EXTENSION_PORT: {requested}")
        return parsed
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _fetch_json(url: str) -> dict:
    cache_path = _openvsx_metadata_cache_path(url)
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
        if isinstance(payload, dict):
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            cache_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
        return payload
    except Exception:
        if cache_path.exists():
            return json.loads(cache_path.read_text(encoding="utf-8"))
        synthesized = _synthesized_openvsx_metadata(url)
        if synthesized is not None:
            return synthesized
        raise


def _download(url: str, target: Path) -> None:
    if target.exists() and target.stat().st_size > 0:
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme == "file":
        source_path = Path(urllib.parse.unquote(parsed.path))
        if not source_path.exists():
            raise FileNotFoundError(source_path)
        if source_path.resolve() != target.resolve():
            shutil.copyfile(source_path, target)
        return
    request = urllib.request.Request(url, headers={"User-Agent": "WIZP parity real-extension smoke"})
    with urllib.request.urlopen(request, timeout=60) as response, target.open("wb") as output:
        shutil.copyfileobj(response, output)


def _safe_extension_filename(extension_id: str, version: str) -> str:
    return f"{extension_id.replace('/', '.').replace(' ', '_')}-{version}.vsix"


def _openvsx_metadata_cache_path(url: str) -> Path:
    parsed = urllib.parse.urlparse(url)
    safe_path = (parsed.netloc + parsed.path).strip("/").replace("/", "__")
    if not safe_path:
        safe_path = "root"
    return OPENVSX_METADATA_CACHE / f"{safe_path}.json"


def _openvsx_extension_id_from_url(url: str) -> str | None:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in {"http", "https"} or parsed.netloc != "open-vsx.org":
        return None
    parts = [part for part in parsed.path.split("/") if part]
    if len(parts) < 3 or parts[0] != "api":
        return None
    return f"{parts[1]}.{parts[2]}"


def _cached_vsix_version(extension_id: str, vsix_path: Path) -> str | None:
    prefix = f"{extension_id.replace('/', '.').replace(' ', '_')}-"
    suffix = ".vsix"
    name = vsix_path.name
    if not name.startswith(prefix) or not name.endswith(suffix):
        return None
    return name[len(prefix):-len(suffix)] or None


def _find_cached_vsix(extension_id: str) -> Path | None:
    parity_root = PROJECT_ROOT / "build" / "parity-real-extensions"
    pattern = f"**/{extension_id.replace('/', '.').replace(' ', '_')}-*.vsix"
    candidates = [path for path in parity_root.glob(pattern) if path.is_file()]
    if not candidates:
        return None
    return max(candidates, key=lambda path: (path.stat().st_mtime, path.stat().st_size, str(path)))


def _synthesized_openvsx_metadata(url: str) -> dict | None:
    extension_id = _openvsx_extension_id_from_url(url)
    if extension_id is None:
        return None
    cached_vsix = _find_cached_vsix(extension_id)
    if cached_vsix is None:
        return None
    namespace, extension_name = extension_id.split(".", 1)
    version = _cached_vsix_version(extension_id, cached_vsix) or "unknown"
    return {
        "namespace": namespace,
        "name": extension_name,
        "version": version,
        "files": {
            "download": cached_vsix.resolve().as_uri(),
        },
        "_wizpCachedSource": "local-vsix-fallback",
        "_wizpCachedVsixPath": str(cached_vsix),
    }


def _vsix_manifest(vsix_path: Path) -> dict:
    with zipfile.ZipFile(vsix_path) as archive:
        names = set(archive.namelist())
        if "extension/package.json" not in names:
            raise AssertionError(f"{vsix_path.name} is missing extension/package.json")
        manifest = json.loads(archive.read("extension/package.json").decode("utf-8"))
        if "extension.vsixmanifest" not in names and "extension/.vsixmanifest" not in names:
            raise AssertionError(f"{vsix_path.name} is missing a VSIX manifest")
        return manifest


def _host_machine_name() -> str:
    machine = platform.machine().lower()
    aliases = {
        "amd64": "x86_64",
        "x64": "x86_64",
        "arm64": "aarch64",
    }
    return aliases.get(machine, machine or "unknown")


def _elf_machine(path: Path) -> dict:
    data = path.read_bytes()[:64]
    if data[:4] != b"\x7fELF":
        return {"format": "not-elf"}
    endian = "little" if data[5] == 1 else "big" if data[5] == 2 else "unknown"
    byteorder = endian if endian in {"little", "big"} else "little"
    machine = int.from_bytes(data[18:20], byteorder)
    machine_names = {
        3: "x86",
        40: "arm",
        62: "x86_64",
        183: "aarch64",
        243: "riscv64",
    }
    return {
        "format": "elf",
        "class": {1: "32", 2: "64"}.get(data[4], "unknown"),
        "endian": endian,
        "machine": machine,
        "machineName": machine_names.get(machine, f"unknown-{machine}"),
    }


def _binary_run_probe(path: Path) -> dict:
    try:
        completed = subprocess.run(
            [str(path), "--version"],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
        return {
            "status": "runnable" if completed.returncode == 0 else "exited-nonzero",
            "returnCode": completed.returncode,
            "stdout": completed.stdout.strip()[:500],
            "stderr": completed.stderr.strip()[:500],
        }
    except OSError as exc:
        return {
            "status": "os-error",
            "error": str(exc),
        }
    except subprocess.TimeoutExpired:
        return {
            "status": "timeout",
        }


def _binary_probe(path: Path) -> dict:
    exists = path.exists()
    host = _host_machine_name()
    result = {
        "path": str(path),
        "exists": exists,
        "hostMachine": host,
    }
    if not exists:
        return result
    elf = _elf_machine(path)
    result.update(
        {
            "mode": oct(path.stat().st_mode & 0o777),
            "elf": elf,
            "hostCompatible": elf.get("format") != "elf" or elf.get("machineName") == host,
            "runProbe": _binary_run_probe(path),
        }
    )
    return result


def _manifest_commands(manifest: dict) -> list[str]:
    contributes = manifest.get("contributes", {})
    if not isinstance(contributes, dict):
        return []
    commands = contributes.get("commands", [])
    if not isinstance(commands, list):
        return []
    result: list[str] = []
    for item in commands:
        if isinstance(item, dict) and isinstance(item.get("command"), str):
            result.append(item["command"])
    return result


def _manifest_named_contributions(manifest: dict, key: str) -> list[dict]:
    contributes = manifest.get("contributes", {})
    if not isinstance(contributes, dict):
        return []
    values = contributes.get(key, [])
    if not isinstance(values, list):
        return []
    return [item for item in values if isinstance(item, dict)]


def _manifest_contribution_ids(manifest: dict, key: str) -> list[str]:
    result: list[str] = []
    for item in _manifest_named_contributions(manifest, key):
        value = item.get("id")
        if not isinstance(value, str) and key == "themes":
            value = item.get("label")
        if isinstance(value, str) and value:
            result.append(value)
    return result


def _manifest_contribution_paths(manifest: dict, key: str) -> list[str]:
    result: list[str] = []
    for item in _manifest_named_contributions(manifest, key):
        value = item.get("path")
        if isinstance(value, str) and value:
            result.append(value)
    return result


def _manifest_contribution_count(manifest: dict, key: str) -> int:
    contributes = manifest.get("contributes", {})
    if not isinstance(contributes, dict):
        return 0
    value = contributes.get(key)
    if key == "grammars" and isinstance(value, list):
        return len(
            [
                item
                for item in value
                if isinstance(item, dict)
                and isinstance(item.get("language"), str)
                and isinstance(item.get("scopeName"), str)
                and isinstance(item.get("path"), str)
            ]
        )
    if key == "walkthroughs":
        return len(value) if isinstance(value, dict) else 0
    if key in {
        "semanticTokenScopes",
        "semanticTokenTypes",
        "semanticTokenModifiers",
        "customEditors",
        "languageModelTools",
        "yamlValidation",
        "debugVisualizers",
        "javaExtensions",
        "javaBuildFilePatterns",
        "javaBuildTools",
        "javaShortcuts",
        "chatParticipants",
        "chatSessions",
        "icons",
        "mcpServerDefinitionProviders",
    }:
        if isinstance(value, list):
            return len(value)
        if isinstance(value, dict):
            return len(value)
        return 1 if value is not None else 0
    if isinstance(value, list):
        return len([item for item in value if isinstance(item, dict)])
    if isinstance(value, dict):
        return len(value)
    return 0


def _manifest_contribution_counts(manifest: dict) -> dict[str, int]:
    return {
        key: _manifest_contribution_count(manifest, key)
        for key in SUPPORTED_LANGUAGE_CONTRIBUTION_KEYS
        if _manifest_contribution_count(manifest, key) > 0
    }


def _manifest_configuration_properties(manifest: dict) -> list[str]:
    contributes = manifest.get("contributes", {})
    if not isinstance(contributes, dict):
        return []
    configs = contributes.get("configuration")
    sections = configs if isinstance(configs, list) else [configs]
    result: list[str] = []
    for section in sections:
        if not isinstance(section, dict):
            continue
        properties = section.get("properties", {})
        if not isinstance(properties, dict):
            continue
        result.extend(str(key) for key in properties.keys())
    return sorted(result)


def _package_record(extension_id: str, metadata: dict, cache_dir: Path) -> dict:
    download_url = metadata.get("files", {}).get("download")
    if not download_url:
        return {
            "id": extension_id,
            "version": str(metadata.get("version") or "unknown"),
            "status": "unsupported-no-openvsx-download-url",
            "blockedReason": "OpenVSX metadata has no downloadable VSIX URL",
        }
    version = str(metadata.get("version") or "unknown")
    vsix_path = cache_dir / _safe_extension_filename(extension_id, version)
    _download(download_url, vsix_path)
    manifest = _vsix_manifest(vsix_path)
    publisher = str(manifest.get("publisher") or "")
    package_name = str(manifest.get("name") or "")
    if not publisher or not package_name:
        return {
            "id": extension_id,
            "version": version,
            "cachePath": str(vsix_path),
            "downloadBytes": vsix_path.stat().st_size,
            "status": "unsupported-manifest-missing-publisher-or-name",
            "blockedReason": "extension/package.json lacks publisher or name",
        }
    contributes = manifest.get("contributes", {})
    activation_events = manifest.get("activationEvents", [])
    return {
        "id": extension_id,
        "manifestId": f"{publisher}.{package_name}",
        "version": version,
        "cachePath": str(vsix_path),
        "downloadBytes": vsix_path.stat().st_size,
        "downloadUrl": download_url,
        "activationEvents": len(activation_events) if isinstance(activation_events, list) else 0,
        "contributes": sorted(contributes.keys()) if isinstance(contributes, dict) else [],
        "commands": _manifest_commands(manifest),
        "main": manifest.get("main"),
        "browser": manifest.get("browser"),
        "extensionKind": manifest.get("extensionKind"),
        "extensionPack": manifest.get("extensionPack") if isinstance(manifest.get("extensionPack"), list) else [],
        "extensionDependencies": manifest.get("extensionDependencies") if isinstance(manifest.get("extensionDependencies"), list) else [],
        "status": "downloaded-and-manifest-verified",
    }


def _install_vsix(vsix_path: Path, install_root: Path, manifest: dict) -> Path:
    publisher = str(manifest.get("publisher") or "unknown")
    name = str(manifest.get("name") or vsix_path.stem)
    install_dir = install_root / f"{publisher}.{name}"
    if install_dir.exists():
        shutil.rmtree(install_dir)
    install_dir.mkdir(parents=True)
    with zipfile.ZipFile(vsix_path) as archive:
        for member in archive.infolist():
            source_name = member.filename
            if not source_name.startswith("extension/") or member.is_dir():
                continue
            relative = PurePosixPath(source_name).relative_to("extension")
            if not relative.parts or any(part in {"", ".", ".."} for part in relative.parts):
                raise AssertionError(f"unsafe VSIX member path: {source_name}")
            target = install_dir.joinpath(*relative.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(member) as source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
            mode = (member.external_attr >> 16) & 0o777
            if mode & 0o111:
                target.chmod(target.stat().st_mode | 0o111)
    package_json = install_dir / "package.json"
    if not package_json.exists():
        raise AssertionError(f"installed extension lacks package.json: {install_dir}")
    return install_dir


def _rpc(method: str, params: dict | None = None, request_id: int = 1, timeout: float = 30.0):
    body: dict = {"jsonrpc": "2.0", "id": request_id, "method": method}
    if params is not None:
        body["params"] = params
    data = json.dumps(body, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(
        RPC_URL,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        payload = json.loads(response.read().decode("utf-8"))
    if "error" in payload:
        raise AssertionError(f"{method} returned error: {payload}")
    return payload["result"]


def _poll_extension_ui() -> list:
    url = RPC_URL.rsplit("/api/rpc", 1)[0] + "/api/extension/ui/poll"
    try:
        with urllib.request.urlopen(url, timeout=5) as response:
            payload = json.loads(response.read().decode("utf-8"))
            return payload if isinstance(payload, list) else []
    except Exception:
        return []


def _wait_for_server(timeout: float = 15.0, required_commands: set[str] | None = None) -> dict | None:
    deadline = time.time() + timeout
    last_payload = None
    while time.time() < deadline:
        try:
            payload = _rpc("extension/commands")
            last_payload = payload
            if not required_commands:
                return payload
            discovered = {
                item.get("command")
                for item in payload.get("commands", [])
                if isinstance(item, dict) and isinstance(item.get("command"), str)
            }
            if required_commands.issubset(discovered):
                return payload
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            pass
        time.sleep(0.1)
    if required_commands:
        raise TimeoutError(
            f"WIZP real extension command surface did not become ready: "
            f"{sorted(required_commands)}; last={last_payload}"
        )
    raise TimeoutError("WIZP HTTP RPC server did not become ready")


def _activation_errors_payload(request_id: int = 22) -> dict:
    try:
        return _rpc("extension/activationErrors", request_id=request_id, timeout=10.0)
    except AssertionError as exc:
        if "Method not found" not in str(exc):
            raise
    except Exception as exc:
        return {"errors": [], "count": 0, "pollError": str(exc)}
    try:
        return _rpc("extensions/activationErrors", request_id=request_id + 1000, timeout=10.0)
    except Exception as exc:
        return {"errors": [], "count": 0, "pollError": str(exc)}


def _activate_by_event(event: str, request_id: int = 31, timeout: float = 30.0) -> dict:
    deadline = time.time() + timeout
    last_error = None
    while time.time() < deadline:
        try:
            return _rpc("extension/activateByEvent", {"event": event}, request_id=request_id, timeout=10.0)
        except AssertionError as exc:
            last_error = exc
            if "Method not found" not in str(exc):
                raise
            time.sleep(0.5)
    raise AssertionError(f"extension/activateByEvent did not become available for {event}: {last_error}")


def _set_active_text_document(params: dict, request_id: int = 41, timeout: float = 30.0) -> dict:
    deadline = time.time() + timeout
    last_error = None
    while time.time() < deadline:
        try:
            return _rpc("extension/activeTextDocument", params, request_id=request_id, timeout=10.0)
        except AssertionError as exc:
            last_error = exc
            if "Method not found" not in str(exc):
                raise
            time.sleep(0.5)
    raise AssertionError(f"extension/activeTextDocument did not become available: {last_error}")


def _update_configuration(params: dict, request_id: int = 45, timeout: float = 30.0) -> dict:
    deadline = time.time() + timeout
    last_error = None
    while time.time() < deadline:
        try:
            return _rpc("extension/updateConfiguration", params, request_id=request_id, timeout=10.0)
        except AssertionError as exc:
            last_error = exc
            if "Method not found" not in str(exc):
                raise
            time.sleep(0.5)
    raise AssertionError(f"extension/updateConfiguration did not become available: {last_error}")


def _wait_for_command_surface(expected_commands: set[str], timeout: float = 30.0) -> tuple[dict, set[str]]:
    deadline = time.time() + timeout
    best_payload: dict = {"commands": []}
    best_commands: set[str] = set()
    while time.time() < deadline:
        payload = _rpc("extension/commands", request_id=121, timeout=10.0)
        discovered = {
            item.get("command")
            for item in payload.get("commands", [])
            if isinstance(item, dict) and isinstance(item.get("command"), str)
        }
        if len(discovered) > len(best_commands):
            best_payload = payload
            best_commands = {cmd for cmd in discovered if isinstance(cmd, str)}
        if expected_commands.issubset(best_commands):
            return best_payload, best_commands
        time.sleep(0.5)
    return best_payload, best_commands


def _run_top20_target_runtime_smoke(name: str, target: dict) -> dict:
    if not BIN.exists():
        return {
            "extensionId": target["extensionId"],
            "status": "blocked-missing-wizp-binary",
            "blockedReason": f"missing WIZP binary: {BIN}; run npm run build first",
        }

    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "top20-runtime-vsix"
    namespace, extension_name = str(target["extensionId"]).split(".", 1)
    metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{extension_name}")
    package = _package_record(str(target["extensionId"]), metadata, cache_dir)
    if package["status"] != "downloaded-and-manifest-verified":
        return {
            "extensionId": target["extensionId"],
            "status": "blocked-package-unavailable",
            "package": package,
        }

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix=f"wizp-top20-{name}-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        for relative, text in target.get("workspaceFiles", {}).items():
            workspace_file = workspace / str(relative)
            workspace_file.parent.mkdir(parents=True, exist_ok=True)
            workspace_file.write_text(str(text), encoding="utf-8")
        source_path = workspace / str(target["file"])
        source_path.parent.mkdir(parents=True, exist_ok=True)
        source_text = str(target["source"])
        source_path.write_text(source_text, encoding="utf-8")

        manifest = _vsix_manifest(Path(str(package["cachePath"])))
        install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_DEFER_STARTUP_EXTENSIONS"] = "0"
        env["WIZP_EXTENSION_ACTIVATION_TIMEOUT_MS"] = str(target.get("activationTimeoutMs", 10000))
        env["WIZP_EXTENSION_CONFIGURATION_JSON"] = json.dumps(target.get("configuration", {}))
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
                start_new_session=True,
            )
            command_payload: dict = {}
            active_document: dict = {}
            activation_result: dict = {}
            activation_errors: dict = {}
            process_result: dict = {}
            debug_state: dict = {}
            provider_result: dict = {}
            ui_events: list = []
            try:
                _wait_for_server(timeout=30.0)
                expected_commands = set(_manifest_commands(manifest))
                command_payload, discovered_commands = _wait_for_command_surface(expected_commands, timeout=30.0)
                missing_commands = sorted(expected_commands - discovered_commands)
                active_document = _set_active_text_document(
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": target["languageId"],
                        "content": source_text,
                        "line": 0,
                        "character": 0,
                        "fireOpen": True,
                    },
                    request_id=701,
                    timeout=10.0,
                )
                try:
                    activation_result = _activate_by_event(
                        str(target["event"]),
                        request_id=702,
                        timeout=float(target.get("activationEventTimeout", 25.0)),
                    )
                except Exception as exc:
                    activation_result = {"error": str(exc), "event": target["event"]}

                expected_counts = target.get("expectedProviderCounts", {})
                expected_markers = [str(marker) for marker in target.get("expectedUiMarkers", [])]
                expected_ui_commands = [str(command) for command in target.get("expectedUiCommands", [])]
                deadline = time.time() + 15.0
                while time.time() < deadline:
                    try:
                        debug_state = _rpc("extension/debugState", request_id=703, timeout=5.0)
                    except Exception as exc:
                        debug_state = {"pollError": str(exc)}
                    try:
                        activation_errors = _activation_errors_payload(request_id=704)
                    except Exception as exc:
                        activation_errors = {"pollError": str(exc)}
                    try:
                        process_result = _rpc("extension/runtimeProcesses", request_id=705, timeout=5.0)
                    except Exception as exc:
                        process_result = {"pollError": str(exc)}
                    ui_events.extend(_poll_extension_ui())
                    provider_counts = debug_state.get("providerCounts", {}) if isinstance(debug_state, dict) else {}
                    counts_ok = all(
                        int(provider_counts.get(key, 0) or 0) >= int(value)
                        for key, value in expected_counts.items()
                    )
                    marker_text = json.dumps(ui_events, sort_keys=True)
                    markers_ok = all(marker in marker_text for marker in expected_markers)
                    commands_ok = all(command in marker_text for command in expected_ui_commands)
                    error_count = int(activation_errors.get("count", 0) or 0) if isinstance(activation_errors, dict) else 0
                    if error_count or (counts_ok and markers_ok and commands_ok):
                        break
                    time.sleep(0.5)

                try:
                    provider_result = _rpc(
                        "extension/languageProviders",
                        {
                            "uri": source_path.resolve().as_uri(),
                            "languageId": target["languageId"],
                            "text": source_text,
                            "line": 0,
                            "character": 0,
                        },
                        request_id=706,
                        timeout=8.0,
                    )
                except Exception as exc:
                    provider_result = {"pollError": str(exc)}
                try:
                    debug_state = _rpc("extension/debugState", request_id=707, timeout=5.0)
                except Exception as exc:
                    debug_state = {"pollError": str(exc)}
                try:
                    activation_errors = _activation_errors_payload(request_id=708)
                except Exception as exc:
                    activation_errors = {"pollError": str(exc)}
                try:
                    process_result = _rpc("extension/runtimeProcesses", request_id=709, timeout=5.0)
                except Exception as exc:
                    process_result = {"pollError": str(exc)}

                provider_counts = debug_state.get("providerCounts", {}) if isinstance(debug_state, dict) else {}
                counts_ok = all(
                    int(provider_counts.get(key, 0) or 0) >= int(value)
                    for key, value in expected_counts.items()
                )
                marker_text = json.dumps(ui_events, sort_keys=True)
                markers_ok = all(marker in marker_text for marker in expected_markers)
                commands_ok = all(command in marker_text for command in expected_ui_commands)
                activation_error_items = activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []
                spawned_processes = process_result.get("spawnedProcesses", []) if isinstance(process_result, dict) else []
                forked_processes = process_result.get("forkedProcesses", []) if isinstance(process_result, dict) else []
                network_audit = process_result.get("networkAudit", []) if isinstance(process_result, dict) else []
                max_spawned_processes = int(target.get("maxSpawnedProcesses", 1))
                max_forked_processes = int(target.get("maxForkedProcesses", 0))
                process_bounded = len(spawned_processes) <= max_spawned_processes and len(forked_processes) <= max_forked_processes
                expected_network = [str(item) for item in target.get("expectedNetworkAudit", [])]
                network_ok = all(
                    any(expected in str(entry.get("options", "")) for entry in network_audit if isinstance(entry, dict))
                    for expected in expected_network
                )
                max_network_audit = target.get("maxNetworkAudit")
                if max_network_audit is not None:
                    network_ok = network_ok and len(network_audit) <= int(max_network_audit)
                debugger_types = [
                    str(entry.get("type"))
                    for entry in _manifest_named_contributions(manifest, "debuggers")
                    if isinstance(entry.get("type"), str)
                ]
                debugger_types_ok = all(
                    expected_type in debugger_types
                    for expected_type in target.get("expectedDebuggerTypes", [])
                )
                host_timeout_errors = [
                    error
                    for error in activation_error_items
                    if str(error.get("name") or "") == "ActivationHostTimeout"
                ]
                activation_ok = (
                    not missing_commands
                    and not activation_error_items
                    and not activation_result.get("error")
                    and (
                        int(activation_result.get("activated", 0) or 0) >= 1
                        or bool(target.get("allowAlreadyActive"))
                    )
                )
                host_timeout_recovered = (
                    bool(target.get("allowActivationHostTimeout"))
                    and bool(host_timeout_errors)
                    and not missing_commands
                    and counts_ok
                    and markers_ok
                    and commands_ok
                    and debugger_types_ok
                    and process_bounded
                    and network_ok
                )
                status = str(target["blockedStatus"])
                if activation_ok and counts_ok and markers_ok and commands_ok and debugger_types_ok and process_bounded and network_ok:
                    status = str(target["status"])
                elif host_timeout_recovered:
                    status = str(target.get("hostTimeoutStatus") or target["status"])
                blocked_reason = None
                if status == target["blockedStatus"]:
                    blocked_reason = (
                        f"activationOk={activation_ok}; countsOk={counts_ok}; markersOk={markers_ok}; "
                        f"commandsOk={commands_ok}; debuggerTypesOk={debugger_types_ok}; processBounded={process_bounded}; networkOk={network_ok}; "
                        f"missingCommands={missing_commands[:10]}; errors={activation_error_items[:3]}"
                    )

                return {
                    "port": port,
                    "extensionId": target["extensionId"],
                    "version": package.get("version"),
                    "package": package,
                    "installDirName": install_path.name,
                    "packageJsonExists": (install_path / "package.json").exists(),
                    "languageId": target["languageId"],
                    "sourceFile": str(source_path),
                    "activeDocument": active_document,
                    "commandCount": len(command_payload.get("commands", [])) if isinstance(command_payload, dict) else 0,
                    "missingCommands": missing_commands,
                    "activationResult": activation_result,
                    "activationErrors": activation_errors,
                    "runtimeProcesses": process_result,
                    "providerResult": provider_result,
                    "debugState": debug_state,
                    "debuggerTypes": debugger_types,
                    "hostTimeoutRecovered": host_timeout_recovered,
                    "uiEvents": ui_events[-18:],
                    "blockedReason": blocked_reason,
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                    "status": status,
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "extensionId": target["extensionId"],
                    "installDirName": install_path.name,
                    "status": target["blockedStatus"],
                    "blockedReason": str(exc),
                    "activationResult": activation_result,
                    "activationErrors": activation_errors,
                    "runtimeProcesses": process_result,
                    "providerResult": provider_result,
                    "debugState": debug_state,
                    "uiEvents": ui_events[-18:],
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    try:
                        os.killpg(proc.pid, signal.SIGTERM)
                        proc.wait(timeout=5)
                    except Exception:
                        proc.kill()
                        proc.wait(timeout=5)


def _openvsx_package_record_or_unsupported(extension_id: str, cache_dir: Path) -> dict:
    namespace, extension_name = extension_id.split(".", 1)
    try:
        metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{extension_name}")
        return _package_record(extension_id, metadata, cache_dir)
    except urllib.error.HTTPError as exc:
        return {
            "id": extension_id,
            "version": "unknown",
            "status": f"unsupported-openvsx-http-{exc.code}",
            "blockedReason": f"OpenVSX returned HTTP {exc.code}",
        }
    except Exception as exc:
        return {
            "id": extension_id,
            "version": "unknown",
            "status": "unsupported-download-or-manifest-failed",
            "blockedReason": str(exc),
        }


def run_python_pack_runtime_rollup(results: dict) -> dict:
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "top20-runtime-vsix"
    main_runtime = results.get("python") if isinstance(results.get("python"), dict) else {}
    package = main_runtime.get("package") if isinstance(main_runtime.get("package"), dict) else {}
    if package.get("status") != "downloaded-and-manifest-verified":
        package = _openvsx_package_record_or_unsupported(PYTHON_PACK_EXTENSION_ID, cache_dir)
    manifest_children = package.get("extensionPack") if isinstance(package.get("extensionPack"), list) else []
    expected_children = sorted([*PYTHON_PACK_AVAILABLE_CHILDREN.values(), *PYTHON_PACK_UNAVAILABLE_CHILDREN])
    missing_manifest_children = sorted(set(expected_children) - set(manifest_children))
    unexpected_manifest_children = sorted(set(manifest_children) - set(expected_children))

    child_runtime_statuses = {}
    missing_runtime_children = []
    for result_key, child_id in PYTHON_PACK_AVAILABLE_CHILDREN.items():
        result = results.get(result_key) if isinstance(results.get(result_key), dict) else {}
        expected_status = TOP20_TARGETED_RUNTIME_TARGETS[result_key]["status"]
        child_runtime_statuses[child_id] = result.get("status")
        if result.get("status") != expected_status:
            missing_runtime_children.append(child_id)

    unsupported_children = [
        _openvsx_package_record_or_unsupported(child_id, cache_dir)
        for child_id in PYTHON_PACK_UNAVAILABLE_CHILDREN
    ]
    unexpectedly_available_children = [
        child.get("id")
        for child in unsupported_children
        if child.get("status") == "downloaded-and-manifest-verified"
    ]

    main_runtime_ok = main_runtime.get("status") == TOP20_TARGETED_RUNTIME_TARGETS["python"]["status"]
    package_ok = package.get("status") == "downloaded-and-manifest-verified"
    unsupported_children_ok = not unexpectedly_available_children and all(
        str(child.get("status") or "").startswith("unsupported-")
        for child in unsupported_children
    )
    status = "python-pack-main-host-timeout-recovered"
    blocked_reason = None
    if (
        not package_ok
        or not main_runtime_ok
        or missing_manifest_children
        or unexpected_manifest_children
        or missing_runtime_children
        or not unsupported_children_ok
    ):
        status = "blocked-python-pack-runtime-rollup"
        blocked_reason = (
            f"packageOk={package_ok}; mainRuntimeOk={main_runtime_ok}; "
            f"missingManifestChildren={missing_manifest_children}; "
            f"unexpectedManifestChildren={unexpected_manifest_children}; "
            f"missingRuntimeChildren={missing_runtime_children}; "
            f"unexpectedlyAvailableChildren={unexpectedly_available_children}; "
            f"unsupportedChildrenOk={unsupported_children_ok}"
        )

    return {
        "extensionId": PYTHON_PACK_EXTENSION_ID,
        "status": status,
        "blockedReason": blocked_reason,
        "package": package,
        "mainRuntimeStatus": main_runtime.get("status"),
        "mainHostTimeoutRecovered": main_runtime.get("hostTimeoutRecovered"),
        "manifestChildren": manifest_children,
        "childRuntimeStatuses": child_runtime_statuses,
        "unsupportedChildren": unsupported_children,
    }


def run_top20_python_runtime_smoke() -> dict:
    results = {
        name: _run_top20_target_runtime_smoke(name, target)
        for name, target in TOP20_TARGETED_RUNTIME_TARGETS.items()
    }
    results["pythonPack"] = run_python_pack_runtime_rollup(results)
    expected_statuses = {
        name: target["status"]
        for name, target in TOP20_TARGETED_RUNTIME_TARGETS.items()
    }
    expected_statuses["pythonPack"] = "python-pack-main-host-timeout-recovered"
    return {
        **results,
        "status": "top-openvsx-top20-targeted-runtime-verified"
        if all(results[name].get("status") == expected_statuses[name] for name in expected_statuses)
        else "top-openvsx-top20-targeted-partial",
    }


def run_network_package_smoke() -> list[dict]:
    results: list[dict] = []
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "vsix"
    for extension_id in sorted(CURATED):
        namespace, name = extension_id.split(".", 1)
        metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}/latest")
        record = _package_record(extension_id, metadata, cache_dir)
        if record["status"] != "downloaded-and-manifest-verified":
            raise AssertionError(f"{extension_id} failed package verification: {record}")
        results.append(
            {
                **record,
                "status": "downloaded-and-manifest-verified",
            }
        )
    return results


def _top_extension_ids(limit: int) -> list[str]:
    if not OPENVSX_TOP_REPORT.exists():
        raise AssertionError(f"missing top OpenVSX report: {OPENVSX_TOP_REPORT}; run npm run report:openvsx-top")
    data = json.loads(OPENVSX_TOP_REPORT.read_text(encoding="utf-8"))
    extensions = data.get("extensions", [])
    if not isinstance(extensions, list):
        raise AssertionError("top OpenVSX report has no extensions[]")
    result = []
    for item in extensions[:limit]:
        if isinstance(item, dict) and isinstance(item.get("id"), str):
            result.append(item["id"])
    if len(result) < limit:
        raise AssertionError(f"top OpenVSX report had only {len(result)} usable ids for requested limit {limit}")
    return result


def _top_theme_icon_extension_ids(limit: int) -> list[str]:
    if not OPENVSX_TOP_REPORT.exists():
        raise AssertionError(f"missing top OpenVSX report: {OPENVSX_TOP_REPORT}; run npm run report:openvsx-top")
    data = json.loads(OPENVSX_TOP_REPORT.read_text(encoding="utf-8"))
    extensions = data.get("extensions", [])
    if not isinstance(extensions, list):
        raise AssertionError("top OpenVSX report has no extensions[]")
    result = []
    for item in extensions:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str):
            continue
        contributes = set(item.get("contributes", [])) if isinstance(item.get("contributes"), list) else set()
        if item.get("lane") == "theme/icon" or contributes & {"themes", "iconThemes", "productIconThemes"}:
            result.append(item["id"])
        if len(result) >= limit:
            break
    if not result:
        raise AssertionError("top OpenVSX report had no theme/icon contribution candidates")
    return result


def _top_lane_baseline_extension_ids(per_lane_limit: int) -> list[str]:
    if not OPENVSX_TOP_REPORT.exists():
        raise AssertionError(f"missing top OpenVSX report: {OPENVSX_TOP_REPORT}; run npm run report:openvsx-top")
    data = json.loads(OPENVSX_TOP_REPORT.read_text(encoding="utf-8"))
    extensions = data.get("extensions", [])
    if not isinstance(extensions, list):
        raise AssertionError("top OpenVSX report has no extensions[]")
    selected: list[str] = []
    seen: set[str] = set()
    counts = {lane: 0 for lane in LANE_BASELINE_LANES}
    formatter_count = 0
    for item in extensions:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str):
            continue
        extension_id = item["id"]
        lane = str(item.get("lane") or "")
        needs = item.get("needs", [])
        needs_text = " ".join(str(need) for need in needs) if isinstance(needs, list) else ""
        should_select = False
        if lane in counts and counts[lane] < per_lane_limit:
            counts[lane] += 1
            should_select = True
        if "format/lint provider runtime" in needs_text and formatter_count < per_lane_limit:
            formatter_count += 1
            should_select = True
        if should_select and extension_id.lower() not in seen:
            selected.append(extension_id)
            seen.add(extension_id.lower())
    if not selected:
        raise AssertionError("top OpenVSX report had no lane baseline candidates")
    return selected


def _top_extension_pack_ids(limit: int) -> list[str]:
    if not OPENVSX_TOP_REPORT.exists():
        raise AssertionError(f"missing top OpenVSX report: {OPENVSX_TOP_REPORT}; run npm run report:openvsx-top")
    data = json.loads(OPENVSX_TOP_REPORT.read_text(encoding="utf-8"))
    extensions = data.get("extensions", [])
    if not isinstance(extensions, list):
        raise AssertionError("top OpenVSX report has no extensions[]")
    result = []
    for item in extensions:
        if isinstance(item, dict) and item.get("lane") == "extension pack" and isinstance(item.get("id"), str):
            result.append(item["id"])
        if len(result) >= limit:
            break
    if not result:
        raise AssertionError("top OpenVSX report had no extension pack candidates")
    return result


def run_top_openvsx_package_smoke(limit: int) -> dict:
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "top-vsix"
    packages: list[dict] = []
    for extension_id in _top_extension_ids(limit):
        namespace, name = extension_id.split(".", 1)
        try:
            metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
            packages.append(_package_record(extension_id, metadata, cache_dir))
        except Exception as exc:
            packages.append(
                {
                    "id": extension_id,
                    "status": "unsupported-download-or-manifest-failed",
                    "blockedReason": str(exc),
                }
            )
    verified = [item for item in packages if item.get("status") == "downloaded-and-manifest-verified"]
    failed = [item for item in packages if item.get("status") != "downloaded-and-manifest-verified"]
    payload = {
        "requestedLimit": limit,
        "verifiedCount": len(verified),
        "failedCount": len(failed),
        "packages": packages,
        "status": "top-openvsx-packages-manifest-verified" if not failed else "top-openvsx-packages-partial",
    }
    if not BIN.exists():
        payload["loadability"] = {
            "status": "skipped-missing-wizp-binary",
            "blockedReason": f"missing WIZP binary: {BIN}; run npm run build before top-N loadability",
        }
        return payload
    if verified:
        payload["loadability"] = run_top_openvsx_loadability_smoke(verified)
    return payload


def run_top_openvsx_theme_icon_smoke(limit: int) -> dict:
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "theme-icon-vsix"
    packages: list[dict] = []
    for extension_id in _top_theme_icon_extension_ids(limit):
        namespace, name = extension_id.split(".", 1)
        try:
            metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
            record = _package_record(extension_id, metadata, cache_dir)
            manifest = _vsix_manifest(Path(str(record["cachePath"])))
            record["themes"] = _manifest_contribution_ids(manifest, "themes")
            record["iconThemes"] = _manifest_contribution_ids(manifest, "iconThemes")
            record["productIconThemes"] = _manifest_contribution_ids(manifest, "productIconThemes")
            packages.append(record)
        except Exception as exc:
            packages.append(
                {
                    "id": extension_id,
                    "status": "unsupported-download-or-manifest-failed",
                    "blockedReason": str(exc),
                }
            )
    verified = [item for item in packages if item.get("status") == "downloaded-and-manifest-verified"]
    failed = [item for item in packages if item.get("status") != "downloaded-and-manifest-verified"]
    payload = {
        "requestedLimit": limit,
        "selectedCount": len(packages),
        "verifiedCount": len(verified),
        "failedCount": len(failed),
        "packages": packages,
        "status": "top-openvsx-theme-icon-packages-manifest-verified" if not failed else "top-openvsx-theme-icon-packages-partial",
    }
    if not BIN.exists():
        payload["contributionSmoke"] = {
            "status": "skipped-missing-wizp-binary",
            "blockedReason": f"missing WIZP binary: {BIN}; run npm run build before theme/icon smoke",
        }
        return payload
    if verified:
        payload["contributionSmoke"] = run_theme_icon_contribution_smoke(verified)
    return payload


def _wait_for_theme_icon_surface(
    expected_themes: set[str],
    expected_icon_themes: set[str],
    timeout: float = 30.0,
) -> tuple[dict, set[str], set[str]]:
    deadline = time.time() + timeout
    best_payload: dict = {"themes": [], "iconThemes": []}
    best_themes: set[str] = set()
    best_icon_themes: set[str] = set()
    while time.time() < deadline:
        try:
            payload = _rpc("extension/languageContributions", request_id=131, timeout=10.0)
        except AssertionError as exc:
            if "Method not found" not in str(exc):
                raise
            time.sleep(0.5)
            continue
        themes = {
            item.get("id")
            for item in payload.get("themes", [])
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        }
        icon_themes = {
            item.get("id")
            for item in payload.get("iconThemes", [])
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        }
        if len(themes) + len(icon_themes) > len(best_themes) + len(best_icon_themes):
            best_payload = payload
            best_themes = {item for item in themes if isinstance(item, str)}
            best_icon_themes = {item for item in icon_themes if isinstance(item, str)}
        if expected_themes.issubset(best_themes) and expected_icon_themes.issubset(best_icon_themes):
            return best_payload, best_themes, best_icon_themes
        time.sleep(0.5)
    return best_payload, best_themes, best_icon_themes


def run_theme_icon_contribution_smoke(packages: list[dict]) -> dict:
    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-theme-icon-openvsx-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        installed = []
        expected_themes: list[str] = []
        expected_icon_themes: list[str] = []
        expected_product_icon_themes: list[str] = []
        missing_paths = []
        for package in packages:
            manifest = _vsix_manifest(Path(str(package["cachePath"])))
            install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)
            theme_ids = _manifest_contribution_ids(manifest, "themes")
            icon_theme_ids = _manifest_contribution_ids(manifest, "iconThemes")
            product_icon_theme_ids = _manifest_contribution_ids(manifest, "productIconThemes")
            expected_themes.extend(theme_ids)
            expected_icon_themes.extend(icon_theme_ids)
            expected_product_icon_themes.extend(product_icon_theme_ids)
            for contribution_key in ("themes", "iconThemes", "productIconThemes"):
                for relative in _manifest_contribution_paths(manifest, contribution_key):
                    if not (install_path / relative).exists():
                        missing_paths.append(
                            {
                                "extensionId": package["id"],
                                "contribution": contribution_key,
                                "path": relative,
                            }
                        )
            installed.append(
                {
                    "id": package["id"],
                    "installDirName": install_path.name,
                    "themeCount": len(theme_ids),
                    "iconThemeCount": len(icon_theme_ids),
                    "productIconThemeCount": len(product_icon_theme_ids),
                    "packageJson": (install_path / "package.json").exists(),
                    "mainExists": _main_exists(install_path, manifest),
                }
            )

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_DEFER_STARTUP_EXTENSIONS"] = "0"
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            try:
                _wait_for_server(timeout=30.0)
                expected_theme_set = set(expected_themes)
                expected_icon_theme_set = set(expected_icon_themes)
                contribution_payload, discovered_themes, discovered_icon_themes = _wait_for_theme_icon_surface(
                    expected_theme_set,
                    expected_icon_theme_set,
                    timeout=30.0,
                )
                missing_themes = sorted(expected_theme_set - discovered_themes)
                missing_icon_themes = sorted(expected_icon_theme_set - discovered_icon_themes)
                activation_errors = _activation_errors_payload(request_id=132)
                activation_error_items = (
                    activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []
                )
                installed_ids = {
                    str(item.get("id", "")).lower()
                    for item in installed
                } | {
                    str(item.get("installDirName", "")).lower()
                    for item in installed
                }
                relevant_activation_errors = [
                    error
                    for error in activation_error_items
                    if str(error.get("extensionId", "")).lower() in installed_ids
                ]
                unsupported_product_icon_themes = sorted(set(expected_product_icon_themes))
                status = "top-openvsx-theme-icon-contributions-verified"
                if (
                    missing_paths
                    or missing_themes
                    or missing_icon_themes
                    or relevant_activation_errors
                    or unsupported_product_icon_themes
                ):
                    status = "top-openvsx-theme-icon-contributions-partial"
                return {
                    "port": port,
                    "installed": installed,
                    "expectedThemeCount": len(expected_theme_set),
                    "discoveredThemeCount": len(discovered_themes),
                    "missingThemes": missing_themes,
                    "expectedIconThemeCount": len(expected_icon_theme_set),
                    "discoveredIconThemeCount": len(discovered_icon_themes),
                    "missingIconThemes": missing_icon_themes,
                    "unsupportedProductIconThemes": unsupported_product_icon_themes,
                    "missingContributionPaths": missing_paths,
                    "themePayloadCount": len(contribution_payload.get("themes", [])) if isinstance(contribution_payload, dict) else 0,
                    "iconThemePayloadCount": len(contribution_payload.get("iconThemes", [])) if isinstance(contribution_payload, dict) else 0,
                    "activationErrors": relevant_activation_errors,
                    "ignoredActivationErrors": [
                        error
                        for error in activation_error_items
                        if error not in relevant_activation_errors
                    ],
                    "startupExtensionsDeferred": True,
                    "status": status,
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "installed": installed,
                    "status": "top-openvsx-theme-icon-contributions-failed",
                    "blockedReason": str(exc),
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def run_top_openvsx_lane_baseline_smoke(per_lane_limit: int) -> dict:
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "lane-baseline-vsix"
    packages: list[dict] = []
    for extension_id in _top_lane_baseline_extension_ids(per_lane_limit):
        namespace, name = extension_id.split(".", 1)
        try:
            metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
            record = _package_record(extension_id, metadata, cache_dir)
            manifest = _vsix_manifest(Path(str(record["cachePath"])))
            record["supportedContributionCounts"] = _manifest_contribution_counts(manifest)
            packages.append(record)
        except Exception as exc:
            packages.append(
                {
                    "id": extension_id,
                    "status": "unsupported-download-or-manifest-failed",
                    "blockedReason": str(exc),
                }
            )
    verified = [item for item in packages if item.get("status") == "downloaded-and-manifest-verified"]
    failed = [item for item in packages if item.get("status") != "downloaded-and-manifest-verified"]
    payload = {
        "perLaneLimit": per_lane_limit,
        "selectedCount": len(packages),
        "verifiedCount": len(verified),
        "failedCount": len(failed),
        "packages": packages,
        "status": "top-openvsx-lane-baseline-packages-manifest-verified" if not failed else "top-openvsx-lane-baseline-packages-partial",
    }
    if not BIN.exists():
        payload["baselineSmoke"] = {
            "status": "skipped-missing-wizp-binary",
            "blockedReason": f"missing WIZP binary: {BIN}; run npm run build before lane baseline smoke",
        }
        return payload
    if verified:
        payload["baselineSmoke"] = run_lane_baseline_contribution_smoke(verified)
    return payload


def run_top_openvsx_extension_pack_smoke(limit: int) -> dict:
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "pack-vsix"
    queue = _top_extension_pack_ids(limit)
    seen: set[str] = set()
    packages: list[dict] = []
    dependency_edges: list[dict] = []
    while queue:
        extension_id = queue.pop(0)
        key = extension_id.lower()
        if key in seen:
            continue
        seen.add(key)
        namespace, name = extension_id.split(".", 1)
        try:
            metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
            record = _package_record(extension_id, metadata, cache_dir)
            if record.get("status") == "downloaded-and-manifest-verified":
                manifest = _vsix_manifest(Path(str(record["cachePath"])))
                child_ids = []
                for field in ("extensionPack", "extensionDependencies"):
                    values = manifest.get(field)
                    if isinstance(values, list):
                        for value in values:
                            if isinstance(value, str) and "." in value:
                                child_ids.append(value)
                                dependency_edges.append(
                                    {
                                        "parent": extension_id,
                                        "child": value,
                                        "kind": field,
                                    }
                                )
                record["extensionPack"] = manifest.get("extensionPack") if isinstance(manifest.get("extensionPack"), list) else []
                record["extensionDependencies"] = manifest.get("extensionDependencies") if isinstance(manifest.get("extensionDependencies"), list) else []
                for child_id in child_ids:
                    if child_id.lower() not in seen:
                        queue.append(child_id)
            packages.append(record)
        except Exception as exc:
            packages.append(
                {
                    "id": extension_id,
                    "status": "unsupported-download-or-manifest-failed",
                    "blockedReason": str(exc),
                }
            )
    verified = [item for item in packages if item.get("status") == "downloaded-and-manifest-verified"]
    failed = [item for item in packages if item.get("status") != "downloaded-and-manifest-verified"]
    unsupported_children = []
    for item in failed:
        child_id = item.get("id")
        parents = [
            edge
            for edge in dependency_edges
            if isinstance(child_id, str) and edge.get("child", "").lower() == child_id.lower()
        ]
        unsupported_children.append(
            {
                "id": child_id,
                "status": item.get("status"),
                "blockedReason": item.get("blockedReason"),
                "parents": parents,
            }
        )
    status = "top-openvsx-extension-packs-expanded-and-manifest-verified"
    if failed:
        status = "top-openvsx-extension-packs-expanded-with-unsupported-children"
    payload = {
        "requestedPackLimit": limit,
        "rootPacks": _top_extension_pack_ids(limit),
        "expandedCount": len(packages),
        "verifiedCount": len(verified),
        "failedCount": len(failed),
        "unsupportedChildren": unsupported_children,
        "dependencyEdges": dependency_edges,
        "packages": packages,
        "status": status,
    }
    if not BIN.exists():
        payload["expandedInstallSmoke"] = {
            "status": "skipped-missing-wizp-binary",
            "blockedReason": f"missing WIZP binary: {BIN}; run npm run build before extension pack smoke",
        }
        return payload
    if verified:
        payload["expandedInstallSmoke"] = run_extension_pack_expanded_install_smoke(verified)
    return payload


def run_extension_pack_expanded_install_smoke(packages: list[dict]) -> dict:
    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-pack-expanded-openvsx-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        installed = []
        expected_commands: list[str] = []
        dependency_counts = {
            "extensionPack": 0,
            "extensionDependencies": 0,
        }
        for package in packages:
            manifest = _vsix_manifest(Path(str(package["cachePath"])))
            install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)
            commands = _manifest_commands(manifest)
            expected_commands.extend(commands)
            dependency_counts["extensionPack"] += len(manifest.get("extensionPack", [])) if isinstance(manifest.get("extensionPack"), list) else 0
            dependency_counts["extensionDependencies"] += len(manifest.get("extensionDependencies", [])) if isinstance(manifest.get("extensionDependencies"), list) else 0
            installed.append(
                {
                    "id": package["id"],
                    "installDirName": install_path.name,
                    "packageJson": (install_path / "package.json").exists(),
                    "mainExists": _main_exists(install_path, manifest),
                    "commandCount": len(commands),
                    "extensionPackCount": len(manifest.get("extensionPack", [])) if isinstance(manifest.get("extensionPack"), list) else 0,
                    "extensionDependencyCount": len(manifest.get("extensionDependencies", [])) if isinstance(manifest.get("extensionDependencies"), list) else 0,
                }
            )

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_DEFER_STARTUP_EXTENSIONS"] = "1"
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            try:
                _wait_for_server(timeout=30.0)
                expected_command_set = set(expected_commands)
                command_payload, discovered_commands = _wait_for_command_surface(expected_command_set, timeout=45.0)
                missing_commands = sorted(expected_command_set - discovered_commands)
                activation_errors = _activation_errors_payload(request_id=152)
                activation_error_items = (
                    activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []
                )
                installed_ids = {
                    str(item.get("id", "")).lower()
                    for item in installed
                } | {
                    str(item.get("installDirName", "")).lower()
                    for item in installed
                }
                relevant_activation_errors = [
                    error
                    for error in activation_error_items
                    if str(error.get("extensionId", "")).lower() in installed_ids
                ]
                status = "top-openvsx-extension-pack-expanded-install-verified"
                if missing_commands or relevant_activation_errors:
                    status = "top-openvsx-extension-pack-expanded-install-partial"
                return {
                    "port": port,
                    "installed": installed,
                    "dependencyCounts": dependency_counts,
                    "expectedCommandCount": len(expected_command_set),
                    "discoveredCommandCount": len(discovered_commands),
                    "commandPayloadCount": len(command_payload.get("commands", [])) if isinstance(command_payload, dict) else 0,
                    "missingCommands": missing_commands[:100],
                    "activationErrors": relevant_activation_errors,
                    "ignoredActivationErrors": [
                        error
                        for error in activation_error_items
                        if error not in relevant_activation_errors
                    ],
                    "startupExtensionsDeferred": True,
                    "status": status,
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "installed": installed,
                    "status": "top-openvsx-extension-pack-expanded-install-failed",
                    "blockedReason": str(exc),
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def _wait_for_language_contributions(timeout: float = 30.0) -> dict:
    deadline = time.time() + timeout
    best_payload: dict = {}
    best_score = -1
    while time.time() < deadline:
        try:
            payload = _rpc("extension/languageContributions", request_id=141, timeout=10.0)
        except AssertionError as exc:
            if "Method not found" not in str(exc):
                raise
            time.sleep(0.5)
            continue
        score = 0
        for key in SUPPORTED_LANGUAGE_CONTRIBUTION_KEYS:
            value = payload.get(key, [])
            if isinstance(value, list):
                score += len(value)
        if score > best_score:
            best_payload = payload
            best_score = score
        time.sleep(0.5)
    return best_payload


def _write_fake_codex_cli(path: Path, log_path: Path) -> None:
    path.write_text(
        """#!/usr/bin/env python3
import json
import os
import sys


def log(event):
    path = os.environ.get("CODEX_FAKE_LOG")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, sort_keys=True) + "\\n")


def respond(message):
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\\n")
    sys.stdout.flush()


args = sys.argv[1:]
log({"argv": args, "cwd": os.getcwd()})
if args == ["--version"] or args == ["version"]:
    print("codex-cli 0.0.0-wizp-smoke")
    raise SystemExit(0)
if not args or args[0] != "app-server":
    print("fake codex: expected app-server", file=sys.stderr)
    raise SystemExit(2)

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        request = json.loads(line)
    except Exception as exc:
        log({"invalidJson": line, "error": str(exc)})
        continue
    log({"message": request})
    method = request.get("method")
    if method == "initialize":
        respond({
            "jsonrpc": "2.0",
            "id": request.get("id"),
            "result": {
                "protocolVersion": "2026-07-07",
                "serverInfo": {
                    "name": "codex-cli",
                    "title": "Codex CLI",
                    "version": "0.0.0-wizp-smoke",
                },
                "capabilities": {
                    "threads": {},
                    "turns": {},
                },
            },
        })
    elif "id" in request:
        respond({"jsonrpc": "2.0", "id": request.get("id"), "result": {}})
""",
        encoding="utf-8",
    )
    path.chmod(0o755)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text("", encoding="utf-8")


def _probe_fake_codex_app_server(fake_cli: Path, log_path: Path) -> dict:
    initialize = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "clientInfo": {
                "name": "codex_vscode",
                "title": "Codex VS Code Extension",
                "version": "0.1.0",
            },
        },
    }
    initialized = {"jsonrpc": "2.0", "method": "initialized", "params": {}}
    env = os.environ.copy()
    env["CODEX_FAKE_LOG"] = str(log_path)
    completed = subprocess.run(
        [str(fake_cli), "app-server"],
        input=json.dumps(initialize, separators=(",", ":")) + "\n" + json.dumps(initialized, separators=(",", ":")) + "\n",
        check=False,
        capture_output=True,
        text=True,
        timeout=5,
        env=env,
    )
    responses = []
    for line in completed.stdout.splitlines():
        if not line.strip():
            continue
        responses.append(json.loads(line))
    initialize_response = next((item for item in responses if item.get("id") == 1), None)
    ok = (
        completed.returncode == 0
        and isinstance(initialize_response, dict)
        and initialize_response.get("jsonrpc") == "2.0"
        and isinstance(initialize_response.get("result"), dict)
        and initialize_response["result"].get("serverInfo", {}).get("name") == "codex-cli"
    )
    return {
        "command": [str(fake_cli), "app-server"],
        "initializeRequest": initialize,
        "clientInfo": initialize["params"]["clientInfo"],
        "returnCode": completed.returncode,
        "stdoutLines": completed.stdout.splitlines(),
        "stderr": completed.stderr.strip()[-1000:],
        "initializeResponse": initialize_response,
        "status": "codex-app-server-jsonrpc-handshake-verified" if ok else "codex-app-server-jsonrpc-handshake-failed",
    }


def _real_codex_cli_path() -> str | None:
    configured = os.environ.get("WIZP_CODEX_CLI")
    if configured:
        return configured
    return shutil.which("codex")


def _write_codex_trust_config(codex_home: Path, *projects: Path) -> None:
    codex_home.mkdir(parents=True, exist_ok=True)
    seen: set[str] = set()
    lines: list[str] = []
    for project in projects:
        project_path = str(project.resolve())
        if project_path in seen:
            continue
        seen.add(project_path)
        lines.append(f"[projects.{json.dumps(project_path)}]")
        lines.append('trust_level = "trusted"')
        lines.append("")
    (codex_home / "config.toml").write_text("\n".join(lines), encoding="utf-8")


def _probe_real_codex_app_server_once(cli_path: str, cwd: Path, codex_home: Path, attempt: int) -> dict:
    _write_codex_trust_config(codex_home, WORKSPACE_ROOT, cwd)
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    env["CODEX_SQLITE_HOME"] = str(codex_home)
    initialize = {
        "method": "initialize",
        "id": "1",
        "params": {
            "capabilities": {
                "experimentalApi": True,
                "mcpServerOpenaiFormElicitation": True,
                "requestAttestation": False,
            },
            "clientInfo": {
                "name": "WIZP",
                "title": "Codex Extension",
                "version": "26.623.101652",
            },
        },
    }
    initialized = {"method": "initialized", "params": {}}
    command = [cli_path, "app-server", "--analytics-default-enabled"]
    stdout_lines: list[str] = []
    stderr_lines: list[str] = []
    responses: list[dict] = []
    notifications: list[dict] = []
    proc = None
    terminated_after_handshake = False
    try:
        proc = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=env,
            cwd=str(cwd),
        )
        assert proc.stdin is not None
        assert proc.stdout is not None
        assert proc.stderr is not None
        proc.stdin.write(json.dumps(initialize, separators=(",", ":")) + "\n")
        proc.stdin.flush()

        selector = selectors.DefaultSelector()
        selector.register(proc.stdout, selectors.EVENT_READ, "stdout")
        selector.register(proc.stderr, selectors.EVENT_READ, "stderr")
        deadline = time.time() + 8.0
        while time.time() < deadline and selector.get_map():
            for key, _ in selector.select(timeout=0.2):
                line = key.fileobj.readline()
                if line == "":
                    selector.unregister(key.fileobj)
                    continue
                line = line.rstrip("\n")
                if key.data == "stderr":
                    stderr_lines.append(line)
                    continue
                stdout_lines.append(line)
                if not line.strip():
                    continue
                try:
                    message = json.loads(line)
                except json.JSONDecodeError:
                    notifications.append({"raw": line})
                    continue
                if isinstance(message, dict) and str(message.get("id")) == "1":
                    responses.append(message)
                elif isinstance(message, dict):
                    notifications.append(message)
            if responses:
                break
            if proc.poll() is not None and not selector.get_map():
                break

        try:
            proc.stdin.write(json.dumps(initialized, separators=(",", ":")) + "\n")
            proc.stdin.flush()
        except Exception:
            pass
        try:
            proc.stdin.close()
        except Exception:
            pass

        try:
            proc.wait(timeout=1.5)
        except subprocess.TimeoutExpired:
            proc.terminate()
            terminated_after_handshake = bool(responses)
            try:
                proc.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=2.0)
        for pipe, target in ((proc.stdout, stdout_lines), (proc.stderr, stderr_lines)):
            if pipe is None:
                continue
            for line in pipe.read().splitlines():
                if line not in target:
                    target.append(line)
    except Exception as exc:
        if proc is not None and proc.poll() is None:
            proc.kill()
            proc.wait(timeout=2.0)
        return {
            "attempt": attempt,
            "command": command,
            "status": "real-codex-app-server-jsonrpc-handshake-failed",
            "blockedReason": str(exc),
            "codexHome": str(codex_home),
        }

    initialize_response = responses[0] if responses else None
    result = initialize_response.get("result") if isinstance(initialize_response, dict) else None
    ok = (
        isinstance(result, dict)
        and isinstance(result.get("userAgent"), str)
        and isinstance(result.get("codexHome"), str)
        and result.get("platformFamily") in {"unix", "windows"}
    )
    return {
        "attempt": attempt,
        "command": command,
        "initializeRequest": initialize,
        "clientInfo": initialize["params"]["clientInfo"],
        "capabilities": initialize["params"]["capabilities"],
        "returnCode": proc.returncode if proc is not None else None,
        "terminatedAfterHandshake": terminated_after_handshake,
        "stdoutLines": stdout_lines[:20],
        "stderr": "\n".join(stderr_lines).strip()[-2000:],
        "initializeResponse": initialize_response,
        "notifications": notifications[:20],
        "codexHome": str(codex_home),
        "status": "real-codex-app-server-jsonrpc-handshake-verified" if ok else "real-codex-app-server-jsonrpc-handshake-failed",
    }


def _probe_real_codex_app_server(cli_path: str, cwd: Path) -> dict:
    with tempfile.TemporaryDirectory(prefix="wizp-real-codex-cli-") as tmp:
        attempts: list[dict] = []
        for attempt in range(1, 4):
            codex_home = Path(tmp) / f"codex-home-{attempt}"
            result = _probe_real_codex_app_server_once(cli_path, cwd, codex_home, attempt)
            attempts.append(result)
            if result.get("status") == "real-codex-app-server-jsonrpc-handshake-verified":
                verified = dict(result)
                verified["attempts"] = [dict(item) for item in attempts]
                return verified
            time.sleep(0.25)
        final = dict(attempts[-1])
        final["attempts"] = [dict(item) for item in attempts]
        return final


def _external_network_issues(process_payload: dict) -> list[dict]:
    issues: list[dict] = []
    for entry in process_payload.get("networkAudit", []) if isinstance(process_payload, dict) else []:
        if not isinstance(entry, dict):
            continue
        host = str(entry.get("host") or "")
        if host in {"", "127.0.0.1", "localhost"}:
            continue
        if entry.get("allowlisted") or entry.get("requestEnded") or entry.get("fetchResolved"):
            issues.append(entry)
    return issues


def _spawned_cli_matches(process_payload: dict, cli_path: str) -> list[dict]:
    matches: list[dict] = []
    for entry in process_payload.get("spawnedProcesses", []) if isinstance(process_payload, dict) else []:
        if not isinstance(entry, dict):
            continue
        args = entry.get("args", [])
        if not isinstance(args, list):
            continue
        if str(entry.get("command") or "") == cli_path and "app-server" in [str(arg) for arg in args]:
            matches.append(entry)
    return matches


def _terminate_spawned_processes(processes: list[dict]) -> list[dict]:
    terminations: list[dict] = []
    for entry in processes:
        if not isinstance(entry, dict):
            continue
        pid = entry.get("pid")
        if not isinstance(pid, int) or pid <= 0:
            continue
        try:
            os.kill(pid, signal.SIGTERM)
            terminations.append({"pid": pid, "status": "sigterm-sent"})
        except ProcessLookupError:
            terminations.append({"pid": pid, "status": "already-exited"})
        except Exception as exc:
            terminations.append({"pid": pid, "status": "sigterm-failed", "error": str(exc)})
    return terminations


def _execute_codex_command(command: str, request_id: int, command_class: str, timeout_ms: int = 3000, args: list | None = None) -> dict:
    params: dict = {"command": command, "timeoutMs": timeout_ms}
    if args is not None:
        params["args"] = args
    started = time.time()
    try:
        execute_result = _rpc(
            "extension/execute",
            params,
            request_id=request_id,
            timeout=max(8.0, (timeout_ms / 1000.0) + 3.0),
        )
        elapsed_ms = int((time.time() - started) * 1000)
        if isinstance(execute_result, dict) and execute_result.get("__wizpTimedOut"):
            return {
                "command": command,
                "class": command_class,
                "status": "timed-out",
                "elapsedMs": elapsed_ms,
                "result": execute_result,
            }
        return {
            "command": command,
            "class": command_class,
            "status": "executed",
            "elapsedMs": elapsed_ms,
            "result": execute_result,
        }
    except Exception as exc:
        return {
            "command": command,
            "class": command_class,
            "status": "failed",
            "error": str(exc),
        }


def _poll_extension_ui_for(seconds: float) -> list:
    events: list = []
    deadline = time.time() + seconds
    while time.time() < deadline:
        polled = _poll_extension_ui()
        if polled:
            events.extend(polled)
        time.sleep(0.1)
    polled = _poll_extension_ui()
    if polled:
        events.extend(polled)
    return events


def _codex_webview_evidence(ui_events: list) -> dict:
    expected_views = set(OFFICIAL_CODEX["webviewViews"])
    expected_focus_commands = {f"{view_id}.focus" for view_id in expected_views}
    registered = sorted({
        str(event.get("id"))
        for event in ui_events
        if isinstance(event, dict) and event.get("type") == "webviewRegistered" and str(event.get("id")) in expected_views
    })
    focused = sorted({
        str(event.get("id"))
        for event in ui_events
        if isinstance(event, dict) and event.get("type") == "webviewViewFocus" and str(event.get("id")) in expected_views
    })
    focus_commands = sorted({
        str(event.get("command"))
        for event in ui_events
        if isinstance(event, dict) and event.get("type") == "commandRegistered" and str(event.get("command")) in expected_focus_commands
    })
    panels = sorted({
        str(event.get("viewType"))
        for event in ui_events
        if isinstance(event, dict) and event.get("type") == "webviewPanelCreated" and event.get("viewType")
    })
    quick_picks = [
        {
            "pickedLabel": str(event.get("pickedLabel", "")),
            "itemCount": len(event.get("items", [])) if isinstance(event.get("items"), list) else 0,
            "title": event.get("options", {}).get("title") if isinstance(event.get("options"), dict) else None,
            "placeholder": event.get("options", {}).get("placeHolder") if isinstance(event.get("options"), dict) else None,
        }
        for event in ui_events
        if isinstance(event, dict) and event.get("type") == "quickPick"
    ]
    return {
        "expectedViews": sorted(expected_views),
        "registeredViews": registered,
        "focusedViews": focused,
        "focusCommands": focus_commands,
        "createdPanels": panels,
        "quickPicks": quick_picks[-5:],
        "missingRegisteredViews": sorted(expected_views - set(registered)),
        "missingFocusedViews": sorted(expected_views - set(focused)),
        "missingFocusCommands": sorted(expected_focus_commands - set(focus_commands)),
    }


def run_official_codex_extension_smoke(package: dict) -> dict:
    if not BIN.exists():
        return {
            "extensionId": OFFICIAL_CODEX["extensionId"],
            "status": "blocked-missing-wizp-binary",
            "blockedReason": f"missing WIZP binary: {BIN}; run npm run build first",
        }

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    tmp_root = PROJECT_ROOT / "build" / "parity-real-extensions"
    tmp_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="wizp-official-codex-", dir=str(tmp_root)) as tmp, tempfile.TemporaryDirectory(prefix="wizp-official-codex-home-") as codex_home_tmp:
        root = Path(tmp)
        codex_home = Path(codex_home_tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        fake_cli = root / "bin" / "codex"
        fake_log = root / "fake-codex.log"
        workspace.mkdir()
        (workspace / "todo.md").write_text("- [ ] verify Codex compatibility\n", encoding="utf-8")
        real_cli_path = _real_codex_cli_path()
        real_app_server_contract = (
            _probe_real_codex_app_server(real_cli_path, workspace)
            if real_cli_path
            else {
                "status": "real-codex-app-server-jsonrpc-handshake-unavailable",
                "blockedReason": "official codex CLI not found on PATH; set WIZP_CODEX_CLI to override",
            }
        )
        use_real_cli = real_app_server_contract.get("status") == "real-codex-app-server-jsonrpc-handshake-verified"
        fake_cli.parent.mkdir(parents=True)
        _write_fake_codex_cli(fake_cli, fake_log)
        fake_app_server_contract = None if use_real_cli else _probe_fake_codex_app_server(fake_cli, fake_log)
        configured_cli = str(real_cli_path) if use_real_cli and real_cli_path else str(fake_cli)
        configured_cli_kind = "real" if use_real_cli else "fake"
        app_server_contract = real_app_server_contract if use_real_cli else fake_app_server_contract
        ext_root.mkdir(parents=True)

        manifest = _vsix_manifest(Path(str(package["cachePath"])))
        install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)
        manifest_commands = set(_manifest_commands(manifest))
        required_commands = set(OFFICIAL_CODEX["requiredCommands"])
        manifest_missing_commands = sorted(required_commands - manifest_commands)
        config_properties = _manifest_configuration_properties(manifest)
        manifest_missing_settings = sorted(
            key
            for key in (OFFICIAL_CODEX["cliExecutableSetting"], OFFICIAL_CODEX["openOnStartupSetting"])
            if key not in config_properties
        )
        chat_sessions = manifest.get("contributes", {}).get("chatSessions", []) if isinstance(manifest.get("contributes"), dict) else []
        manifest_chat_session_types = sorted(
            str(item.get("type"))
            for item in chat_sessions
            if isinstance(item, dict) and isinstance(item.get("type"), str)
        )

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["CODEX_HOME"] = str(codex_home)
        env["CODEX_SQLITE_HOME"] = env["CODEX_HOME"]
        env["CODEX_FAKE_LOG"] = str(fake_log)
        env["PATH"] = str(fake_cli.parent) + os.pathsep + env.get("PATH", "")
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_DEFER_STARTUP_EXTENSIONS"] = "1"
        env["WIZP_EXTENSION_ACTIVATION_TIMEOUT_MS"] = "8000"
        env["WIZP_EXTENSION_DIAGNOSTIC_RPC_TIMEOUT_MS"] = "2500"
        env["WIZP_EXTENSION_QUICK_PICK_SELECTION"] = "none"
        env["WIZP_EXTENSION_CONFIGURATION_JSON"] = json.dumps(
            {
                "chatgpt": {
                    "cliExecutable": configured_cli,
                    "openOnStartup": False,
                },
                OFFICIAL_CODEX["cliExecutableSetting"]: configured_cli,
                OFFICIAL_CODEX["openOnStartupSetting"]: False,
            },
            separators=(",", ":"),
        )
        _write_codex_trust_config(Path(env["CODEX_HOME"]), WORKSPACE_ROOT, workspace)
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            try:
                _wait_for_server(required_commands=required_commands, timeout=45.0)
                command_payload, discovered_commands = _wait_for_command_surface(required_commands, timeout=45.0)
                snapshot = _rpc(
                    "extension/contributionSnapshot",
                    {"extensionId": OFFICIAL_CODEX["extensionId"]},
                    request_id=171,
                    timeout=10.0,
                )
                snapshot_commands = {
                    item.get("command")
                    for item in snapshot.get("commands", [])
                    if isinstance(item, dict) and isinstance(item.get("command"), str)
                }
                snapshot_config = {
                    item.get("key")
                    for item in snapshot.get("configuration", [])
                    if isinstance(item, dict) and isinstance(item.get("key"), str)
                }
                snapshot_chat_session_types = sorted(
                    str(item.get("value", {}).get("type"))
                    for item in snapshot.get("chatSessions", [])
                    if isinstance(item, dict)
                    and isinstance(item.get("value"), dict)
                    and isinstance(item["value"].get("type"), str)
                )
                activation_result: dict = {}
                activation_exception = None
                try:
                    activation_result = _activate_by_event("startup", request_id=172, timeout=12.0)
                except Exception as exc:
                    activation_exception = str(exc)
                time.sleep(1.0)
                activation_errors = _activation_errors_payload(request_id=173)
                activation_error_items = (
                    activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []
                )
                activation_error_ids = {
                    OFFICIAL_CODEX["extensionId"].lower(),
                    install_path.name.lower(),
                    str(manifest.get("name") or "").lower(),
                }
                publisher_name = f"{manifest.get('publisher')}.{manifest.get('name')}".lower()
                activation_error_ids.add(publisher_name)
                relevant_activation_errors = [
                    error
                    for error in activation_error_items
                    if str(error.get("id", error.get("extensionId", ""))).lower() in activation_error_ids
                ]
                ui_events = _poll_extension_ui_for(0.5)
                source_text = "- [ ] TODO: verify Codex compatibility\n"
                active_document = _rpc(
                    "extension/activeTextDocument",
                    {
                        "uri": (workspace / "todo.md").resolve().as_uri(),
                        "languageId": "markdown",
                        "content": source_text,
                        "line": 0,
                        "character": 6,
                        "endLine": 0,
                        "endCharacter": len(source_text.rstrip()),
                    },
                    request_id=174,
                    timeout=8.0,
                )
                ui_events.extend(_poll_extension_ui_for(0.2))

                webview_focus_results: list[dict] = []
                for index, view_id in enumerate(OFFICIAL_CODEX["webviewViews"], start=1):
                    webview_focus_results.append(
                        _execute_codex_command(
                            f"{view_id}.focus",
                            request_id=180 + index,
                            command_class="webview-focus",
                            timeout_ms=3000,
                        )
                    )
                    ui_events.extend(_poll_extension_ui_for(0.3))

                ui_workflow_results: list[dict] = []
                for index, command in enumerate(OFFICIAL_CODEX["uiWorkflowCommands"], start=1):
                    ui_workflow_results.append(
                        _execute_codex_command(
                            command,
                            request_id=190 + index,
                            command_class="ui-workflow",
                            timeout_ms=4000,
                        )
                    )
                    ui_events.extend(_poll_extension_ui_for(0.3))

                context_workflow_results: list[dict] = []
                for index, command in enumerate(OFFICIAL_CODEX["contextWorkflowCommands"], start=1):
                    context_workflow_results.append(
                        _execute_codex_command(
                            command,
                            request_id=210 + index,
                            command_class="context-workflow",
                            timeout_ms=4000,
                        )
                    )
                    ui_events.extend(_poll_extension_ui_for(0.3))

                authenticated_command_boundaries = [
                    {
                        "command": command,
                        "class": "authenticated-turn",
                        "status": "not-executed",
                        "reason": "requires an authenticated Codex thread or model turn; outside the local no-credential compatibility smoke",
                    }
                    for command in OFFICIAL_CODEX["authenticatedTurnCommands"]
                ]
                command_results_payload = _rpc("extension/commandResults", request_id=225, timeout=5.0)
                ui_events.extend(_poll_extension_ui_for(0.5))
                webview_evidence = _codex_webview_evidence(ui_events)
                safe_command_results = webview_focus_results + ui_workflow_results + context_workflow_results

                process_payload = _rpc("extension/runtimeProcesses", request_id=175, timeout=10.0)
                external_network_issues = _external_network_issues(process_payload)
                spawned_cli_matches = _spawned_cli_matches(process_payload, configured_cli)
                spawned_cli_terminations = _terminate_spawned_processes(spawned_cli_matches) if use_real_cli else []
                missing_commands = sorted(required_commands - discovered_commands)
                missing_snapshot_commands = sorted(required_commands - snapshot_commands)
                missing_snapshot_settings = sorted(
                    key
                    for key in (OFFICIAL_CODEX["cliExecutableSetting"], OFFICIAL_CODEX["openOnStartupSetting"])
                    if key not in snapshot_config
                )
                missing_chat_sessions = (
                    []
                    if OFFICIAL_CODEX["chatSessionType"] in snapshot_chat_session_types
                    else [OFFICIAL_CODEX["chatSessionType"]]
                )
                fake_log_lines = fake_log.read_text(encoding="utf-8", errors="replace").splitlines() if fake_log.exists() else []
                app_server_status = app_server_contract.get("status") if isinstance(app_server_contract, dict) else None
                expected_app_server_status = (
                    "real-codex-app-server-jsonrpc-handshake-verified"
                    if use_real_cli
                    else "codex-app-server-jsonrpc-handshake-verified"
                )
                real_cli_failed = real_cli_path is not None and not use_real_cli
                safe_command_failures = [
                    result for result in safe_command_results if result.get("status") != "executed"
                ]
                webview_evidence_missing = (
                    webview_evidence["missingRegisteredViews"]
                    or webview_evidence["missingFocusedViews"]
                    or webview_evidence["missingFocusCommands"]
                )
                status = (
                    "official-codex-vscode-extension-and-real-cli-workflows-verified"
                    if use_real_cli
                    else "official-codex-vscode-extension-and-cli-workflows-verified"
                )
                if (
                    manifest_missing_commands
                    or manifest_missing_settings
                    or OFFICIAL_CODEX["chatSessionType"] not in manifest_chat_session_types
                    or missing_commands
                    or missing_snapshot_commands
                    or missing_snapshot_settings
                    or missing_chat_sessions
                    or activation_exception
                    or relevant_activation_errors
                    or external_network_issues
                    or app_server_status != expected_app_server_status
                    or not spawned_cli_matches
                    or safe_command_failures
                    or webview_evidence_missing
                    or real_cli_failed
                ):
                    status = "official-codex-vscode-extension-and-cli-contract-partial"
                return {
                    "port": port,
                    "extensionId": OFFICIAL_CODEX["extensionId"],
                    "version": manifest.get("version"),
                    "installDirName": install_path.name,
                    "mainExists": _main_exists(install_path, manifest),
                    "cliExecutableSetting": OFFICIAL_CODEX["cliExecutableSetting"],
                    "configuredCli": configured_cli,
                    "configuredCliKind": configured_cli_kind,
                    "realCliPath": real_cli_path,
                    "realCliAppServerContract": real_app_server_contract,
                    "fakeCli": str(fake_cli),
                    "fakeCliAppServerContract": fake_app_server_contract,
                    "appServerContract": app_server_contract,
                    "manifestCommandCount": len(manifest_commands),
                    "requiredCommands": OFFICIAL_CODEX["requiredCommands"],
                    "manifestMissingCommands": manifest_missing_commands,
                    "discoveredCommandCount": len(discovered_commands),
                    "commandPayloadCount": len(command_payload.get("commands", [])) if isinstance(command_payload, dict) else 0,
                    "missingCommands": missing_commands,
                    "missingSnapshotCommands": missing_snapshot_commands,
                    "manifestConfigurationProperties": config_properties,
                    "manifestMissingSettings": manifest_missing_settings,
                    "missingSnapshotSettings": missing_snapshot_settings,
                    "manifestChatSessionTypes": manifest_chat_session_types,
                    "snapshotChatSessionTypes": snapshot_chat_session_types,
                    "missingChatSessions": missing_chat_sessions,
                    "activationResult": activation_result,
                    "activationException": activation_exception,
                    "activationErrors": relevant_activation_errors,
                    "activeDocument": active_document,
                    "webviewFocusCommandResults": webview_focus_results,
                    "uiWorkflowCommandResults": ui_workflow_results,
                    "contextWorkflowCommandResults": context_workflow_results,
                    "authenticatedCommandBoundaries": authenticated_command_boundaries,
                    "safeCommandResults": safe_command_results,
                    "commandResults": command_results_payload,
                    "webviewEvidence": webview_evidence,
                    "uiEventCount": len(ui_events),
                    "uiEvents": ui_events[-30:],
                    "ignoredActivationErrors": [
                        error
                        for error in activation_error_items
                        if error not in relevant_activation_errors
                    ],
                    "spawnedProcesses": process_payload.get("spawnedProcesses", []) if isinstance(process_payload, dict) else [],
                    "spawnedCliMatches": spawned_cli_matches,
                    "spawnedCliTerminations": spawned_cli_terminations,
                    "forkedProcesses": process_payload.get("forkedProcesses", []) if isinstance(process_payload, dict) else [],
                    "networkAudit": process_payload.get("networkAudit", []) if isinstance(process_payload, dict) else [],
                    "externalNetworkIssues": external_network_issues,
                    "fakeCliLog": fake_log_lines[-20:],
                    "startupExtensionsDeferred": True,
                    "status": status,
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "extensionId": OFFICIAL_CODEX["extensionId"],
                    "status": "official-codex-vscode-extension-and-cli-contract-failed",
                    "blockedReason": str(exc),
                    "configuredCli": configured_cli,
                    "configuredCliKind": configured_cli_kind,
                    "realCliPath": real_cli_path,
                    "realCliAppServerContract": real_app_server_contract,
                    "fakeCli": str(fake_cli),
                    "fakeCliAppServerContract": fake_app_server_contract,
                    "appServerContract": app_server_contract,
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def run_official_codex_smoke() -> dict:
    extension_id = str(OFFICIAL_CODEX["extensionId"])
    namespace, name = extension_id.split(".", 1)
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "codex-vsix"
    try:
        metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
        package = _package_record(extension_id, metadata, cache_dir)
        if package.get("status") == "downloaded-and-manifest-verified":
            manifest = _vsix_manifest(Path(str(package["cachePath"])))
            package["supportedContributionCounts"] = _manifest_contribution_counts(manifest)
            package["configurationProperties"] = _manifest_configuration_properties(manifest)
            package["chatSessions"] = manifest.get("contributes", {}).get("chatSessions", []) if isinstance(manifest.get("contributes"), dict) else []
        else:
            return {
                "extensionId": extension_id,
                "package": package,
                "status": "official-codex-package-unavailable",
            }
    except Exception as exc:
        return {
            "extensionId": extension_id,
            "status": "official-codex-package-unavailable",
            "blockedReason": str(exc),
        }
    extension_smoke = run_official_codex_extension_smoke(package)
    return {
        "extensionId": extension_id,
        "package": package,
        "extensionSmoke": extension_smoke,
        "status": extension_smoke.get("status", "official-codex-vscode-extension-and-cli-contract-unknown"),
    }


def run_lane_baseline_contribution_smoke(packages: list[dict]) -> dict:
    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-lane-baseline-openvsx-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        installed = []
        expected_commands: list[str] = []
        expected_supported_counts = {key: 0 for key in SUPPORTED_LANGUAGE_CONTRIBUTION_KEYS}
        unsupported_contribution_keys: dict[str, list[str]] = {}
        for package in packages:
            manifest = _vsix_manifest(Path(str(package["cachePath"])))
            install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)
            commands = _manifest_commands(manifest)
            expected_commands.extend(commands)
            contributes = manifest.get("contributes", {})
            contribute_keys = sorted(contributes.keys()) if isinstance(contributes, dict) else []
            for key, count in _manifest_contribution_counts(manifest).items():
                expected_supported_counts[key] += count
            unsupported = [
                key
                for key in contribute_keys
                if key not in SUPPORTED_LANGUAGE_CONTRIBUTION_KEYS
                and key not in {"commands", "menus", "keybindings", "configuration", "configurationDefaults", "colors", "submenus"}
            ]
            if unsupported:
                unsupported_contribution_keys[package["id"]] = unsupported
            installed.append(
                {
                    "id": package["id"],
                    "installDirName": install_path.name,
                    "packageJson": (install_path / "package.json").exists(),
                    "mainExists": _main_exists(install_path, manifest),
                    "commandCount": len(commands),
                    "supportedContributionCounts": _manifest_contribution_counts(manifest),
                    "unsupportedContributionKeys": unsupported,
                    "extensionPackCount": len(manifest.get("extensionPack", [])) if isinstance(manifest.get("extensionPack"), list) else 0,
                    "extensionDependencyCount": len(manifest.get("extensionDependencies", [])) if isinstance(manifest.get("extensionDependencies"), list) else 0,
                }
            )

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_DEFER_STARTUP_EXTENSIONS"] = "1"
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            try:
                _wait_for_server(timeout=30.0)
                expected_command_set = set(expected_commands)
                command_payload, discovered_commands = _wait_for_command_surface(expected_command_set, timeout=45.0)
                missing_commands = sorted(expected_command_set - discovered_commands)
                contribution_payload = _wait_for_language_contributions(timeout=45.0)
                discovered_supported_counts: dict[str, int] = {}
                missing_supported_counts: dict[str, dict[str, int]] = {}
                for key, expected_count in expected_supported_counts.items():
                    value = contribution_payload.get(key, [])
                    discovered_count = len(value) if isinstance(value, list) else 0
                    discovered_supported_counts[key] = discovered_count
                    if discovered_count < expected_count:
                        missing_supported_counts[key] = {
                            "expected": expected_count,
                            "discovered": discovered_count,
                        }
                activation_errors = _activation_errors_payload(request_id=142)
                activation_error_items = (
                    activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []
                )
                installed_ids = {
                    str(item.get("id", "")).lower()
                    for item in installed
                } | {
                    str(item.get("installDirName", "")).lower()
                    for item in installed
                }
                relevant_activation_errors = [
                    error
                    for error in activation_error_items
                    if str(error.get("extensionId", "")).lower() in installed_ids
                ]
                status = "top-openvsx-lane-baseline-contributions-verified"
                if missing_commands or missing_supported_counts or relevant_activation_errors:
                    status = "top-openvsx-lane-baseline-contributions-partial"
                return {
                    "port": port,
                    "installed": installed,
                    "expectedCommandCount": len(expected_command_set),
                    "discoveredCommandCount": len(discovered_commands),
                    "commandPayloadCount": len(command_payload.get("commands", [])) if isinstance(command_payload, dict) else 0,
                    "missingCommands": missing_commands[:100],
                    "expectedSupportedContributionCounts": {
                        key: count
                        for key, count in expected_supported_counts.items()
                        if count > 0
                    },
                    "discoveredSupportedContributionCounts": {
                        key: count
                        for key, count in discovered_supported_counts.items()
                        if count > 0
                    },
                    "missingSupportedContributionCounts": missing_supported_counts,
                    "unsupportedContributionKeys": unsupported_contribution_keys,
                    "activationErrors": relevant_activation_errors,
                    "ignoredActivationErrors": [
                        error
                        for error in activation_error_items
                        if error not in relevant_activation_errors
                    ],
                    "startupExtensionsDeferred": True,
                    "status": status,
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "installed": installed,
                    "status": "top-openvsx-lane-baseline-contributions-failed",
                    "blockedReason": str(exc),
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def run_top_openvsx_loadability_smoke(packages: list[dict]) -> dict:
    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-top-openvsx-load-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        installed = []
        expected_commands: list[str] = []
        for package in packages:
            manifest = _vsix_manifest(Path(str(package["cachePath"])))
            install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)
            commands = _manifest_commands(manifest)
            expected_commands.extend(commands)
            installed.append(
                {
                    "id": package["id"],
                    "installDirName": install_path.name,
                    "packageJson": (install_path / "package.json").exists(),
                    "mainExists": _main_exists(install_path, manifest),
                    "commandCount": len(commands),
                }
            )

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_DEFER_STARTUP_EXTENSIONS"] = "1"
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            try:
                _wait_for_server(timeout=30.0)
                expected_command_set = set(expected_commands)
                command_payload, discovered_commands = _wait_for_command_surface(expected_command_set, timeout=30.0)
                missing_commands = sorted(expected_command_set - discovered_commands)
                activation_errors = _activation_errors_payload(request_id=122)
                activation_error_items = (
                    activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []
                )
                installed_ids = {
                    str(item.get("id", "")).lower()
                    for item in installed
                } | {
                    str(item.get("installDirName", "")).lower()
                    for item in installed
                }
                relevant_activation_errors = [
                    error
                    for error in activation_error_items
                    if str(error.get("extensionId", "")).lower() in installed_ids
                ]
                command_surface_status = "top-openvsx-command-surface-verified"
                if missing_commands:
                    command_surface_status = "top-openvsx-command-surface-partial"
                status = "top-openvsx-loadability-verified"
                if relevant_activation_errors:
                    status = "top-openvsx-loadability-partial"
                return {
                    "port": port,
                    "installed": installed,
                    "expectedCommandCount": len(set(expected_commands)),
                    "discoveredCommandCount": len(discovered_commands),
                    "commandPayloadCount": len(command_payload.get("commands", [])) if isinstance(command_payload, dict) else 0,
                    "missingCommands": missing_commands[:100],
                    "commandSurfaceStatus": command_surface_status,
                    "activationErrors": relevant_activation_errors,
                    "ignoredActivationErrors": [
                        error
                        for error in activation_error_items
                        if error not in relevant_activation_errors
                    ],
                    "startupExtensionsDeferred": True,
                    "status": status,
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "installed": installed,
                    "status": "top-openvsx-loadability-failed",
                    "blockedReason": str(exc),
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def _main_exists(install_path: Path, manifest: dict) -> bool:
    main = manifest.get("main") or manifest.get("browser")
    if not main:
        return True
    path = install_path / str(main)
    if path.exists():
        return True
    if not str(main).endswith(".js") and path.with_suffix(path.suffix + ".js").exists():
        return True
    return False


def run_loadability_smoke(packages: list[dict]) -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-real-extension-load-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        installed = []
        expected_commands: list[str] = []
        for package in packages:
            vsix_path = Path(str(package["cachePath"]))
            manifest = _vsix_manifest(vsix_path)
            install_path = _install_vsix(vsix_path, ext_root, manifest)
            commands = _manifest_commands(manifest)
            expected_commands.extend(commands)
            installed.append(
                {
                    "id": package["id"],
                    "installDirName": install_path.name,
                    "installedInTempHome": True,
                    "packageJson": (install_path / "package.json").exists(),
                    "mainExists": bool(manifest.get("main")) and (install_path / str(manifest.get("main"))).exists(),
                    "commands": commands,
                }
            )

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_DEFER_STARTUP_EXTENSIONS"] = "1"
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            try:
                _wait_for_server(required_commands=set(expected_commands))
                command_payload = _rpc("extension/commands", request_id=21)
                discovered_commands = {
                    item.get("command")
                    for item in command_payload.get("commands", [])
                    if isinstance(item, dict) and isinstance(item.get("command"), str)
                }
                missing_commands = sorted(command for command in expected_commands if command not in discovered_commands)
                if missing_commands:
                    raise AssertionError(f"installed real extension command(s) missing: {missing_commands[:10]}")
                activation_errors = _rpc("extension/activationErrors", request_id=22)
                activation_error_items = (
                    activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []
                )
                if activation_error_items:
                    raise AssertionError(f"real extension startup activation error(s): {activation_error_items}")
                return {
                    "port": port,
                    "installed": installed,
                    "expectedCommandCount": len(expected_commands),
                    "discoveredCommandCount": len(discovered_commands),
                    "missingCommands": missing_commands,
                    "activationErrors": activation_error_items,
                "status": "installed-command-surface-with-startup-activation-deferred-verified",
            }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                proc_code = proc.poll()
                stdout_tail = stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:]
                stderr_tail = stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:]
                raise AssertionError(
                    "real extension loadability smoke failed: "
                    f"{exc}; procExit={proc_code}; stdoutTail={stdout_tail!r}; stderrTail={stderr_tail!r}"
                ) from exc
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def run_runtime_command_smoke(packages: list[dict]) -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    target = next((package for package in packages if package["id"] == RUNTIME_COMMAND["extensionId"]), None)
    if not target:
        raise AssertionError(f"runtime command extension missing from package set: {RUNTIME_COMMAND['extensionId']}")

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-real-extension-runtime-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        expected_path = workspace / RUNTIME_COMMAND["expectedFile"]

        manifest = _vsix_manifest(Path(str(target["cachePath"])))
        install_path = _install_vsix(Path(str(target["cachePath"])), ext_root, manifest)
        expected_commands = _manifest_commands(manifest)

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_DEFER_STARTUP_EXTENSIONS"] = "1"
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            try:
                _wait_for_server(required_commands={RUNTIME_COMMAND["command"]})
                _rpc("extension/activateByEvent", {"event": "startup"}, request_id=31)
                deadline = time.time() + 8.0
                command_results = None
                time.sleep(5.0)
                execute_result = _rpc(
                    "extension/execute",
                    {"command": RUNTIME_COMMAND["command"], "timeoutMs": 5000},
                    request_id=35,
                )
                ui_events: list = []
                while time.time() < deadline:
                    if expected_path.exists():
                        break
                    ui_events.extend(_poll_extension_ui())
                    if expected_path.exists():
                        break
                    try:
                        command_results = _rpc("extension/commandResults", request_id=34)
                    except Exception as exc:
                        command_results = {"pollError": str(exc)}
                    time.sleep(0.25)
                try:
                    activation_errors = _rpc("extension/activationErrors", request_id=33)
                except Exception as exc:
                    activation_errors = {"errors": [], "pollError": str(exc)}
                activation_error_items = (
                    activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []
                )
                if activation_error_items:
                    raise AssertionError(f"runtime command activation error(s): {activation_error_items}")
                if not expected_path.exists():
                    raise AssertionError(f"runtime command did not create {expected_path}; last result={execute_result!r}; commandResults={command_results!r}; uiEvents={ui_events[-10:]!r}")
                return {
                    "port": port,
                    "extensionId": RUNTIME_COMMAND["extensionId"],
                    "command": RUNTIME_COMMAND["command"],
                    "installDirName": install_path.name,
                    "expectedCommands": expected_commands,
                    "generatedFile": str(expected_path),
                    "generatedBytes": expected_path.stat().st_size,
                    "uiEvents": ui_events,
                    "commandResults": command_results,
                    "activationErrors": activation_error_items,
                    "status": "real-command-executed-and-side-effect-verified",
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                proc_code = proc.poll()
                stdout_tail = stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:]
                stderr_tail = stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:]
                raise AssertionError(
                    "real extension runtime command smoke failed: "
                    f"{exc}; procExit={proc_code}; stdoutTail={stdout_tail!r}; stderrTail={stderr_tail!r}"
                ) from exc
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def run_runtime_provider_smoke(packages: list[dict]) -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    target = next((package for package in packages if package["id"] == RUNTIME_PROVIDER["extensionId"]), None)
    if not target:
        raise AssertionError(f"runtime provider extension missing from package set: {RUNTIME_PROVIDER['extensionId']}")

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-real-extension-provider-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        source_dir = workspace / "src"
        nested_dir = source_dir / "nested"
        nested_dir.mkdir(parents=True)
        (source_dir / "alpha.ts").write_text("export const alpha = 1;\n", encoding="utf-8")
        (nested_dir / "beta.ts").write_text("export const beta = 1;\n", encoding="utf-8")
        source_path = workspace / str(RUNTIME_PROVIDER["file"])
        source_text = 'import x from "./src/";\n'
        source_path.write_text(source_text, encoding="utf-8")

        manifest = _vsix_manifest(Path(str(target["cachePath"])))
        install_path = _install_vsix(Path(str(target["cachePath"])), ext_root, manifest)

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_DEFER_STARTUP_EXTENSIONS"] = "1"
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            try:
                _wait_for_server(timeout=20.0)
                time.sleep(1.0)
                provider_result = _rpc(
                    "extension/languageProviders",
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": RUNTIME_PROVIDER["languageId"],
                        "text": source_text,
                        "line": 0,
                        "character": len('import x from "./src/'),
                        "triggerCharacter": "/",
                    },
                    request_id=41,
                )
                activation_errors = _rpc("extension/activationErrors", request_id=42)
                activation_error_items = (
                    activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []
                )
                if activation_error_items:
                    raise AssertionError(f"runtime provider activation error(s): {activation_error_items}")
                completion = provider_result.get("completion", {}) if isinstance(provider_result, dict) else {}
                items = completion.get("items", []) if isinstance(completion, dict) else []
                labels = {item.get("label") for item in items if isinstance(item, dict)}
                if not {"alpha.ts", "nested"}.issubset(labels):
                    raise AssertionError(f"path-intellisense did not return expected path completions: {items}")
                return {
                    "port": port,
                    "extensionId": RUNTIME_PROVIDER["extensionId"],
                    "installDirName": install_path.name,
                    "languageId": RUNTIME_PROVIDER["languageId"],
                    "sourceFile": str(source_path),
                    "labels": sorted(label for label in labels if isinstance(label, str)),
                    "providerResolution": provider_result.get("providerResolution", {}),
                    "activationErrors": activation_error_items,
                    "status": "real-provider-completions-verified",
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                proc_code = proc.poll()
                stdout_tail = stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:]
                stderr_tail = stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:]
                raise AssertionError(
                    "real extension runtime provider smoke failed: "
                    f"{exc}; procExit={proc_code}; stdoutTail={stdout_tail!r}; stderrTail={stderr_tail!r}"
                ) from exc
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def run_runtime_npm_provider_smoke(packages: list[dict]) -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    target = next((package for package in packages if package["id"] == RUNTIME_NPM_PROVIDER["extensionId"]), None)
    if not target:
        raise AssertionError(f"runtime npm provider extension missing from package set: {RUNTIME_NPM_PROVIDER['extensionId']}")

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-real-extension-npm-provider-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        (workspace / "package.json").write_text(
            json.dumps(
                {
                    "name": "wizp-npm-intellisense-smoke",
                    "dependencies": {
                        "left-pad": "1.3.0",
                        "@scope/pkg": "2.0.0",
                    },
                    "devDependencies": {
                        "dev-only-package": "1.0.0",
                    },
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        source_path = workspace / str(RUNTIME_NPM_PROVIDER["file"])
        source_text = 'import smoke from "";\n'
        source_path.write_text(source_text, encoding="utf-8")

        manifest = _vsix_manifest(Path(str(target["cachePath"])))
        install_path = _install_vsix(Path(str(target["cachePath"])), ext_root, manifest)

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_DEFER_STARTUP_EXTENSIONS"] = "1"
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            try:
                _wait_for_server(timeout=20.0)
                time.sleep(1.0)
                provider_result = _rpc(
                    "extension/languageProviders",
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": RUNTIME_NPM_PROVIDER["languageId"],
                        "text": source_text,
                        "line": 0,
                        "character": len('import smoke from "'),
                        "triggerCharacter": '"',
                    },
                    request_id=71,
                )
                activation_errors = _rpc("extension/activationErrors", request_id=72)
                activation_error_items = (
                    activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []
                )
                if activation_error_items:
                    raise AssertionError(f"runtime npm provider activation error(s): {activation_error_items}")
                completion = provider_result.get("completion", {}) if isinstance(provider_result, dict) else {}
                items = completion.get("items", []) if isinstance(completion, dict) else []
                labels = {item.get("label") for item in items if isinstance(item, dict)}
                if not {"left-pad", "@scope/pkg"}.issubset(labels):
                    raise AssertionError(f"npm-intellisense did not return expected dependency completions: {items}")
                if "dev-only-package" in labels:
                    raise AssertionError(f"npm-intellisense returned devDependency despite default config: {items}")
                return {
                    "port": port,
                    "extensionId": RUNTIME_NPM_PROVIDER["extensionId"],
                    "installDirName": install_path.name,
                    "languageId": RUNTIME_NPM_PROVIDER["languageId"],
                    "sourceFile": str(source_path),
                    "labels": sorted(label for label in labels if isinstance(label, str)),
                    "providerResolution": provider_result.get("providerResolution", {}),
                    "activationErrors": activation_error_items,
                    "status": "real-provider-package-completions-verified",
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                proc_code = proc.poll()
                stdout_tail = stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:]
                stderr_tail = stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:]
                raise AssertionError(
                    "real extension runtime npm provider smoke failed: "
                    f"{exc}; procExit={proc_code}; stdoutTail={stdout_tail!r}; stderrTail={stderr_tail!r}"
                ) from exc
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def run_prettier_formatter_runtime_smoke() -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "formatter-vsix"
    namespace, name = PRETTIER_RUNTIME["extensionId"].split(".", 1)
    metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
    package = _package_record(PRETTIER_RUNTIME["extensionId"], metadata, cache_dir)
    if package["status"] != "downloaded-and-manifest-verified":
        return {
            "extensionId": PRETTIER_RUNTIME["extensionId"],
            "status": "prettier-formatter-package-unavailable",
            "package": package,
        }

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-prettier-runtime-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        source_path = workspace / str(PRETTIER_RUNTIME["file"])
        source_text = str(PRETTIER_RUNTIME["source"])
        source_path.write_text(source_text, encoding="utf-8")

        def offset_at(text: str, line: int, character: int) -> int:
            if line <= 0:
                return min(len(text), max(0, character))
            current_line = 0
            current_character = 0
            for index, char in enumerate(text):
                if current_line == line and current_character == character:
                    return index
                if char == "\n":
                    current_line += 1
                    current_character = 0
                else:
                    current_character += 1
            return len(text)

        def apply_text_edits(text: str, text_edits: list[dict]) -> str:
            normalized: list[tuple[int, int, str]] = []
            for item in text_edits:
                if not isinstance(item, dict):
                    continue
                edit_range = item.get("range")
                if not isinstance(edit_range, dict):
                    continue
                start = edit_range.get("start") or {}
                end = edit_range.get("end") or {}
                normalized.append(
                    (
                        offset_at(text, int(start.get("line", 0)), int(start.get("character", 0))),
                        offset_at(text, int(end.get("line", 0)), int(end.get("character", 0))),
                        str(item.get("newText", "")),
                    )
                )
            for start, end, replacement in sorted(normalized, reverse=True):
                text = text[:start] + replacement + text[end:]
            return text

        manifest = _vsix_manifest(Path(str(package["cachePath"])))
        install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_DEFER_STARTUP_EXTENSIONS"] = "1"
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            try:
                provider_result: dict = {}
                edits: list = []
                provider_error: str | None = None
                startup_activation_error: str | None = None
                _wait_for_server(timeout=30.0)
                expected_commands = set(_manifest_commands(manifest))
                _wait_for_command_surface(expected_commands, timeout=30.0)
                active_document = _set_active_text_document(
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": PRETTIER_RUNTIME["languageId"],
                        "content": source_text,
                        "line": 0,
                        "character": 0,
                    },
                    request_id=160,
                )
                try:
                    _activate_by_event("onStartupFinished", request_id=161, timeout=20.0)
                except Exception as exc:
                    startup_activation_error = str(exc)
                deadline = time.time() + 45.0
                while time.time() < deadline:
                    try:
                        provider_result = _rpc(
                            "extension/languageProviders",
                            {
                                "uri": source_path.resolve().as_uri(),
                                "languageId": PRETTIER_RUNTIME["languageId"],
                                "text": source_text,
                                "line": 0,
                                "character": 0,
                                "options": {"tabSize": 2, "insertSpaces": True},
                            },
                            request_id=162,
                            timeout=30.0,
                        )
                        provider_error = None
                    except Exception as exc:
                        provider_error = str(exc)
                        time.sleep(1.0)
                        continue
                    edits = provider_result.get("documentFormatting", []) if isinstance(provider_result, dict) else []
                    if edits:
                        break
                    time.sleep(0.5)
                activation_errors = _activation_errors_payload(request_id=163)
                activation_error_items = (
                    activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []
                )
                relevant_activation_errors = [
                    error
                    for error in activation_error_items
                    if str(error.get("extensionId", "")).lower()
                    in {PRETTIER_RUNTIME["extensionId"].lower(), install_path.name.lower()}
                ]
                if relevant_activation_errors:
                    raise AssertionError(f"prettier runtime activation error(s): {relevant_activation_errors}")
                formatted_text = apply_text_edits(source_text, edits)
                if not edits or "const smoke = {" not in formatted_text or "console.log(smoke);" not in formatted_text:
                    raise AssertionError(
                        "prettier did not return expected formatting edits: "
                        f"edits={edits!r}; provider={provider_result!r}; providerError={provider_error!r}; "
                        f"startupActivationError={startup_activation_error!r}"
                    )
                save_without_format = _rpc(
                    "extension/applySaveParticipants",
                    {
                        "path": str(source_path.resolve()),
                        "content": source_text,
                        "languageId": PRETTIER_RUNTIME["languageId"],
                        "formatOnSave": False,
                        "options": {"tabSize": 2, "insertSpaces": True},
                    },
                    request_id=164,
                    timeout=20.0,
                )
                save_with_format = _rpc(
                    "extension/applySaveParticipants",
                    {
                        "path": str(source_path.resolve()),
                        "content": source_text,
                        "languageId": PRETTIER_RUNTIME["languageId"],
                        "formatOnSave": True,
                        "options": {"tabSize": 2, "insertSpaces": True},
                    },
                    request_id=165,
                    timeout=20.0,
                )
                if save_without_format.get("changed"):
                    raise AssertionError(f"format-on-save disabled unexpectedly changed content: {save_without_format!r}")
                saved_text = str(save_with_format.get("content", ""))
                if (
                    not save_with_format.get("changed")
                    or int(save_with_format.get("formatterEditCount", 0)) < 1
                    or "const smoke = {" not in saved_text
                    or "console.log(smoke);" not in saved_text
                ):
                    raise AssertionError(f"format-on-save did not apply Prettier edits: {save_with_format!r}")
                return {
                    "port": port,
                    "extensionId": PRETTIER_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "languageId": PRETTIER_RUNTIME["languageId"],
                    "sourceFile": str(source_path),
                    "activeDocument": active_document,
                    "editCount": len(edits),
                    "formattedPreview": formatted_text[:500],
                    "formatOnSave": {
                        "disabledChanged": bool(save_without_format.get("changed")),
                        "enabledChanged": bool(save_with_format.get("changed")),
                        "formatterEditCount": save_with_format.get("formatterEditCount"),
                        "formattedPreview": saved_text[:500],
                    },
                    "providerResolution": provider_result.get("providerResolution", {}),
                    "activationErrors": relevant_activation_errors,
                    "status": "prettier-document-formatting-runtime-verified",
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "extensionId": PRETTIER_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "status": "prettier-document-formatting-runtime-failed",
                    "blockedReason": str(exc),
                    "providerResult": provider_result,
                    "documentFormatting": edits,
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def run_ruff_formatter_linter_runtime_smoke() -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "formatter-vsix"
    namespace, name = RUFF_RUNTIME["extensionId"].split(".", 1)
    metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
    package = _package_record(RUFF_RUNTIME["extensionId"], metadata, cache_dir)
    if package["status"] != "downloaded-and-manifest-verified":
        return {
            "extensionId": RUFF_RUNTIME["extensionId"],
            "status": "ruff-formatter-linter-package-unavailable",
            "package": package,
        }

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-ruff-runtime-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        source_path = workspace / str(RUFF_RUNTIME["file"])
        source_text = str(RUFF_RUNTIME["source"])
        source_path.write_text(source_text, encoding="utf-8")
        (workspace / "pyproject.toml").write_text(
            "[tool.ruff]\nline-length = 88\n[tool.ruff.lint]\nselect = [\"F\", \"E\"]\n",
            encoding="utf-8",
        )

        manifest = _vsix_manifest(Path(str(package["cachePath"])))
        install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)
        bundled_binary = _binary_probe(install_path / "bundled" / "libs" / "bin" / "ruff")

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_ENABLE_PYTHON_EXTENSION_API_SHIM"] = "1"
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            process_result: dict = {}
            provider_result: dict = {}
            diagnostics: dict = {}
            debug_state: dict = {}
            ui_events: list = []
            activation_errors: dict = {}
            try:
                _wait_for_server(timeout=30.0)
                _wait_for_command_surface(set(_manifest_commands(manifest)), timeout=30.0)
                _update_configuration(
                    {
                        "values": {
                            "ruff.enable": True,
                            "ruff.nativeServer": False,
                            "ruff.lint.enable": True,
                            "ruff.lint.select": ["F", "E"],
                            "ruff.organizeImports": True,
                            "ruff.fixAll": True,
                            "ruff.format.backend": "internal",
                            "ruff.importStrategy": "useBundled",
                            "ruff.interpreter": [sys.executable],
                            "ruff.path": [],
                        }
                    },
                    request_id=201,
                    timeout=10.0,
                )
                active_document = _set_active_text_document(
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": RUFF_RUNTIME["languageId"],
                        "content": source_text,
                        "line": 0,
                        "character": 0,
                    },
                    request_id=202,
                )
                _activate_by_event(f"onLanguage:{RUFF_RUNTIME['languageId']}", request_id=203, timeout=30.0)
                deadline = time.time() + 30.0
                while time.time() < deadline:
                    process_result = _rpc("extension/runtimeProcesses", request_id=204, timeout=10.0)
                    provider_result = _rpc(
                        "extension/languageProviders",
                        {
                            "uri": source_path.resolve().as_uri(),
                            "languageId": RUFF_RUNTIME["languageId"],
                            "text": source_text,
                            "line": 0,
                            "character": 0,
                            "options": {"tabSize": 4, "insertSpaces": True},
                        },
                        request_id=205,
                        timeout=20.0,
                    )
                    diagnostics = _rpc("extension/diagnostics", request_id=206, timeout=10.0)
                    ui_events.extend(_poll_extension_ui())
                    provider_resolution = provider_result.get("providerResolution", {}) if isinstance(provider_result, dict) else {}
                    spawned = process_result.get("spawnedProcesses", []) if isinstance(process_result, dict) else []
                    diagnostic_collections = diagnostics.get("collections", []) if isinstance(diagnostics, dict) else []
                    if spawned or provider_resolution.get("documentFormatting") or provider_resolution.get("codeActions") or diagnostic_collections:
                        break
                    time.sleep(0.75)
                activation_errors = _activation_errors_payload(request_id=207)
                activation_error_items = (
                    activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []
                )
                relevant_activation_errors = [
                    error
                    for error in activation_error_items
                    if str(error.get("extensionId", "")).lower()
                    in {RUFF_RUNTIME["extensionId"].lower(), install_path.name.lower()}
                ]
                if relevant_activation_errors:
                    raise AssertionError(f"ruff runtime activation error(s): {relevant_activation_errors}")
                spawned_processes = process_result.get("spawnedProcesses", []) if isinstance(process_result, dict) else []
                ruff_spawned = [
                    item
                    for item in spawned_processes
                    if isinstance(item, dict)
                    and (
                        "ruff" in str(item.get("command", "")).lower()
                        or any("ruff" in str(arg).lower() for arg in item.get("args", []))
                    )
                ]
                provider_resolution = provider_result.get("providerResolution", {}) if isinstance(provider_result, dict) else {}
                formatting_providers = provider_resolution.get("documentFormatting") or []
                code_action_providers = provider_resolution.get("codeActions") or []
                diagnostic_collections = diagnostics.get("collections", []) if isinstance(diagnostics, dict) else []
                formatted_text = str(provider_result.get("documentFormattingAppliedText", "")) if isinstance(provider_result, dict) else ""
                ui_text = " ".join(str(event) for event in ui_events).lower()
                degraded_server_failure = (
                    "ruff" in ui_text
                    and ("couldn't create connection" in ui_text or "server: start failed" in ui_text)
                    and bool(ruff_spawned)
                )
                full_runtime = bool(
                    formatting_providers
                    or code_action_providers
                    or diagnostic_collections
                    or (
                        formatted_text
                        and "def add(left: int, right: int) -> int:" in formatted_text
                        and "print(add(1, 2))" in formatted_text
                    )
                ) and not degraded_server_failure
                if not ruff_spawned and not full_runtime and not degraded_server_failure:
                    raise AssertionError(
                        "ruff runtime smoke did not observe process, providers, or diagnostics: "
                        f"processes={process_result!r}; providers={provider_result!r}; diagnostics={diagnostics!r}; ui={ui_events!r}"
                    )
                return {
                    "port": port,
                    "extensionId": RUFF_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "languageId": RUFF_RUNTIME["languageId"],
                    "sourceFile": str(source_path),
                    "activeDocument": active_document,
                    "bundledBinary": bundled_binary,
                    "runtimeProcesses": process_result,
                    "providerResolution": provider_resolution,
                    "documentFormattingAppliedText": formatted_text[:500],
                    "diagnosticCollections": diagnostic_collections,
                    "uiEvents": ui_events[-10:],
                    "activationErrors": relevant_activation_errors,
                    "status": "ruff-formatter-linter-runtime-verified"
                    if full_runtime
                    else "ruff-language-server-degraded-verified",
                    "blockedReason": None
                    if full_runtime
                    else "Ruff legacy language server launch reached a safe degraded state: server process was requested, UI/logs reported connection failure, and activation did not crash.",
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "extensionId": RUFF_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "status": "ruff-formatter-linter-runtime-failed",
                    "blockedReason": str(exc),
                    "bundledBinary": bundled_binary,
                    "runtimeProcesses": process_result,
                    "providerResult": provider_result,
                    "diagnostics": diagnostics,
                    "uiEvents": ui_events[-10:],
                    "activationErrors": activation_errors,
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def run_ruff_external_binary_discovery_smoke() -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "formatter-vsix"
    namespace, name = RUFF_RUNTIME["extensionId"].split(".", 1)
    metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
    package = _package_record(RUFF_RUNTIME["extensionId"], metadata, cache_dir)
    if package["status"] != "downloaded-and-manifest-verified":
        return {
            "extensionId": RUFF_RUNTIME["extensionId"],
            "status": "ruff-external-binary-package-unavailable",
            "package": package,
        }

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-ruff-external-runtime-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        source_path = workspace / str(RUFF_RUNTIME["file"])
        source_text = str(RUFF_RUNTIME["source"])
        invocation_log = workspace / "external-ruff.invocations"
        external_ruff = root / "bin" / "ruff"
        external_ruff.parent.mkdir(parents=True)
        external_ruff.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' \"$0 $*\" >> \"$WIZP_RUFF_INVOCATIONS\"\n"
            "if [ \"$1\" = \"--version\" ]; then\n"
            "  printf 'ruff 0.14.0\\n'\n"
            "  exit 0\n"
            "fi\n"
            "if [ \"$1\" = \"server\" ]; then\n"
            "  sleep 20\n"
            "  exit 0\n"
            "fi\n"
            "printf 'ruff 0.14.0\\n'\n"
            "exit 0\n",
            encoding="utf-8",
        )
        external_ruff.chmod(0o755)

        manifest = _vsix_manifest(Path(str(package["cachePath"])))
        install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_DEFER_STARTUP_EXTENSIONS"] = "1"
        env["WIZP_RUFF_INVOCATIONS"] = str(invocation_log)
        env["WIZP_ENABLE_PYTHON_EXTENSION_API_SHIM"] = "1"
        env["PATH"] = f"{external_ruff.parent}{os.pathsep}{env.get('PATH', '')}"
        env["WIZP_EXTENSION_CONFIGURATION_JSON"] = json.dumps(
            {
                "ruff": {
                    "enable": True,
                    "nativeServer": False,
                    "importStrategy": "fromEnvironment",
                    "path": [str(external_ruff)],
                    "interpreter": [],
                }
            }
        )
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            process_result: dict = {}
            provider_result: dict = {}
            debug_state: dict = {}
            initial_debug_state: dict = {}
            ui_events: list = []
            activation_errors: dict = {}
            try:
                _wait_for_server(timeout=30.0)
                deadline = time.time() + 30.0
                last_debug_error = None
                while time.time() < deadline:
                    try:
                        initial_debug_state = _rpc(
                            "extension/debugState",
                            {
                                "configSection": "ruff",
                                "configKeys": ["enable", "nativeServer", "importStrategy", "path", "interpreter"],
                                "inspect": True,
                            },
                            request_id=231,
                            timeout=10.0,
                        )
                        break
                    except AssertionError as exc:
                        last_debug_error = exc
                        if "Method not found" not in str(exc):
                            raise
                        time.sleep(0.5)
                if not initial_debug_state:
                    raise AssertionError(f"extension/debugState did not become available before Ruff activation: {last_debug_error}")
                source_path.write_text(source_text, encoding="utf-8")
                active_document = _set_active_text_document(
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": RUFF_RUNTIME["languageId"],
                        "content": source_text,
                        "line": 0,
                        "character": 0,
                        "fireOpen": True,
                    },
                    request_id=232,
                )
                _activate_by_event(f"onLanguage:{RUFF_RUNTIME['languageId']}", request_id=233, timeout=30.0)
                deadline = time.time() + 30.0
                external_spawned: list[dict] = []
                external_invocations: list[str] = []
                while time.time() < deadline:
                    process_result = _rpc("extension/runtimeProcesses", request_id=234, timeout=10.0)
                    debug_state = _rpc(
                        "extension/debugState",
                        {
                            "configSection": "ruff",
                            "configKeys": ["enable", "nativeServer", "importStrategy", "path", "interpreter"],
                            "inspect": True,
                        },
                        request_id=235,
                        timeout=10.0,
                    )
                    provider_result = _rpc(
                        "extension/languageProviders",
                        {
                            "uri": source_path.resolve().as_uri(),
                            "languageId": RUFF_RUNTIME["languageId"],
                            "text": source_text,
                            "line": 0,
                            "character": 0,
                            "options": {"tabSize": 4, "insertSpaces": True},
                        },
                        request_id=236,
                        timeout=20.0,
                    )
                    ui_events.extend(_poll_extension_ui())
                    spawned_processes = process_result.get("spawnedProcesses", []) if isinstance(process_result, dict) else []
                    external_spawned = [
                        item
                        for item in spawned_processes
                        if isinstance(item, dict)
                        and (
                            str(item.get("command", "")) == str(external_ruff)
                            or any(str(arg) == str(external_ruff) for arg in item.get("args", []))
                        )
                    ]
                    external_invocations = (
                        invocation_log.read_text(encoding="utf-8", errors="replace").splitlines()
                        if invocation_log.exists()
                        else []
                    )
                    if external_spawned or external_invocations:
                        break
                    time.sleep(0.75)
                activation_errors = _activation_errors_payload(request_id=237)
                activation_error_items = (
                    activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []
                )
                relevant_activation_errors = [
                    error
                    for error in activation_error_items
                    if str(error.get("extensionId", "")).lower()
                    in {RUFF_RUNTIME["extensionId"].lower(), install_path.name.lower()}
                ]
                if relevant_activation_errors:
                    raise AssertionError(f"ruff external runtime activation error(s): {relevant_activation_errors}")
                if not external_spawned and not external_invocations:
                    raise AssertionError(
                        "ruff external binary discovery smoke did not observe configured ruff.path launch or invocation: "
                        f"processes={process_result!r}; debugState={debug_state!r}; providers={provider_result!r}; ui={ui_events!r}"
                    )
                return {
                    "port": port,
                    "extensionId": RUFF_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "languageId": RUFF_RUNTIME["languageId"],
                    "sourceFile": str(source_path),
                    "activeDocument": active_document,
                    "externalBinary": {
                        "path": str(external_ruff),
                        "mode": oct(external_ruff.stat().st_mode & 0o777),
                        "invocations": external_invocations,
                    },
                    "runtimeProcesses": process_result,
                    "externalSpawnedProcesses": external_spawned,
                    "initialDebugState": initial_debug_state,
                    "debugState": debug_state,
                    "providerResult": provider_result,
                    "uiEvents": ui_events[-10:],
                    "activationErrors": relevant_activation_errors,
                    "status": "ruff-external-binary-discovery-verified",
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "extensionId": RUFF_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "status": "ruff-external-binary-discovery-failed",
                    "blockedReason": str(exc),
                    "externalBinary": {
                        "path": str(external_ruff),
                        "invocations": invocation_log.read_text(encoding="utf-8", errors="replace").splitlines()
                        if invocation_log.exists()
                        else [],
                    },
                    "runtimeProcesses": process_result,
                    "providerResult": provider_result,
                    "initialDebugState": initial_debug_state,
                    "debugState": debug_state,
                    "uiEvents": ui_events[-10:],
                    "activationErrors": activation_errors,
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def run_eslint_formatter_linter_runtime_smoke() -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "formatter-vsix"
    namespace, name = ESLINT_RUNTIME["extensionId"].split(".", 1)
    metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
    package = _package_record(ESLINT_RUNTIME["extensionId"], metadata, cache_dir)
    if package["status"] != "downloaded-and-manifest-verified":
        return {
            "extensionId": ESLINT_RUNTIME["extensionId"],
            "status": "eslint-formatter-linter-package-unavailable",
            "package": package,
        }

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-eslint-runtime-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        source_path = workspace / str(ESLINT_RUNTIME["file"])
        source_text = str(ESLINT_RUNTIME["source"])
        source_path.write_text(source_text, encoding="utf-8")
        (workspace / "package.json").write_text(
            json.dumps({"type": "module", "devDependencies": {"eslint": "^9.0.0"}}, indent=2),
            encoding="utf-8",
        )
        (workspace / "eslint.config.js").write_text(
            "export default [{ files: ['**/*.js'], rules: { semi: ['error', 'always'], 'no-unused-vars': 'warn' } }];\n",
            encoding="utf-8",
        )
        npm_cache = PROJECT_ROOT / "build" / "parity-real-extensions" / "npm-cache"
        npm_cache.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [
                "npm",
                "install",
                "--silent",
                "--no-audit",
                "--no-fund",
                "--cache",
                str(npm_cache),
                "eslint@^9.0.0",
            ],
            cwd=str(workspace),
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        manifest = _vsix_manifest(Path(str(package["cachePath"])))
        install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_DEFER_STARTUP_EXTENSIONS"] = "1"
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            process_result: dict = {}
            provider_result: dict = {}
            diagnostics: dict = {}
            debug_state: dict = {}
            ui_events: list = []
            activation_errors: dict = {}
            try:
                _wait_for_server(timeout=30.0)
                _wait_for_command_surface(set(_manifest_commands(manifest)), timeout=30.0)
                _rpc(
                    "extension/updateConfiguration",
                    {
                        "values": {
                            "eslint.enable": True,
                            "eslint.enabled": True,
                            "eslint.run": "onType",
                            "eslint.validate": ["javascript"],
                            "eslint.probe": ["javascript"],
                            "eslint.useFlatConfig": True,
                            "eslint.experimental.useFlatConfig": False,
                            "eslint.nodePath": None,
                            "eslint.options": {},
                            "eslint.packageManager": "npm",
                        }
                    },
                    request_id=211,
                    timeout=10.0,
                )
                _rpc(
                    "extension/updateConfiguration",
                    {"target": "global", "values": {"eslint.quiet": True}},
                    request_id=221,
                    timeout=10.0,
                )
                _rpc(
                    "extension/updateConfiguration",
                    {"target": "workspace", "values": {"eslint.quiet": False}},
                    request_id=222,
                    timeout=10.0,
                )
                _rpc(
                    "extension/updateConfiguration",
                    {
                        "target": "workspaceFolder",
                        "scopeUri": workspace.resolve().as_uri(),
                        "values": {"eslint.quiet": True},
                    },
                    request_id=223,
                    timeout=10.0,
                )
                _rpc(
                    "extension/updateConfiguration",
                    {
                        "target": "workspaceFolder",
                        "scopeUri": workspace.resolve().as_uri(),
                        "languageId": ESLINT_RUNTIME["languageId"],
                        "values": {"eslint.quiet": False},
                    },
                    request_id=224,
                    timeout=10.0,
                )
                active_document = _set_active_text_document(
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": ESLINT_RUNTIME["languageId"],
                        "content": source_text,
                        "line": 0,
                        "character": 6,
                    },
                    request_id=212,
                )
                _activate_by_event("startup", request_id=213, timeout=60.0)
                active_document = _set_active_text_document(
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": ESLINT_RUNTIME["languageId"],
                        "content": source_text,
                        "line": 0,
                        "character": 6,
                        "fireOpen": True,
                    },
                    request_id=218,
                    timeout=90.0,
                )
                _rpc(
                    "extension/execute",
                    {"command": "eslint.restart", "timeoutMs": 5000},
                    request_id=220,
                    timeout=10.0,
                )
                deadline = time.time() + 35.0
                while time.time() < deadline:
                    process_result = _rpc("extension/runtimeProcesses", request_id=214, timeout=10.0)
                    debug_state = _rpc(
                        "extension/debugState",
                        {
                            "configSection": "eslint",
                            "configKeys": ["enable", "enabled", "validate", "probe", "run", "useFlatConfig", "quiet"],
                            "inspect": True,
                        },
                        request_id=219,
                        timeout=10.0,
                    )
                    provider_result = _rpc(
                        "extension/languageProviders",
                        {
                            "uri": source_path.resolve().as_uri(),
                            "languageId": ESLINT_RUNTIME["languageId"],
                            "text": source_text,
                            "line": 0,
                            "character": 6,
                            "options": {"tabSize": 2, "insertSpaces": True},
                        },
                        request_id=215,
                        timeout=20.0,
                    )
                    diagnostics = _rpc("extension/diagnostics", request_id=216, timeout=10.0)
                    ui_events.extend(_poll_extension_ui())
                    forked = process_result.get("forkedProcesses", []) if isinstance(process_result, dict) else []
                    provider_resolution = provider_result.get("providerResolution", {}) if isinstance(provider_result, dict) else {}
                    diagnostic_collections = diagnostics.get("collections", []) if isinstance(diagnostics, dict) else []
                    eslint_forked = [
                        item
                        for item in forked
                        if isinstance(item, dict)
                        and "eslintserver" in str(item.get("modulePath", "")).replace("/", "").lower()
                    ]
                    if eslint_forked or provider_resolution.get("codeActions") or diagnostic_collections:
                        break
                    time.sleep(0.75)
                activation_errors = _activation_errors_payload(request_id=217)
                activation_error_items = (
                    activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []
                )
                relevant_activation_errors = [
                    error
                    for error in activation_error_items
                    if str(error.get("extensionId", "")).lower()
                    in {ESLINT_RUNTIME["extensionId"].lower(), install_path.name.lower()}
                ]
                if relevant_activation_errors:
                    raise AssertionError(f"eslint runtime activation error(s): {relevant_activation_errors}")
                startup_errors = [
                    event
                    for event in ui_events
                    if isinstance(event, dict)
                    and event.get("severity") == "error"
                    and (
                        "Starting the server failed" in str(event.get("message", ""))
                        or "couldn't create connection" in str(event.get("message", ""))
                    )
                ]
                startup_errors.extend(
                    event
                    for event in ui_events
                    if isinstance(event, dict)
                    and event.get("level") == "error"
                    and (
                        "Starting the server failed" in str(event.get("text", ""))
                        or "couldn't create connection" in str(event.get("text", ""))
                    )
                )
                if startup_errors:
                    raise AssertionError(f"eslint runtime startup error(s): {startup_errors[-4:]!r}")
                forked_processes = process_result.get("forkedProcesses", []) if isinstance(process_result, dict) else []
                eslint_processes = [
                    item
                    for item in forked_processes
                    if isinstance(item, dict)
                    and (
                        "eslintserver" in str(item.get("modulePath", "")).replace("/", "").lower()
                        or "eslintserver" in " ".join(str(arg) for arg in item.get("args", [])).replace("/", "").lower()
                    )
                ]
                provider_resolution = provider_result.get("providerResolution", {}) if isinstance(provider_result, dict) else {}
                diagnostic_collections = diagnostics.get("collections", []) if isinstance(diagnostics, dict) else []
                quiet_inspect = ((debug_state.get("configurationInspect") or {}).get("quiet") or {}) if isinstance(debug_state, dict) else {}
                if (debug_state.get("configuration") or {}).get("quiet") is not False:
                    raise AssertionError(f"eslint config precedence did not resolve workspace-folder language override: {debug_state!r}")
                if quiet_inspect.get("globalValue") is not True or quiet_inspect.get("workspaceValue") is not False or quiet_inspect.get("workspaceFolderValue") is not True or quiet_inspect.get("workspaceFolderLanguageValue") is not False:
                    raise AssertionError(f"eslint config inspect did not expose expected precedence layers: {quiet_inspect!r}")
                if not eslint_processes and not provider_resolution.get("codeActions") and not diagnostic_collections:
                    raise AssertionError(
                        "eslint runtime smoke did not observe server process, providers, or diagnostics: "
                        f"processes={process_result!r}; debug={debug_state!r}; providers={provider_result!r}; diagnostics={diagnostics!r}; ui={ui_events!r}"
                    )
                return {
                    "port": port,
                    "extensionId": ESLINT_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "languageId": ESLINT_RUNTIME["languageId"],
                    "sourceFile": str(source_path),
                    "activeDocument": active_document,
                    "runtimeProcesses": process_result,
                    "debugState": debug_state,
                    "configPrecedence": {
                        "resolvedQuiet": (debug_state.get("configuration") or {}).get("quiet"),
                        "quietInspect": quiet_inspect,
                    },
                    "providerResolution": provider_resolution,
                    "diagnosticCollections": diagnostic_collections,
                    "uiEvents": ui_events[-10:],
                    "activationErrors": relevant_activation_errors,
                    "status": "eslint-formatter-linter-runtime-verified",
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "extensionId": ESLINT_RUNTIME["extensionId"],
                    "installDirName": install_path.name if "install_path" in locals() else None,
                    "status": "eslint-formatter-linter-runtime-failed",
                    "blockedReason": str(exc),
                    "runtimeProcesses": process_result,
                    "debugState": debug_state,
                    "providerResult": provider_result,
                    "diagnostics": diagnostics,
                    "uiEvents": ui_events[-10:],
                    "activationErrors": activation_errors,
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def run_intelephense_php_diagnostics_lifecycle_smoke() -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "formatter-vsix"
    namespace, name = INTELEPHENSE_RUNTIME["extensionId"].split(".", 1)
    metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
    package = _package_record(INTELEPHENSE_RUNTIME["extensionId"], metadata, cache_dir)
    if package["status"] != "downloaded-and-manifest-verified":
        return {
            "extensionId": INTELEPHENSE_RUNTIME["extensionId"],
            "status": "intelephense-package-unavailable",
            "package": package,
        }

    def diagnostics_for_uri(payload: dict, uri: str) -> list[dict]:
        if not isinstance(payload, dict):
            return []
        result: list[dict] = []
        for collection in payload.get("collections", []) or []:
            if not isinstance(collection, dict):
                continue
            for entry in collection.get("entries", []) or []:
                if not isinstance(entry, dict):
                    continue
                entry_uri = str(entry.get("uri", ""))
                if entry_uri in {uri, uri.replace("file://", ""), Path(uri.replace("file://", "")).as_posix()}:
                    values = entry.get("diagnostics", [])
                    if isinstance(values, list):
                        result.extend([item for item in values if isinstance(item, dict)])
        return result

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-intelephense-runtime-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        source_path = workspace / str(INTELEPHENSE_RUNTIME["file"])
        bad_source = str(INTELEPHENSE_RUNTIME["badSource"])
        fixed_source = str(INTELEPHENSE_RUNTIME["fixedSource"])
        source_path.write_text(bad_source, encoding="utf-8")

        manifest = _vsix_manifest(Path(str(package["cachePath"])))
        install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_DEFER_STARTUP_EXTENSIONS"] = "1"
        env["WIZP_EXTENSION_NATIVE_FORK"] = "1"
        env["WIZP_EXTENSION_CONFIGURATION_JSON"] = json.dumps(
            {
                "intelephense": {
                    "diagnostics": {
                        "enable": True,
                        "run": "onType",
                        "undefinedFunctions": True,
                        "undefinedVariables": "on",
                    },
                    "environment": {"phpVersion": "8.2.0"},
                    "files": {"maxSize": 1000000},
                    "telemetry": {"enabled": False},
                    "trace": {"server": "off"},
                },
                "php": {"validate": {"enable": False, "run": "onType"}},
            }
        )
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            process_result: dict = {}
            diagnostics_before: dict = {}
            diagnostics_after: dict = {}
            provider_result: dict = {}
            debug_state: dict = {}
            ui_events: list = []
            activation_errors: dict = {}
            before_items: list[dict] = []
            after_items: list[dict] = []
            try:
                _wait_for_server(timeout=30.0)
                _wait_for_command_surface(set(_manifest_commands(manifest)), timeout=30.0)
                active_document = _set_active_text_document(
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": INTELEPHENSE_RUNTIME["languageId"],
                        "content": bad_source,
                        "line": 1,
                        "character": 0,
                        "fireOpen": True,
                    },
                    request_id=241,
                )
                _activate_by_event(f"onLanguage:{INTELEPHENSE_RUNTIME['languageId']}", request_id=242, timeout=45.0)
                uri = source_path.resolve().as_uri()
                deadline = time.time() + 60.0
                while time.time() < deadline:
                    process_result = _rpc("extension/runtimeProcesses", request_id=243, timeout=10.0)
                    diagnostics_before = _rpc("extension/diagnostics", request_id=244, timeout=10.0)
                    provider_result = _rpc(
                        "extension/languageProviders",
                        {
                            "uri": uri,
                            "languageId": INTELEPHENSE_RUNTIME["languageId"],
                            "text": bad_source,
                            "line": 2,
                            "character": 10,
                            "options": {"tabSize": 4, "insertSpaces": True},
                        },
                        request_id=245,
                        timeout=20.0,
                    )
                    debug_state = _rpc(
                        "extension/debugState",
                        {
                            "configSection": "intelephense",
                            "configKeys": ["diagnostics.enable", "diagnostics.run", "diagnostics.undefinedFunctions", "diagnostics.undefinedVariables"],
                            "inspect": True,
                        },
                        request_id=246,
                        timeout=10.0,
                    )
                    ui_events.extend(_poll_extension_ui())
                    before_items = diagnostics_for_uri(diagnostics_before, uri)
                    spawned = process_result.get("forkedProcesses", []) + process_result.get("spawnedProcesses", []) if isinstance(process_result, dict) else []
                    if before_items and spawned:
                        break
                    time.sleep(1.0)
                if not before_items:
                    raise AssertionError(
                        "Intelephense did not publish diagnostics for bad PHP fixture: "
                        f"processes={process_result!r}; diagnostics={diagnostics_before!r}; providers={provider_result!r}; debug={debug_state!r}; ui={ui_events!r}"
                    )
                source_path.write_text(fixed_source, encoding="utf-8")
                active_document = _set_active_text_document(
                    {
                        "uri": uri,
                        "languageId": INTELEPHENSE_RUNTIME["languageId"],
                        "content": fixed_source,
                        "line": 2,
                        "character": 10,
                    },
                    request_id=247,
                    timeout=20.0,
                )
                deadline = time.time() + 45.0
                while time.time() < deadline:
                    diagnostics_after = _rpc("extension/diagnostics", request_id=248, timeout=10.0)
                    ui_events.extend(_poll_extension_ui())
                    after_items = diagnostics_for_uri(diagnostics_after, uri)
                    if len(after_items) < len(before_items):
                        break
                    time.sleep(1.0)
                activation_errors = _activation_errors_payload(request_id=249)
                activation_error_items = (
                    activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []
                )
                relevant_activation_errors = [
                    error
                    for error in activation_error_items
                    if str(error.get("extensionId", "")).lower()
                    in {INTELEPHENSE_RUNTIME["extensionId"].lower(), install_path.name.lower()}
                ]
                if relevant_activation_errors:
                    raise AssertionError(f"Intelephense activation error(s): {relevant_activation_errors}")
                if len(after_items) >= len(before_items):
                    raise AssertionError(
                        "Intelephense diagnostics did not clear or shrink after fixing PHP fixture: "
                        f"before={before_items!r}; after={after_items!r}; diagnosticsAfter={diagnostics_after!r}"
                    )
                return {
                    "port": port,
                    "extensionId": INTELEPHENSE_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "languageId": INTELEPHENSE_RUNTIME["languageId"],
                    "sourceFile": str(source_path),
                    "activeDocument": active_document,
                    "runtimeProcesses": process_result,
                    "providerResolution": provider_result.get("providerResolution", {}) if isinstance(provider_result, dict) else {},
                    "diagnosticsBefore": before_items,
                    "diagnosticsAfter": after_items,
                    "diagnosticsBeforeCount": len(before_items),
                    "diagnosticsAfterCount": len(after_items),
                    "debugState": debug_state,
                    "uiEvents": ui_events[-10:],
                    "activationErrors": relevant_activation_errors,
                    "status": "intelephense-php-diagnostics-lifecycle-verified",
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "extensionId": INTELEPHENSE_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "status": "intelephense-php-diagnostics-lifecycle-failed",
                    "blockedReason": str(exc),
                    "runtimeProcesses": process_result,
                    "providerResult": provider_result,
                    "debugState": debug_state,
                    "diagnosticsBefore": diagnostics_before,
                    "diagnosticsAfter": diagnostics_after,
                    "uiEvents": ui_events[-10:],
                    "activationErrors": activation_errors,
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def run_pyright_language_runtime_smoke() -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "language-vsix"
    namespace, name = PYRIGHT_LANGUAGE_RUNTIME["extensionId"].split(".", 1)
    metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
    package = _package_record(PYRIGHT_LANGUAGE_RUNTIME["extensionId"], metadata, cache_dir)
    if package["status"] != "downloaded-and-manifest-verified":
        return {
            "extensionId": PYRIGHT_LANGUAGE_RUNTIME["extensionId"],
            "status": "pyright-language-package-unavailable",
            "package": package,
        }

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-pyright-runtime-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        source_path = workspace / str(PYRIGHT_LANGUAGE_RUNTIME["file"])
        source_text = str(PYRIGHT_LANGUAGE_RUNTIME["source"])
        source_path.write_text(source_text, encoding="utf-8")

        manifest = _vsix_manifest(Path(str(package["cachePath"])))
        install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            process_result: dict = {}
            provider_result: dict = {}
            try:
                _wait_for_server(timeout=30.0)
                expected_commands = set(_manifest_commands(manifest))
                _wait_for_command_surface(expected_commands, timeout=30.0)
                active_document = _set_active_text_document(
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": PYRIGHT_LANGUAGE_RUNTIME["languageId"],
                        "content": source_text,
                        "line": 0,
                        "character": 4,
                    },
                    request_id=171,
                )
                _activate_by_event(f"onLanguage:{PYRIGHT_LANGUAGE_RUNTIME['languageId']}", request_id=172, timeout=30.0)
                deadline = time.time() + 20.0
                forked_processes: list[dict] = []
                while time.time() < deadline:
                    process_result = _rpc("extension/runtimeProcesses", request_id=173, timeout=10.0)
                    forked_processes = [
                        item
                        for item in process_result.get("forkedProcesses", [])
                        if isinstance(item, dict)
                    ]
                    if any("server.js" in str(item.get("modulePath", "")) for item in forked_processes):
                        break
                    time.sleep(0.5)
                provider_result = _rpc(
                    "extension/languageProviders",
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": PYRIGHT_LANGUAGE_RUNTIME["languageId"],
                        "text": source_text,
                        "line": 0,
                        "character": 4,
                    },
                    request_id=174,
                    timeout=20.0,
                )
                activation_errors = _activation_errors_payload(request_id=175)
                activation_error_items = (
                    activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []
                )
                relevant_activation_errors = [
                    error
                    for error in activation_error_items
                    if str(error.get("extensionId", "")).lower()
                    in {PYRIGHT_LANGUAGE_RUNTIME["extensionId"].lower(), install_path.name.lower()}
                ]
                if relevant_activation_errors:
                    raise AssertionError(f"pyright runtime activation error(s): {relevant_activation_errors}")
                pyright_server_processes = [
                    item
                    for item in forked_processes
                    if "server.js" in str(item.get("modulePath", ""))
                    and str(item.get("modulePath", "")).lower().find("pyright") >= 0
                ]
                if not pyright_server_processes:
                    raise AssertionError(
                        f"pyright did not start a visible language-server IPC process: processes={process_result!r}"
                    )
                return {
                    "port": port,
                    "extensionId": PYRIGHT_LANGUAGE_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "languageId": PYRIGHT_LANGUAGE_RUNTIME["languageId"],
                    "sourceFile": str(source_path),
                    "activeDocument": active_document,
                    "runtimeProcesses": process_result,
                    "providerResolution": provider_result.get("providerResolution", {}),
                    "activationErrors": relevant_activation_errors,
                    "status": "pyright-language-server-runtime-verified",
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "extensionId": PYRIGHT_LANGUAGE_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "status": "pyright-language-server-runtime-failed",
                    "blockedReason": str(exc),
                    "runtimeProcesses": process_result,
                    "providerResult": provider_result,
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def run_yaml_language_runtime_smoke() -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "language-vsix"
    namespace, name = YAML_LANGUAGE_RUNTIME["extensionId"].split(".", 1)
    metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
    package = _package_record(YAML_LANGUAGE_RUNTIME["extensionId"], metadata, cache_dir)
    if package["status"] != "downloaded-and-manifest-verified":
        return {
            "extensionId": YAML_LANGUAGE_RUNTIME["extensionId"],
            "status": "yaml-language-package-unavailable",
            "package": package,
        }

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-yaml-runtime-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        source_path = workspace / str(YAML_LANGUAGE_RUNTIME["file"])
        source_text = str(YAML_LANGUAGE_RUNTIME["source"])
        source_path.write_text(source_text, encoding="utf-8")

        manifest = _vsix_manifest(Path(str(package["cachePath"])))
        install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            process_result: dict = {}
            provider_result: dict = {}
            try:
                _wait_for_server(timeout=30.0)
                _wait_for_command_surface(set(_manifest_commands(manifest)), timeout=30.0)
                active_document = _set_active_text_document(
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": YAML_LANGUAGE_RUNTIME["languageId"],
                        "content": source_text,
                        "line": 0,
                        "character": 0,
                    },
                    request_id=181,
                )
                _activate_by_event(f"onLanguage:{YAML_LANGUAGE_RUNTIME['languageId']}", request_id=182, timeout=30.0)
                deadline = time.time() + 20.0
                forked_processes: list[dict] = []
                while time.time() < deadline:
                    process_result = _rpc("extension/runtimeProcesses", request_id=183, timeout=10.0)
                    forked_processes = [
                        item
                        for item in process_result.get("forkedProcesses", [])
                        if isinstance(item, dict)
                    ]
                    if any("languageserver.js" in str(item.get("modulePath", "")) for item in forked_processes):
                        break
                    time.sleep(0.5)
                provider_result = _rpc(
                    "extension/languageProviders",
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": YAML_LANGUAGE_RUNTIME["languageId"],
                        "text": source_text,
                        "line": 0,
                        "character": 0,
                    },
                    request_id=184,
                    timeout=20.0,
                )
                activation_errors = _activation_errors_payload(request_id=185)
                activation_error_items = (
                    activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []
                )
                relevant_activation_errors = [
                    error
                    for error in activation_error_items
                    if str(error.get("extensionId", "")).lower()
                    in {YAML_LANGUAGE_RUNTIME["extensionId"].lower(), install_path.name.lower()}
                ]
                if relevant_activation_errors:
                    raise AssertionError(f"yaml runtime activation error(s): {relevant_activation_errors}")
                yaml_server_processes = [
                    item
                    for item in forked_processes
                    if "languageserver.js" in str(item.get("modulePath", ""))
                    and str(item.get("modulePath", "")).lower().find("vscode-yaml") >= 0
                ]
                if not yaml_server_processes:
                    raise AssertionError(
                        f"yaml did not start a visible language-server IPC process: processes={process_result!r}"
                    )
                return {
                    "port": port,
                    "extensionId": YAML_LANGUAGE_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "languageId": YAML_LANGUAGE_RUNTIME["languageId"],
                    "sourceFile": str(source_path),
                    "activeDocument": active_document,
                    "runtimeProcesses": process_result,
                    "providerResolution": provider_result.get("providerResolution", {}),
                    "activationErrors": relevant_activation_errors,
                    "status": "yaml-language-server-runtime-verified",
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "extensionId": YAML_LANGUAGE_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "status": "yaml-language-server-runtime-failed",
                    "blockedReason": str(exc),
                    "runtimeProcesses": process_result,
                    "providerResult": provider_result,
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def run_clangd_degraded_runtime_smoke() -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "language-vsix"
    namespace, name = CLANGD_DEGRADED_RUNTIME["extensionId"].split(".", 1)
    metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
    package = _package_record(CLANGD_DEGRADED_RUNTIME["extensionId"], metadata, cache_dir)
    if package["status"] != "downloaded-and-manifest-verified":
        return {
            "extensionId": CLANGD_DEGRADED_RUNTIME["extensionId"],
            "status": "clangd-package-unavailable",
            "package": package,
        }

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-clangd-runtime-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        source_path = workspace / str(CLANGD_DEGRADED_RUNTIME["file"])
        source_text = str(CLANGD_DEGRADED_RUNTIME["source"])
        source_path.write_text(source_text, encoding="utf-8")

        manifest = _vsix_manifest(Path(str(package["cachePath"])))
        install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            process_result: dict = {}
            provider_result: dict = {}
            ui_events: list = []
            activation_errors: dict = {}
            try:
                _wait_for_server(timeout=30.0)
                _wait_for_command_surface(set(_manifest_commands(manifest)), timeout=30.0)
                _rpc(
                    "extension/updateConfiguration",
                    {
                        "values": {
                            "clangd.path": CLANGD_DEGRADED_RUNTIME["missingPath"],
                            "clangd.checkUpdates": False,
                            "clangd.detectExtensionConflicts": False,
                            "clangd.enable": True,
                        }
                    },
                    request_id=191,
                    timeout=10.0,
                )
                active_document = _set_active_text_document(
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": CLANGD_DEGRADED_RUNTIME["languageId"],
                        "content": source_text,
                        "line": 0,
                        "character": 4,
                    },
                    request_id=192,
                )
                try:
                    _activate_by_event(f"onLanguage:{CLANGD_DEGRADED_RUNTIME['languageId']}", request_id=193, timeout=30.0)
                except Exception:
                    activation_errors = _activation_errors_payload(request_id=196)
                    raise
                deadline = time.time() + 10.0
                while time.time() < deadline:
                    process_result = _rpc("extension/runtimeProcesses", request_id=194, timeout=10.0)
                    ui_events.extend(_poll_extension_ui())
                    forked_processes = [
                        item
                        for item in process_result.get("forkedProcesses", [])
                        if isinstance(item, dict)
                    ]
                    if ui_events and not any("clangd" in str(item.get("modulePath", "")).lower() for item in forked_processes):
                        break
                    time.sleep(0.5)
                provider_result = _rpc(
                    "extension/languageProviders",
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": CLANGD_DEGRADED_RUNTIME["languageId"],
                        "text": source_text,
                        "line": 0,
                        "character": 4,
                    },
                    request_id=195,
                    timeout=20.0,
                )
                activation_errors = _activation_errors_payload(request_id=196)
                activation_error_items = (
                    activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []
                )
                relevant_activation_errors = [
                    error
                    for error in activation_error_items
                    if str(error.get("extensionId", "")).lower()
                    in {CLANGD_DEGRADED_RUNTIME["extensionId"].lower(), install_path.name.lower()}
                ]
                if relevant_activation_errors:
                    raise AssertionError(f"clangd degraded activation error(s): {relevant_activation_errors}")
                forked_processes = [
                    item
                    for item in process_result.get("forkedProcesses", [])
                    if isinstance(item, dict)
                ]
                clangd_processes = [
                    item
                    for item in forked_processes
                    if "clangd" in str(item.get("modulePath", "")).lower()
                    or any("clangd" in str(arg).lower() for arg in item.get("args", []))
                ]
                if clangd_processes:
                    raise AssertionError(f"clangd degraded smoke unexpectedly started clangd process: {clangd_processes}")
                stdout_tail = stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:]
                stderr_tail = stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:]
                message_text = " ".join(str(event) for event in ui_events + relevant_activation_errors) + " " + stderr_tail
                lowered_message_text = message_text.lower()
                missing_tool_markers = ("not found", "not installed", "missing", "enoent")
                if "clangd" not in lowered_message_text or not any(
                    marker in lowered_message_text for marker in missing_tool_markers
                ):
                    raise AssertionError(
                        f"clangd degraded smoke did not surface missing-tool UX: uiEvents={ui_events!r}; stderrTail={stderr_tail!r}"
                    )
                return {
                    "port": port,
                    "extensionId": CLANGD_DEGRADED_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "languageId": CLANGD_DEGRADED_RUNTIME["languageId"],
                    "sourceFile": str(source_path),
                    "missingPath": CLANGD_DEGRADED_RUNTIME["missingPath"],
                    "activeDocument": active_document,
                    "runtimeProcesses": process_result,
                    "providerResolution": provider_result.get("providerResolution", {}),
                    "uiEvents": ui_events[-10:],
                    "activationErrors": relevant_activation_errors,
                    "stdoutTail": stdout_tail,
                    "stderrTail": stderr_tail,
                    "status": "clangd-missing-binary-degraded-verified",
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "extensionId": CLANGD_DEGRADED_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "status": "clangd-missing-binary-degraded-failed",
                    "blockedReason": str(exc),
                    "runtimeProcesses": process_result,
                    "providerResult": provider_result,
                    "uiEvents": ui_events[-10:],
                    "activationErrors": activation_errors,
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def run_tailwind_language_runtime_smoke() -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "language-vsix"
    namespace, name = TAILWIND_LANGUAGE_RUNTIME["extensionId"].split(".", 1)
    metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
    package = _package_record(TAILWIND_LANGUAGE_RUNTIME["extensionId"], metadata, cache_dir)
    if package["status"] != "downloaded-and-manifest-verified":
        return {
            "extensionId": TAILWIND_LANGUAGE_RUNTIME["extensionId"],
            "status": "tailwind-language-package-unavailable",
            "package": package,
        }

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-tailwind-runtime-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        source_path = workspace / str(TAILWIND_LANGUAGE_RUNTIME["file"])
        source_text = str(TAILWIND_LANGUAGE_RUNTIME["source"])
        source_path.write_text(source_text, encoding="utf-8")
        config_path = workspace / str(TAILWIND_LANGUAGE_RUNTIME["configFile"])
        config_path.write_text(str(TAILWIND_LANGUAGE_RUNTIME["configSource"]), encoding="utf-8")

        manifest = _vsix_manifest(Path(str(package["cachePath"])))
        install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_EXTENSION_NATIVE_FORK"] = "1"
        env["WIZP_EXTENSION_CONFIGURATION_JSON"] = json.dumps(
            {
                "tailwindCSS": {
                    "experimental": {"configFile": str(config_path)},
                    "includeLanguages": {"html": "html"},
                },
            }
        )
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            process_result: dict = {}
            provider_result: dict = {}
            debug_state: dict = {}
            activation_errors: dict = {}
            try:
                _wait_for_server(timeout=30.0)
                _wait_for_command_surface(set(_manifest_commands(manifest)), timeout=30.0)
                character = source_text.index("text-red") + len("text-")
                active_document = _set_active_text_document(
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": TAILWIND_LANGUAGE_RUNTIME["languageId"],
                        "content": source_text,
                        "line": 0,
                        "character": character,
                    },
                    request_id=201,
                )
                activation_result = _activate_by_event("onStartupFinished", request_id=202, timeout=30.0)
                time.sleep(5.0)
                deadline = time.time() + 45.0
                forked_processes: list[dict] = []
                while time.time() < deadline:
                    try:
                        process_result = _rpc("extension/runtimeProcesses", request_id=203, timeout=5.0)
                    except Exception as exc:
                        process_result = {"pollError": str(exc)}
                        time.sleep(0.5)
                        continue
                    if not isinstance(process_result, dict):
                        time.sleep(0.5)
                        continue
                    forked_processes = [
                        item
                        for item in process_result.get("forkedProcesses", [])
                        if isinstance(item, dict)
                    ]
                    try:
                        debug_state = _rpc(
                            "extension/debugState",
                            {
                                "configSection": "tailwindCSS",
                                "configKeys": ["experimental.configFile", "includeLanguages"],
                                "inspect": True,
                            },
                            request_id=204,
                            timeout=5.0,
                        )
                    except Exception as exc:
                        debug_state = {"pollError": str(exc)}
                        time.sleep(0.5)
                        continue
                    provider_counts = debug_state.get("providerCounts", {}) if isinstance(debug_state, dict) else {}
                    if any("tailwindServer.js" in str(item.get("modulePath", "")) for item in forked_processes) and (
                        provider_counts.get("completions", 0) or provider_counts.get("colors", 0)
                    ):
                        break
                    time.sleep(0.5)
                provider_result = _rpc(
                    "extension/languageProviders",
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": TAILWIND_LANGUAGE_RUNTIME["languageId"],
                        "text": source_text,
                        "line": 0,
                        "character": character,
                        "triggerCharacter": "-",
                    },
                    request_id=205,
                    timeout=20.0,
                )
                activation_errors = _activation_errors_payload(request_id=206)
                activation_error_items = (
                    activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []
                )
                relevant_activation_errors = [
                    error
                    for error in activation_error_items
                    if str(error.get("extensionId", "")).lower()
                    in {TAILWIND_LANGUAGE_RUNTIME["extensionId"].lower(), install_path.name.lower()}
                ]
                if relevant_activation_errors:
                    raise AssertionError(f"tailwind runtime activation error(s): {relevant_activation_errors}")
                tailwind_server_processes = [
                    item
                    for item in forked_processes
                    if "tailwindServer.js" in str(item.get("modulePath", ""))
                    and str(item.get("modulePath", "")).lower().find("vscode-tailwindcss") >= 0
                ]
                if not tailwind_server_processes:
                    raise AssertionError(
                        f"tailwind did not start a visible bundled language-server process: processes={process_result!r}"
                    )
                provider_resolution = provider_result.get("providerResolution", {})
                provider_counts = debug_state.get("providerCounts", {}) if isinstance(debug_state, dict) else {}
                if not provider_counts.get("completions") or not provider_counts.get("colors"):
                    raise AssertionError(
                        f"tailwind completion/color providers were not registered: debugState={debug_state!r}"
                    )
                completion_items = (provider_result.get("completion", {}) if isinstance(provider_result, dict) else {}).get("items", [])
                if not completion_items:
                    raise AssertionError(
                        f"tailwind completion provider did not return completion items: providerResult={provider_result!r}; debugState={debug_state!r}"
                    )
                return {
                    "port": port,
                    "extensionId": TAILWIND_LANGUAGE_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "languageId": TAILWIND_LANGUAGE_RUNTIME["languageId"],
                    "sourceFile": str(source_path),
                    "configFile": str(config_path),
                    "activeDocument": active_document,
                    "activationResult": activation_result,
                    "runtimeProcesses": process_result,
                    "providerResolution": provider_resolution,
                    "providerResult": provider_result,
                    "completionCount": len(completion_items),
                    "completionSample": completion_items[:8],
                    "debugState": debug_state,
                    "activationErrors": relevant_activation_errors,
                    "status": "tailwind-language-server-completion-runtime-verified",
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "extensionId": TAILWIND_LANGUAGE_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "status": "tailwind-language-server-runtime-failed",
                    "blockedReason": str(exc),
                    "runtimeProcesses": process_result,
                    "providerResult": provider_result,
                    "debugState": debug_state,
                    "activationResult": locals().get("activation_result"),
                    "activationErrors": activation_errors,
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def run_pyrefly_degraded_runtime_smoke() -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "language-vsix"
    namespace, name = PYREFLY_DEGRADED_RUNTIME["extensionId"].split(".", 1)
    metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
    package = _package_record(PYREFLY_DEGRADED_RUNTIME["extensionId"], metadata, cache_dir)
    if package["status"] != "downloaded-and-manifest-verified":
        return {
            "extensionId": PYREFLY_DEGRADED_RUNTIME["extensionId"],
            "status": "pyrefly-package-unavailable",
            "package": package,
        }

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-pyrefly-runtime-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        source_path = workspace / str(PYREFLY_DEGRADED_RUNTIME["file"])
        source_text = str(PYREFLY_DEGRADED_RUNTIME["source"])
        source_path.write_text(source_text, encoding="utf-8")

        manifest = _vsix_manifest(Path(str(package["cachePath"])))
        install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)
        bundled_binary = _binary_probe(install_path / "bin" / "pyrefly")

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_DEFER_STARTUP_EXTENSIONS"] = "1"
        env["WIZP_EXTENSION_CONFIGURATION_JSON"] = json.dumps(
            {
                "pyrefly": {
                    "lspPath": "",
                    "lspArguments": ["lsp"],
                    "trace": {"server": "off"},
                },
                "python": {
                    "pyrefly": {
                        "disableLanguageServices": False,
                        "displayTypeErrors": "default",
                        "runnableCodeLens": False,
                    },
                    "analysis": {
                        "completeFunctionParens": False,
                        "showHoverGoToLinks": True,
                    },
                },
            }
        )
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            process_result: dict = {}
            debug_state: dict = {}
            activation_result: dict = {}
            activation_errors: dict = {}
            ui_events: list = []
            activation_exception = None
            try:
                _wait_for_server(timeout=30.0)
                _wait_for_command_surface(set(_manifest_commands(manifest)), timeout=30.0)
                active_document = _set_active_text_document(
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": PYREFLY_DEGRADED_RUNTIME["languageId"],
                        "content": source_text,
                        "line": 0,
                        "character": 4,
                    },
                    request_id=211,
                )
                try:
                    activation_result = _activate_by_event(
                        f"onLanguage:{PYREFLY_DEGRADED_RUNTIME['languageId']}",
                        request_id=212,
                        timeout=30.0,
                    )
                except Exception as exc:
                    activation_exception = str(exc)
                deadline = time.time() + 10.0
                while time.time() < deadline:
                    try:
                        process_result = _rpc("extension/runtimeProcesses", request_id=213, timeout=5.0)
                    except Exception as exc:
                        process_result = {"pollError": str(exc)}
                    try:
                        debug_state = _rpc(
                            "extension/debugState",
                            {
                                "configSection": "pyrefly",
                                "configKeys": ["lspPath", "lspArguments", "trace.server"],
                                "inspect": True,
                            },
                            request_id=214,
                            timeout=5.0,
                        )
                    except Exception as exc:
                        debug_state = {"pollError": str(exc)}
                    ui_events.extend(_poll_extension_ui())
                    if isinstance(process_result, dict) and process_result.get("spawnedProcesses"):
                        break
                    if isinstance(debug_state, dict) and debug_state.get("providerCounts", {}).get("diagnostics"):
                        break
                    time.sleep(0.75)
                activation_errors = _activation_errors_payload(request_id=215)
                health = _rpc("extension/debugState", request_id=216, timeout=10.0)
                host_compatible = bundled_binary.get("hostCompatible")
                machine_name = (bundled_binary.get("elf") or {}).get("machineName")
                if bundled_binary.get("exists") is not True or machine_name != "aarch64" or host_compatible is not False:
                    raise AssertionError(f"pyrefly bundled binary probe did not record expected platform mismatch: {bundled_binary!r}")
                run_probe = bundled_binary.get("runProbe") or {}
                run_text = " ".join(str(run_probe.get(key, "")) for key in ("status", "error", "stderr", "stdout")).lower()
                if "exec format" not in run_text and run_probe.get("status") != "os-error":
                    raise AssertionError(f"pyrefly incompatible binary run probe was not explicit: {run_probe!r}")
                return {
                    "port": port,
                    "extensionId": PYREFLY_DEGRADED_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "languageId": PYREFLY_DEGRADED_RUNTIME["languageId"],
                    "sourceFile": str(source_path),
                    "activeDocument": active_document,
                    "bundledBinary": bundled_binary,
                    "activationResult": activation_result,
                    "activationException": activation_exception,
                    "activationErrors": activation_errors,
                    "runtimeProcesses": process_result,
                    "debugState": debug_state,
                    "health": health,
                    "uiEvents": ui_events[-10:],
                    "status": "pyrefly-bundled-binary-platform-mismatch-verified",
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "extensionId": PYREFLY_DEGRADED_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "status": "pyrefly-bundled-binary-platform-mismatch-failed",
                    "blockedReason": str(exc),
                    "bundledBinary": bundled_binary,
                    "activationResult": activation_result,
                    "activationException": activation_exception,
                    "activationErrors": activation_errors,
                    "runtimeProcesses": process_result,
                    "debugState": debug_state,
                    "uiEvents": ui_events[-10:],
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def run_rust_analyzer_degraded_runtime_smoke() -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "language-vsix"
    namespace, name = RUST_ANALYZER_DEGRADED_RUNTIME["extensionId"].split(".", 1)
    metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
    package = _package_record(RUST_ANALYZER_DEGRADED_RUNTIME["extensionId"], metadata, cache_dir)
    if package["status"] != "downloaded-and-manifest-verified":
        return {
            "extensionId": RUST_ANALYZER_DEGRADED_RUNTIME["extensionId"],
            "status": "rust-analyzer-package-unavailable",
            "package": package,
        }

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-rust-analyzer-runtime-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        source_path = workspace / str(RUST_ANALYZER_DEGRADED_RUNTIME["file"])
        source_path.parent.mkdir(parents=True, exist_ok=True)
        source_text = str(RUST_ANALYZER_DEGRADED_RUNTIME["source"])
        source_path.write_text(source_text, encoding="utf-8")
        (workspace / "Cargo.toml").write_text(str(RUST_ANALYZER_DEGRADED_RUNTIME["cargoToml"]), encoding="utf-8")

        manifest = _vsix_manifest(Path(str(package["cachePath"])))
        install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_EXTENSION_ACTIVATION_TIMEOUT_MS"] = "6000"
        env["WIZP_EXTENSION_CONFIGURATION_JSON"] = json.dumps(
            {
                "rust-analyzer": {
                    "server": {
                        "path": RUST_ANALYZER_DEGRADED_RUNTIME["missingPath"],
                        "extraEnv": {},
                    },
                    "checkOnSave": False,
                    "cargo": {"buildScripts": {"enable": False}},
                    "procMacro": {"enable": False},
                    "testExplorer": False,
                    "showDependenciesExplorer": False,
                    "showSyntaxTree": False,
                    "initializeStopped": False,
                    "statusBar": {"showStatusBar": "never"},
                    "trace": {"server": "off"},
                }
            }
        )
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            process_result: dict = {}
            debug_state: dict = {}
            provider_result: dict = {}
            activation_errors: dict = {}
            ui_events: list = []
            try:
                _wait_for_server(timeout=30.0)
                _wait_for_command_surface(set(_manifest_commands(manifest)), timeout=30.0)
                active_document = _set_active_text_document(
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": RUST_ANALYZER_DEGRADED_RUNTIME["languageId"],
                        "content": source_text,
                        "line": 0,
                        "character": 3,
                    },
                    request_id=221,
                )
                deadline = time.time() + 20.0
                while time.time() < deadline:
                    try:
                        process_result = _rpc("extension/runtimeProcesses", request_id=222, timeout=5.0)
                    except Exception as exc:
                        process_result = {"pollError": str(exc)}
                    try:
                        debug_state = _rpc(
                            "extension/debugState",
                            {
                                "configSection": "rust-analyzer",
                                "configKeys": ["server.path", "server.extraEnv", "checkOnSave", "initializeStopped"],
                                "inspect": True,
                            },
                            request_id=223,
                            timeout=5.0,
                        )
                    except Exception as exc:
                        debug_state = {"pollError": str(exc)}
                    ui_events.extend(_poll_extension_ui())
                    message_text = " ".join(str(event) for event in ui_events).lower()
                    if "rust-analyzer" in message_text and (
                        "not available" in message_text
                        or "failed to execute" in message_text
                        or "bootstrap error" in message_text
                        or "cannot activate" in message_text
                    ):
                        break
                    time.sleep(0.75)
                provider_result = _rpc(
                    "extension/languageProviders",
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": RUST_ANALYZER_DEGRADED_RUNTIME["languageId"],
                        "text": source_text,
                        "line": 0,
                        "character": 3,
                    },
                    request_id=224,
                    timeout=15.0,
                )
                activation_errors = _activation_errors_payload(request_id=225)
                activation_error_items = activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []
                relevant_activation_errors = [
                    error
                    for error in activation_error_items
                    if str(error.get("id", error.get("extensionId", ""))).lower()
                    in {RUST_ANALYZER_DEGRADED_RUNTIME["extensionId"].lower(), install_path.name.lower(), "rust-analyzer"}
                ]
                spawned_processes = process_result.get("spawnedProcesses", []) if isinstance(process_result, dict) else []
                real_rust_analyzer_processes = [
                    item
                    for item in spawned_processes
                    if isinstance(item, dict)
                    and item.get("pid", 0)
                    and (
                        "rust-analyzer" in str(item.get("command", "")).lower()
                        or any("rust-analyzer" in str(arg).lower() for arg in item.get("args", []))
                    )
                ]
                if real_rust_analyzer_processes:
                    raise AssertionError(
                        f"rust-analyzer degraded smoke unexpectedly started a real server process: {real_rust_analyzer_processes}"
                    )
                message_text = " ".join(str(event) for event in ui_events + relevant_activation_errors).lower()
                if "rust-analyzer" not in message_text or not any(
                    marker in message_text for marker in ("not available", "failed to execute", "bootstrap error", "cannot activate")
                ):
                    raise AssertionError(
                        f"rust-analyzer degraded smoke did not surface missing-server UX: uiEvents={ui_events!r}; activationErrors={activation_errors!r}"
                    )
                return {
                    "port": port,
                    "extensionId": RUST_ANALYZER_DEGRADED_RUNTIME["extensionId"],
                    "version": package.get("version"),
                    "package": package,
                    "installDirName": install_path.name,
                    "languageId": RUST_ANALYZER_DEGRADED_RUNTIME["languageId"],
                    "sourceFile": str(source_path),
                    "missingPath": RUST_ANALYZER_DEGRADED_RUNTIME["missingPath"],
                    "activeDocument": active_document,
                    "runtimeProcesses": process_result,
                    "providerResolution": provider_result.get("providerResolution", {}) if isinstance(provider_result, dict) else {},
                    "debugState": debug_state,
                    "uiEvents": ui_events[-12:],
                    "activationErrors": relevant_activation_errors,
                    "status": "rust-analyzer-missing-binary-degraded-verified",
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "extensionId": RUST_ANALYZER_DEGRADED_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "status": "rust-analyzer-missing-binary-degraded-failed",
                    "blockedReason": str(exc),
                    "runtimeProcesses": process_result,
                    "providerResult": provider_result,
                    "debugState": debug_state,
                    "uiEvents": ui_events[-12:],
                    "activationErrors": activation_errors,
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def run_redhat_java_bounded_activation_smoke() -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "language-vsix"
    namespace, name = REDHAT_JAVA_BOUNDED_RUNTIME["extensionId"].split(".", 1)
    metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
    package = _package_record(REDHAT_JAVA_BOUNDED_RUNTIME["extensionId"], metadata, cache_dir)
    if package["status"] != "downloaded-and-manifest-verified":
        return {
            "extensionId": REDHAT_JAVA_BOUNDED_RUNTIME["extensionId"],
            "status": "redhat-java-package-unavailable",
            "package": package,
        }

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-redhat-java-runtime-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()

        manifest = _vsix_manifest(Path(str(package["cachePath"])))
        install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_EXTENSION_ACTIVATION_TIMEOUT_MS"] = "6000"
        env["WIZP_EXTENSION_CONFIGURATION_JSON"] = json.dumps(
            {
                "java": {
                    "server": {"launchMode": "Standard"},
                    "jdt": {"ls": {"java": {"home": REDHAT_JAVA_BOUNDED_RUNTIME["missingJavaHome"]}}},
                    "transport": "stdio",
                },
                "redhat": {"telemetry": {"enabled": False}},
            }
        )
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            command_payload: dict = {}
            debug_state: dict = {}
            active_document: dict = {}
            activation_result: dict = {}
            activation_errors: dict = {}
            process_result: dict = {}
            provider_result: dict = {}
            ui_events: list = []
            health: dict = {}
            try:
                _wait_for_server(timeout=30.0)
                command_payload, discovered_commands = _wait_for_command_surface(set(_manifest_commands(manifest)), timeout=45.0)
                missing_commands = sorted(set(_manifest_commands(manifest)) - discovered_commands)
                if missing_commands:
                    raise AssertionError(f"redhat.java command surface missing commands: {missing_commands[:10]}")

                (workspace / "pom.xml").write_text(str(REDHAT_JAVA_BOUNDED_RUNTIME["pomXml"]), encoding="utf-8")
                source_path = workspace / str(REDHAT_JAVA_BOUNDED_RUNTIME["file"])
                source_path.parent.mkdir(parents=True, exist_ok=True)
                source_text = str(REDHAT_JAVA_BOUNDED_RUNTIME["source"])
                source_path.write_text(source_text, encoding="utf-8")
                active_document = _set_active_text_document(
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": REDHAT_JAVA_BOUNDED_RUNTIME["languageId"],
                        "content": source_text,
                        "line": 0,
                        "character": 13,
                    },
                    request_id=231,
                )
                debug_state = _rpc(
                    "extension/debugState",
                    {
                        "configSection": "java",
                        "configKeys": ["jdt.ls.java.home", "server.launchMode", "transport"],
                        "inspect": True,
                    },
                    request_id=232,
                    timeout=10.0,
                )
                try:
                    activation_result = _activate_by_event("workspaceContains:pom.xml", request_id=233, timeout=40.0)
                    status = "redhat-java-activation-returned-unexpectedly"
                except TimeoutError as exc:
                    activation_result = {"timeout": str(exc), "event": "workspaceContains:pom.xml", "timeoutSeconds": 40}
                    status = "redhat-java-activation-timeout-bounded"
                except Exception as exc:
                    activation_result = {"error": str(exc), "event": "workspaceContains:pom.xml"}
                    status = "redhat-java-activation-error-bounded"

                deadline = time.time() + 8.0
                while time.time() < deadline:
                    try:
                        process_result = _rpc("extension/runtimeProcesses", request_id=234, timeout=5.0)
                    except Exception as exc:
                        process_result = {"pollError": str(exc)}
                    try:
                        activation_errors = _activation_errors_payload(request_id=235)
                    except Exception as exc:
                        activation_errors = {"pollError": str(exc)}
                    ui_events.extend(_poll_extension_ui())
                    message_text = " ".join(str(event) for event in ui_events + [activation_errors, activation_result]).lower()
                    if "java" in message_text or "jdt" in message_text or "jdk" in message_text:
                        break
                    time.sleep(0.5)
                try:
                    provider_result = _rpc(
                        "extension/languageProviders",
                        {
                            "uri": source_path.resolve().as_uri(),
                            "languageId": REDHAT_JAVA_BOUNDED_RUNTIME["languageId"],
                            "text": source_text,
                            "line": 0,
                            "character": 13,
                        },
                        request_id=236,
                        timeout=8.0,
                    )
                except Exception as exc:
                    provider_result = {"pollError": str(exc)}
                try:
                    health = _rpc("extension/debugState", request_id=237, timeout=5.0)
                except Exception as exc:
                    health = {"pollError": str(exc)}
                if isinstance(activation_errors, dict) and activation_errors.get("pollError") and status == "redhat-java-activation-timeout-bounded":
                    try:
                        activation_errors = _activation_errors_payload(request_id=238)
                    except Exception as exc:
                        activation_errors = {"pollError": str(exc)}
                if isinstance(process_result, dict) and process_result.get("pollError") and status == "redhat-java-activation-timeout-bounded":
                    try:
                        process_result = _rpc("extension/runtimeProcesses", request_id=239, timeout=5.0)
                    except Exception as exc:
                        process_result = {"pollError": str(exc)}
                spawned_processes = process_result.get("spawnedProcesses", []) if isinstance(process_result, dict) else []
                forked_processes = process_result.get("forkedProcesses", []) if isinstance(process_result, dict) else []
                real_java_processes = [
                    item
                    for item in list(spawned_processes) + list(forked_processes)
                    if isinstance(item, dict)
                    and item.get("pid", 0)
                    and (
                        "java" in str(item.get("command", "")).lower()
                        or "jdt" in str(item.get("command", "")).lower()
                        or "java" in str(item.get("modulePath", "")).lower()
                        or "jdt" in str(item.get("modulePath", "")).lower()
                        or any("java" in str(arg).lower() or "jdt" in str(arg).lower() for arg in item.get("args", []))
                    )
                ]
                if real_java_processes:
                    status = "redhat-java-runtime-process-bounded"
                else:
                    message_text = " ".join(str(event) for event in ui_events + [activation_errors, activation_result]).lower()
                    if (
                        status in {"redhat-java-activation-error-bounded", "redhat-java-activation-timeout-bounded"}
                        and "activationhosttimeout" in message_text
                        and isinstance(health, dict)
                        and not health.get("pollError")
                        and isinstance(process_result, dict)
                        and not process_result.get("pollError")
                    ):
                        status = "redhat-java-activation-host-timeout-recovered"
                    elif status in {"redhat-java-activation-returned-unexpectedly", "redhat-java-activation-error-bounded"} and any(
                        marker in message_text for marker in ("java runtime", "jdk", "jdt", "java home", REDHAT_JAVA_BOUNDED_RUNTIME["missingJavaHome"].lower())
                    ) and isinstance(health, dict) and not health.get("pollError"):
                        status = "redhat-java-missing-jdk-degraded-verified"
                    elif status == "redhat-java-activation-timeout-bounded" and (
                        isinstance(process_result, dict)
                        and process_result.get("pollError") == "timed out"
                        and isinstance(health, dict)
                        and health.get("pollError") == "timed out"
                    ):
                        status = "redhat-java-activation-timeout-host-blocking-bounded"
                    elif status == "redhat-java-activation-timeout-bounded" and (
                        isinstance(health, dict)
                        and not health.get("pollError")
                        and isinstance(process_result, dict)
                        and not process_result.get("pollError")
                    ):
                        status = "redhat-java-activation-timeout-host-recovered"
                return {
                    "port": port,
                    "extensionId": REDHAT_JAVA_BOUNDED_RUNTIME["extensionId"],
                    "version": package.get("version"),
                    "package": package,
                    "installDirName": install_path.name,
                    "languageId": REDHAT_JAVA_BOUNDED_RUNTIME["languageId"],
                    "missingJavaHome": REDHAT_JAVA_BOUNDED_RUNTIME["missingJavaHome"],
                    "activeDocument": active_document,
                    "commandCount": len(command_payload.get("commands", [])) if isinstance(command_payload, dict) else 0,
                    "debugState": debug_state,
                    "activationResult": activation_result,
                    "activationErrors": activation_errors,
                    "runtimeProcesses": process_result,
                    "providerResult": provider_result,
                    "health": health,
                    "uiEvents": ui_events[-12:],
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                    "status": status,
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "extensionId": REDHAT_JAVA_BOUNDED_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "status": "redhat-java-bounded-activation-probe-failed",
                    "blockedReason": str(exc),
                    "commandPayload": command_payload,
                    "debugState": debug_state,
                    "activeDocument": active_document,
                    "activationResult": activation_result,
                    "activationErrors": activation_errors,
                    "runtimeProcesses": process_result,
                    "providerResult": provider_result,
                    "health": health,
                    "uiEvents": ui_events[-12:],
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def _redhat_java_valid_jdk_home() -> Path | None:
    candidates: list[Path] = []
    for value in (
        os.environ.get("WIZP_REDHAT_JAVA_VALID_JDK_HOME"),
        os.environ.get("JAVA_HOME"),
        "/opt/android-studio/jbr",
        "/usr/lib/jvm/java-26-openjdk",
    ):
        if value:
            candidates.append(Path(value))
    java_bin = shutil.which("java")
    javac_bin = shutil.which("javac")
    if java_bin and javac_bin:
        candidates.append(Path(java_bin).resolve().parents[1])
    seen: set[str] = set()
    for candidate in candidates:
        key = str(candidate)
        if key in seen:
            continue
        seen.add(key)
        if (candidate / "bin" / "java").exists() and (candidate / "bin" / "javac").exists():
            return candidate
    return None


def run_redhat_java_valid_jdk_timeout_smoke() -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    jdk_home = _redhat_java_valid_jdk_home()
    if not jdk_home:
        return {
            "extensionId": REDHAT_JAVA_BOUNDED_RUNTIME["extensionId"],
            "status": "redhat-java-valid-jdk-timeout-skipped-no-jdk",
            "blockedReason": "No local JDK with bin/java and bin/javac was found for the valid-JDK bounded activation probe.",
        }
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "language-vsix"
    namespace, name = REDHAT_JAVA_BOUNDED_RUNTIME["extensionId"].split(".", 1)
    metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
    package = _package_record(REDHAT_JAVA_BOUNDED_RUNTIME["extensionId"], metadata, cache_dir)
    if package["status"] != "downloaded-and-manifest-verified":
        return {
            "extensionId": REDHAT_JAVA_BOUNDED_RUNTIME["extensionId"],
            "status": "redhat-java-valid-jdk-package-unavailable",
            "package": package,
        }

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-redhat-java-valid-jdk-timeout-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()

        manifest = _vsix_manifest(Path(str(package["cachePath"])))
        install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_DEFER_STARTUP_EXTENSIONS"] = "1"
        env["JAVA_HOME"] = str(jdk_home)
        env["PATH"] = str(jdk_home / "bin") + os.pathsep + env.get("PATH", "")
        env["WIZP_EXTENSION_ACTIVATION_TIMEOUT_MS"] = "6000"
        env["WIZP_EXTENSION_CONFIGURATION_JSON"] = json.dumps(
            {
                "java": {
                    "home": str(jdk_home),
                    "server": {"launchMode": "Standard"},
                    "jdt": {"ls": {"java": {"home": str(jdk_home)}}},
                    "transport": "stdio",
                    "imports": {"maven": {"enabled": True}, "gradle": {"enabled": False}},
                    "autobuild": {"enabled": False},
                    "configuration": {"updateBuildConfiguration": "disabled"},
                },
                "redhat": {"telemetry": {"enabled": False}},
            }
        )
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
                start_new_session=True,
            )
            command_payload: dict = {}
            active_document: dict = {}
            activation_result: dict = {}
            activation_errors: dict = {}
            process_result: dict = {}
            provider_result: dict = {}
            health: dict = {}
            ui_events: list = []
            activation_elapsed = 0.0
            try:
                _wait_for_server(timeout=30.0)
                command_payload, discovered_commands = _wait_for_command_surface(set(_manifest_commands(manifest)), timeout=45.0)
                missing_commands = sorted(set(_manifest_commands(manifest)) - discovered_commands)
                if missing_commands:
                    raise AssertionError(f"redhat.java valid-JDK command surface missing commands: {missing_commands[:10]}")

                (workspace / "pom.xml").write_text(str(REDHAT_JAVA_BOUNDED_RUNTIME["pomXml"]), encoding="utf-8")
                source_path = workspace / str(REDHAT_JAVA_BOUNDED_RUNTIME["file"])
                source_path.parent.mkdir(parents=True, exist_ok=True)
                source_text = str(REDHAT_JAVA_BOUNDED_RUNTIME["source"])
                source_path.write_text(source_text, encoding="utf-8")
                active_document = _set_active_text_document(
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": REDHAT_JAVA_BOUNDED_RUNTIME["languageId"],
                        "content": source_text,
                        "line": 0,
                        "character": 13,
                    },
                    request_id=291,
                    timeout=10.0,
                )
                started = time.time()
                try:
                    activation_result = _rpc("extension/activateByEvent", {"event": "workspaceContains:pom.xml"}, request_id=292, timeout=20.0)
                except Exception as exc:
                    activation_result = {"error": str(exc), "event": "workspaceContains:pom.xml"}
                activation_elapsed = time.time() - started
                try:
                    process_result = _rpc("extension/runtimeProcesses", request_id=293, timeout=8.0)
                except Exception as exc:
                    process_result = {"pollError": str(exc)}
                try:
                    activation_errors = _activation_errors_payload(request_id=294)
                except Exception as exc:
                    activation_errors = {"pollError": str(exc)}
                try:
                    health = _rpc("extension/debugState", request_id=295, timeout=8.0)
                except Exception as exc:
                    health = {"pollError": str(exc)}
                try:
                    provider_result = _rpc(
                        "extension/languageProviders",
                        {
                            "uri": source_path.resolve().as_uri(),
                            "languageId": REDHAT_JAVA_BOUNDED_RUNTIME["languageId"],
                            "text": source_text,
                            "line": 0,
                            "character": 13,
                        },
                        request_id=296,
                        timeout=8.0,
                    )
                except Exception as exc:
                    provider_result = {"pollError": str(exc)}
                ui_events.extend(_poll_extension_ui())
                spawned_processes = process_result.get("spawnedProcesses", []) if isinstance(process_result, dict) else []
                forked_processes = process_result.get("forkedProcesses", []) if isinstance(process_result, dict) else []
                java_like_processes = [
                    item
                    for item in list(spawned_processes) + list(forked_processes)
                    if isinstance(item, dict)
                    and (
                        "java" in str(item.get("command", "")).lower()
                        or "jdt" in str(item.get("command", "")).lower()
                        or any("java" in str(arg).lower() or "jdt" in str(arg).lower() for arg in item.get("args", []))
                    )
                ]
                activation_error_names = [
                    item.get("name")
                    for item in activation_errors.get("errors", [])
                    if isinstance(item, dict)
                ] if isinstance(activation_errors, dict) else []
                if java_like_processes:
                    status = "redhat-java-valid-jdk-started-jdt-bounded"
                elif "ActivationHostTimeout" in activation_error_names and isinstance(health, dict) and not health.get("pollError"):
                    status = "redhat-java-valid-jdk-host-timeout-recovered"
                else:
                    status = "redhat-java-valid-jdk-timeout-unverified"
                return {
                    "port": port,
                    "extensionId": REDHAT_JAVA_BOUNDED_RUNTIME["extensionId"],
                    "version": package.get("version"),
                    "package": package,
                    "installDirName": install_path.name,
                    "jdkHome": str(jdk_home),
                    "activationTimeoutMs": 6000,
                    "activationElapsedSeconds": round(activation_elapsed, 2),
                    "activeDocument": active_document,
                    "commandCount": len(command_payload.get("commands", [])) if isinstance(command_payload, dict) else 0,
                    "activationResult": activation_result,
                    "activationErrors": activation_errors,
                    "runtimeProcesses": process_result,
                    "javaLikeProcesses": java_like_processes[:5],
                    "providerResult": provider_result,
                    "health": health,
                    "uiEvents": ui_events[-12:],
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                    "status": status,
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "extensionId": REDHAT_JAVA_BOUNDED_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "jdkHome": str(jdk_home),
                    "status": "redhat-java-valid-jdk-timeout-probe-failed",
                    "blockedReason": str(exc),
                    "activeDocument": active_document,
                    "activationResult": activation_result,
                    "activationErrors": activation_errors,
                    "runtimeProcesses": process_result,
                    "providerResult": provider_result,
                    "health": health,
                    "uiEvents": ui_events[-12:],
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    try:
                        os.killpg(proc.pid, signal.SIGTERM)
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(proc.pid, signal.SIGKILL)
                        proc.wait(timeout=5)
                    except ProcessLookupError:
                        pass


def run_go_missing_tool_degraded_smoke() -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "language-vsix"
    namespace, name = GO_DEGRADED_RUNTIME["extensionId"].split(".", 1)
    metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
    package = _package_record(GO_DEGRADED_RUNTIME["extensionId"], metadata, cache_dir)
    if package["status"] != "downloaded-and-manifest-verified":
        return {
            "extensionId": GO_DEGRADED_RUNTIME["extensionId"],
            "status": "go-package-unavailable",
            "package": package,
        }

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-go-runtime-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        empty_bin = root / "empty-bin"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        empty_bin.mkdir()
        (workspace / "go.mod").write_text(str(GO_DEGRADED_RUNTIME["goMod"]), encoding="utf-8")
        source_path = workspace / str(GO_DEGRADED_RUNTIME["file"])
        source_text = str(GO_DEGRADED_RUNTIME["source"])
        source_path.write_text(source_text, encoding="utf-8")

        manifest = _vsix_manifest(Path(str(package["cachePath"])))
        install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_DEFER_STARTUP_EXTENSIONS"] = "1"
        env["WIZP_EXTENSION_ACTIVATION_TIMEOUT_MS"] = "8000"
        env["PATH"] = str(empty_bin)
        env["WIZP_EXTENSION_CONFIGURATION_JSON"] = json.dumps(
            {
                "go": {
                    "useLanguageServer": True,
                    "languageServerFlags": [],
                    "toolsManagement": {"autoUpdate": False},
                    "alternateTools": {
                        "go": GO_DEGRADED_RUNTIME["missingGo"],
                        "gopls": GO_DEGRADED_RUNTIME["missingGopls"],
                    },
                }
            }
        )
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            process_result: dict = {}
            debug_state: dict = {}
            active_document: dict = {}
            activation_errors: dict = {}
            ui_events: list = []
            try:
                _wait_for_server(timeout=30.0)
                command_payload, discovered_commands = _wait_for_command_surface(set(_manifest_commands(manifest)), timeout=45.0)
                missing_commands = sorted(set(_manifest_commands(manifest)) - discovered_commands)
                if missing_commands:
                    raise AssertionError(f"golang.Go command surface missing commands: {missing_commands[:10]}")
                active_document = _set_active_text_document(
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": GO_DEGRADED_RUNTIME["languageId"],
                        "content": source_text,
                        "line": 0,
                        "character": 8,
                    },
                    request_id=241,
                )
                try:
                    _activate_by_event(f"onLanguage:{GO_DEGRADED_RUNTIME['languageId']}", request_id=242, timeout=20.0)
                except Exception:
                    pass
                deadline = time.time() + 10.0
                while time.time() < deadline:
                    process_result = _rpc("extension/runtimeProcesses", request_id=243, timeout=10.0)
                    activation_errors = _activation_errors_payload(request_id=244)
                    ui_events.extend(_poll_extension_ui())
                    message_text = " ".join(str(event) for event in ui_events + [activation_errors]).lower()
                    if "go" in message_text and any(marker in message_text for marker in ("failed to find", "go binary", "gopls", "install go")):
                        break
                    time.sleep(0.5)
                debug_state = _rpc(
                    "extension/debugState",
                    {
                        "configSection": "go",
                        "configKeys": ["useLanguageServer", "alternateTools", "toolsManagement.autoUpdate"],
                        "inspect": True,
                    },
                    request_id=245,
                    timeout=10.0,
                )
                spawned_processes = process_result.get("spawnedProcesses", []) if isinstance(process_result, dict) else []
                real_go_processes = [
                    item
                    for item in spawned_processes
                    if isinstance(item, dict)
                    and item.get("pid", 0)
                    and (
                        str(item.get("command", "")).endswith("/go")
                        or "gopls" in str(item.get("command", "")).lower()
                        or any(str(arg).endswith("/go") or "gopls" in str(arg).lower() for arg in item.get("args", []))
                    )
                ]
                if real_go_processes:
                    raise AssertionError(f"go degraded smoke unexpectedly started Go/gopls process: {real_go_processes}")
                message_text = " ".join(str(event) for event in ui_events + [activation_errors]).lower()
                if "go" not in message_text or not any(
                    marker in message_text for marker in ("failed to find", "go binary", "install go", "gopls")
                ):
                    raise AssertionError(f"go degraded smoke did not surface missing-tool UX: uiEvents={ui_events!r}; activationErrors={activation_errors!r}")
                return {
                    "port": port,
                    "extensionId": GO_DEGRADED_RUNTIME["extensionId"],
                    "version": package.get("version"),
                    "package": package,
                    "installDirName": install_path.name,
                    "languageId": GO_DEGRADED_RUNTIME["languageId"],
                    "sourceFile": str(source_path),
                    "missingGo": GO_DEGRADED_RUNTIME["missingGo"],
                    "missingGopls": GO_DEGRADED_RUNTIME["missingGopls"],
                    "activeDocument": active_document,
                    "commandCount": len(command_payload.get("commands", [])) if isinstance(command_payload, dict) else 0,
                    "runtimeProcesses": process_result,
                    "debugState": debug_state,
                    "uiEvents": ui_events[-12:],
                    "activationErrors": activation_errors,
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                    "status": "go-missing-tool-degraded-verified",
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "extensionId": GO_DEGRADED_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "status": "blocked-go-missing-tool",
                    "blockedReason": str(exc),
                    "runtimeProcesses": process_result,
                    "debugState": debug_state,
                    "activeDocument": active_document,
                    "uiEvents": ui_events[-12:],
                    "activationErrors": activation_errors,
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def run_ruby_lsp_degraded_runtime_smoke() -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "language-vsix"
    namespace, name = RUBY_LSP_DEGRADED_RUNTIME["extensionId"].split(".", 1)
    metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
    package = _package_record(RUBY_LSP_DEGRADED_RUNTIME["extensionId"], metadata, cache_dir)
    if package["status"] != "downloaded-and-manifest-verified":
        return {
            "extensionId": RUBY_LSP_DEGRADED_RUNTIME["extensionId"],
            "status": "ruby-lsp-package-unavailable",
            "package": package,
        }

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-ruby-lsp-runtime-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        (workspace / "Gemfile").write_text(str(RUBY_LSP_DEGRADED_RUNTIME["gemfile"]), encoding="utf-8")
        (workspace / "Gemfile.lock").write_text(str(RUBY_LSP_DEGRADED_RUNTIME["gemfileLock"]), encoding="utf-8")
        source_path = workspace / str(RUBY_LSP_DEGRADED_RUNTIME["file"])
        source_text = str(RUBY_LSP_DEGRADED_RUNTIME["source"])
        source_path.write_text(source_text, encoding="utf-8")

        manifest = _vsix_manifest(Path(str(package["cachePath"])))
        install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_EXTENSION_CONFIGURATION_JSON"] = json.dumps(
            {
                "rubyLsp": {
                    "enabledFeatures": {},
                    "featureFlags": {},
                    "rubyVersionManager": {"identifier": "none"},
                    "rubyExecutablePath": RUBY_LSP_DEGRADED_RUNTIME["missingRuby"],
                    "bundleGemfile": "",
                    "testTimeout": 30,
                }
            }
        )
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            process_result: dict = {}
            debug_state: dict = {}
            active_document: dict = {}
            activation_result: dict = {}
            activation_errors: dict = {}
            ui_events: list = []
            try:
                _wait_for_server(timeout=30.0)
                command_payload, discovered_commands = _wait_for_command_surface(set(_manifest_commands(manifest)), timeout=45.0)
                missing_commands = sorted(set(_manifest_commands(manifest)) - discovered_commands)
                if missing_commands:
                    raise AssertionError(f"Shopify.ruby-lsp command surface missing commands: {missing_commands[:10]}")
                active_document = _set_active_text_document(
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": RUBY_LSP_DEGRADED_RUNTIME["languageId"],
                        "content": source_text,
                        "line": 0,
                        "character": 4,
                    },
                    request_id=251,
                )
                try:
                    activation_result = _activate_by_event("workspaceContains:Gemfile.lock", request_id=252, timeout=18.0)
                except TimeoutError as exc:
                    activation_result = {"timeout": str(exc), "event": "workspaceContains:Gemfile.lock", "timeoutSeconds": 18}
                except Exception as exc:
                    activation_result = {"error": str(exc), "event": "workspaceContains:Gemfile.lock"}

                deadline = time.time() + 8.0
                while time.time() < deadline:
                    process_result = _rpc("extension/runtimeProcesses", request_id=253, timeout=10.0)
                    activation_errors = _activation_errors_payload(request_id=254)
                    ui_events.extend(_poll_extension_ui())
                    message_text = " ".join(str(event) for event in ui_events + [activation_errors, activation_result]).lower()
                    if "ruby" in message_text or "bundle" in message_text or "gemfile" in message_text:
                        break
                    time.sleep(0.5)
                debug_state = _rpc(
                    "extension/debugState",
                    {
                        "configSection": "rubyLsp",
                        "configKeys": ["enabledFeatures", "featureFlags", "rubyVersionManager", "rubyExecutablePath", "bundleGemfile", "testTimeout"],
                        "inspect": True,
                    },
                    request_id=255,
                    timeout=10.0,
                )
                spawned_processes = process_result.get("spawnedProcesses", []) if isinstance(process_result, dict) else []
                real_ruby_processes = [
                    item
                    for item in spawned_processes
                    if isinstance(item, dict)
                    and item.get("pid", 0)
                    and (
                        "ruby" in str(item.get("command", "")).lower()
                        or any("ruby" in str(arg).lower() or "bundle" in str(arg).lower() for arg in item.get("args", []))
                    )
                ]
                if real_ruby_processes:
                    raise AssertionError(f"ruby-lsp degraded smoke unexpectedly started Ruby process: {real_ruby_processes}")
                message_text = " ".join(str(event) for event in ui_events + [activation_errors, activation_result]).lower()
                has_missing_runtime_ux = any(
                    marker in message_text
                    for marker in (
                        "ruby executable",
                        "missing ruby",
                        "bundle executable",
                        "no such file",
                        "enoent",
                        RUBY_LSP_DEGRADED_RUNTIME["missingRuby"].lower(),
                    )
                )
                non_runtime_activation_errors = []
                if activation_result.get("error") and not has_missing_runtime_ux:
                    non_runtime_activation_errors.append(activation_result.get("error"))
                for error in activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []:
                    error_text = str(error).lower()
                    if not any(
                        marker in error_text
                        for marker in (
                            "ruby executable",
                            "missing ruby",
                            "bundle executable",
                            "no such file",
                            "enoent",
                            RUBY_LSP_DEGRADED_RUNTIME["missingRuby"].lower(),
                        )
                    ):
                        non_runtime_activation_errors.append(error)
                if has_missing_runtime_ux and not non_runtime_activation_errors:
                    status = "ruby-lsp-missing-ruby-degraded-verified"
                else:
                    status = "ruby-lsp-activation-bounded-no-runtime-ux"
                return {
                    "port": port,
                    "extensionId": RUBY_LSP_DEGRADED_RUNTIME["extensionId"],
                    "version": package.get("version"),
                    "package": package,
                    "installDirName": install_path.name,
                    "languageId": RUBY_LSP_DEGRADED_RUNTIME["languageId"],
                    "sourceFile": str(source_path),
                    "missingRuby": RUBY_LSP_DEGRADED_RUNTIME["missingRuby"],
                    "activeDocument": active_document,
                    "commandCount": len(command_payload.get("commands", [])) if isinstance(command_payload, dict) else 0,
                    "activationResult": activation_result,
                    "runtimeProcesses": process_result,
                    "debugState": debug_state,
                    "uiEvents": ui_events[-12:],
                    "activationErrors": activation_errors,
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                    "status": status,
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "extensionId": RUBY_LSP_DEGRADED_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "status": "ruby-lsp-degraded-runtime-failed",
                    "blockedReason": str(exc),
                    "runtimeProcesses": process_result,
                    "debugState": debug_state,
                    "activeDocument": active_document,
                    "activationResult": activation_result,
                    "uiEvents": ui_events[-12:],
                    "activationErrors": activation_errors,
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def run_vue_volar_language_runtime_smoke() -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "language-vsix"
    namespace, name = VUE_LANGUAGE_RUNTIME["extensionId"].split(".", 1)
    metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
    package = _package_record(VUE_LANGUAGE_RUNTIME["extensionId"], metadata, cache_dir)
    if package["status"] != "downloaded-and-manifest-verified":
        return {
            "extensionId": VUE_LANGUAGE_RUNTIME["extensionId"],
            "status": "vue-volar-package-unavailable",
            "package": package,
        }

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-vue-volar-runtime-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        (workspace / "package.json").write_text(str(VUE_LANGUAGE_RUNTIME["packageJson"]), encoding="utf-8")
        (workspace / "tsconfig.json").write_text(str(VUE_LANGUAGE_RUNTIME["tsconfig"]), encoding="utf-8")
        source_path = workspace / str(VUE_LANGUAGE_RUNTIME["file"])
        source_path.parent.mkdir(parents=True, exist_ok=True)
        source_text = str(VUE_LANGUAGE_RUNTIME["source"])
        source_path.write_text(source_text, encoding="utf-8")

        manifest = _vsix_manifest(Path(str(package["cachePath"])))
        install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_EXTENSION_NATIVE_FORK"] = "1"
        env["WIZP_EXTENSION_CONFIGURATION_JSON"] = json.dumps(
            {
                "vue": {
                    "server": {"hybridMode": True, "includeLanguages": ["vue"]},
                },
                "typescript": {
                    "tsdk": "",
                },
            }
        )
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            process_result: dict = {}
            debug_state: dict = {}
            provider_result: dict = {}
            active_document: dict = {}
            activation_result: dict = {}
            activation_errors: dict = {}
            ui_events: list = []
            try:
                _wait_for_server(timeout=30.0)
                command_payload, discovered_commands = _wait_for_command_surface(set(_manifest_commands(manifest)), timeout=30.0)
                missing_commands = sorted(set(_manifest_commands(manifest)) - discovered_commands)
                if missing_commands:
                    raise AssertionError(f"Vue.volar command surface missing commands: {missing_commands[:10]}")
                character = source_text.index("message")
                active_document = _set_active_text_document(
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": VUE_LANGUAGE_RUNTIME["languageId"],
                        "content": source_text,
                        "line": 1,
                        "character": 12,
                    },
                    request_id=261,
                )
                try:
                    activation_result = _activate_by_event("language:vue", request_id=262, timeout=30.0)
                except Exception as exc:
                    activation_result = {"error": str(exc), "event": "language:vue"}

                deadline = time.time() + 25.0
                forked_processes: list[dict] = []
                while time.time() < deadline:
                    process_result = _rpc("extension/runtimeProcesses", request_id=263, timeout=10.0)
                    activation_errors = _activation_errors_payload(request_id=264)
                    ui_events.extend(_poll_extension_ui())
                    debug_state = _rpc(
                        "extension/debugState",
                        {
                            "configSection": "vue",
                            "configKeys": ["server.hybridMode", "server.includeLanguages"],
                            "inspect": True,
                        },
                        request_id=265,
                        timeout=10.0,
                    )
                    forked_processes = [
                        item
                        for item in process_result.get("forkedProcesses", [])
                        if isinstance(item, dict)
                    ] if isinstance(process_result, dict) else []
                    if any("language-server.js" in str(item.get("modulePath", "")) for item in forked_processes):
                        break
                    message_text = " ".join(str(event) for event in ui_events).lower()
                    if "restart the extension host to activate vue support" in message_text:
                        break
                    if isinstance(activation_errors, dict) and activation_errors.get("count"):
                        break
                    time.sleep(0.5)

                try:
                    provider_result = _rpc(
                        "extension/languageProviders",
                        {
                            "uri": source_path.resolve().as_uri(),
                            "languageId": VUE_LANGUAGE_RUNTIME["languageId"],
                            "text": source_text,
                            "line": 1,
                            "character": character,
                        },
                        request_id=266,
                        timeout=20.0,
                    )
                except Exception as exc:
                    provider_result = {"error": str(exc)}

                relevant_activation_errors = [
                    error
                    for error in (activation_errors.get("errors", []) if isinstance(activation_errors, dict) else [])
                    if str(error.get("id", "")).lower()
                    in {VUE_LANGUAGE_RUNTIME["extensionId"].lower(), "volar", install_path.name.lower()}
                    or "volar" in str(error).lower()
                    or "vue" in str(error).lower()
                ]
                volar_processes = [
                    item
                    for item in forked_processes
                    if "language-server.js" in str(item.get("modulePath", ""))
                    and "volar" in str(item.get("modulePath", "")).lower()
                ]
                if volar_processes and not relevant_activation_errors:
                    status = "vue-volar-language-server-runtime-verified"
                elif relevant_activation_errors:
                    status = "vue-volar-activation-bounded"
                elif "restart the extension host to activate vue support" in " ".join(str(event) for event in ui_events).lower():
                    status = "vue-volar-typescript-restart-bounded"
                else:
                    status = "vue-volar-runtime-bounded-no-server"
                return {
                    "port": port,
                    "extensionId": VUE_LANGUAGE_RUNTIME["extensionId"],
                    "version": package.get("version"),
                    "package": package,
                    "installDirName": install_path.name,
                    "languageId": VUE_LANGUAGE_RUNTIME["languageId"],
                    "sourceFile": str(source_path),
                    "activeDocument": active_document,
                    "commandCount": len(command_payload.get("commands", [])) if isinstance(command_payload, dict) else 0,
                    "activationResult": activation_result,
                    "runtimeProcesses": process_result,
                    "providerResult": provider_result,
                    "debugState": debug_state,
                    "uiEvents": ui_events[-12:],
                    "activationErrors": relevant_activation_errors,
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                    "status": status,
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "extensionId": VUE_LANGUAGE_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "status": "vue-volar-language-runtime-failed",
                    "blockedReason": str(exc),
                    "runtimeProcesses": process_result,
                    "providerResult": provider_result,
                    "debugState": debug_state,
                    "activeDocument": active_document,
                    "activationResult": activation_result,
                    "uiEvents": ui_events[-12:],
                    "activationErrors": activation_errors,
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def run_dart_code_degraded_runtime_smoke() -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "language-vsix"
    namespace, name = DART_CODE_DEGRADED_RUNTIME["extensionId"].split(".", 1)
    metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
    package = _package_record(DART_CODE_DEGRADED_RUNTIME["extensionId"], metadata, cache_dir)
    if package["status"] != "downloaded-and-manifest-verified":
        return {
            "extensionId": DART_CODE_DEGRADED_RUNTIME["extensionId"],
            "status": "dart-code-package-unavailable",
            "package": package,
        }

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-dart-code-runtime-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        (workspace / "pubspec.yaml").write_text(str(DART_CODE_DEGRADED_RUNTIME["pubspec"]), encoding="utf-8")
        (workspace / "analysis_options.yaml").write_text(str(DART_CODE_DEGRADED_RUNTIME["analysisOptions"]), encoding="utf-8")
        source_path = workspace / str(DART_CODE_DEGRADED_RUNTIME["file"])
        source_path.parent.mkdir(parents=True, exist_ok=True)
        source_text = str(DART_CODE_DEGRADED_RUNTIME["source"])
        source_path.write_text(source_text, encoding="utf-8")

        manifest = _vsix_manifest(Path(str(package["cachePath"])))
        install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_EXTENSION_CONFIGURATION_JSON"] = json.dumps(
            {
                "dart": {
                    "sdkPath": DART_CODE_DEGRADED_RUNTIME["missingDartSdk"],
                    "flutterSdkPath": DART_CODE_DEGRADED_RUNTIME["missingFlutterSdk"],
                    "sdkPaths": [],
                    "flutterSdkPaths": [],
                    "checkForSdkUpdates": False,
                    "allowAnalytics": False,
                    "openDevTools": "never",
                    "cliConsole": "debugConsole",
                    "showTodos": True,
                    "debugExternalPackageLibraries": False,
                    "debugSdkLibraries": False,
                    "analysisServerFolding": True,
                    "analysisServerLogFile": None,
                    "analysisExcludedFolders": [],
                }
            }
        )
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            process_result: dict = {}
            debug_state: dict = {}
            provider_result: dict = {}
            active_document: dict = {}
            activation_result: dict = {}
            activation_errors: dict = {}
            command_results: dict = {}
            dart_command_invocations: list = []
            ui_events: list = []
            try:
                _wait_for_server(timeout=30.0)
                command_payload, discovered_commands = _wait_for_command_surface(set(_manifest_commands(manifest)), timeout=45.0)
                missing_commands = sorted(set(_manifest_commands(manifest)) - discovered_commands)
                if missing_commands:
                    raise AssertionError(f"Dart-Code.dart-code command surface missing commands: {missing_commands[:10]}")
                active_document = _set_active_text_document(
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": DART_CODE_DEGRADED_RUNTIME["languageId"],
                        "content": source_text,
                        "line": 1,
                        "character": 8,
                    },
                    request_id=271,
                )
                try:
                    activation_result = _activate_by_event("workspaceContains:pubspec.yaml", request_id=272, timeout=25.0)
                except TimeoutError as exc:
                    activation_result = {"timeout": str(exc), "event": "workspaceContains:pubspec.yaml", "timeoutSeconds": 25}
                except Exception as exc:
                    activation_result = {"error": str(exc), "event": "workspaceContains:pubspec.yaml"}

                deadline = time.time() + 12.0
                while time.time() < deadline:
                    process_result = _rpc("extension/runtimeProcesses", request_id=273, timeout=10.0)
                    activation_errors = _activation_errors_payload(request_id=274)
                    ui_events.extend(_poll_extension_ui())
                    message_text = " ".join(str(event) for event in ui_events + [activation_errors, activation_result]).lower()
                    if "dart" in message_text or "flutter" in message_text:
                        break
                    time.sleep(0.5)

                debug_state = _rpc(
                    "extension/debugState",
                    {
                        "configSection": "dart",
                        "configKeys": [
                            "sdkPath",
                            "flutterSdkPath",
                            "sdkPaths",
                            "flutterSdkPaths",
                            "checkForSdkUpdates",
                            "allowAnalytics",
                            "openDevTools",
                            "analysisExcludedFolders",
                        ],
                        "inspect": True,
                    },
                    request_id=275,
                    timeout=10.0,
                )
                try:
                    provider_result = _rpc(
                        "extension/languageProviders",
                        {
                            "uri": source_path.resolve().as_uri(),
                            "languageId": DART_CODE_DEGRADED_RUNTIME["languageId"],
                            "text": source_text,
                            "line": 1,
                            "character": 8,
                        },
                        request_id=276,
                        timeout=15.0,
                    )
                except Exception as exc:
                    provider_result = {"error": str(exc)}

                for command in ("dart.restartAnalysisServer", "flutter.doctor"):
                    try:
                        dart_command_invocations.append(
                            _rpc(
                                "extension/execute",
                                {"command": command, "detached": True},
                                request_id=277 + len(dart_command_invocations),
                                timeout=10.0,
                            )
                        )
                    except Exception as exc:
                        dart_command_invocations.append({"command": command, "error": str(exc)})

                deadline = time.time() + 12.0
                while time.time() < deadline:
                    try:
                        command_results = _rpc("extension/commandResults", request_id=281, timeout=5.0)
                    except Exception as exc:
                        command_results = {"pollError": str(exc)}
                    try:
                        process_result = _rpc("extension/runtimeProcesses", request_id=282, timeout=5.0)
                    except Exception as exc:
                        process_result = {"pollError": str(exc)}
                    try:
                        activation_errors = _activation_errors_payload(request_id=283)
                    except Exception as exc:
                        activation_errors = {"pollError": str(exc)}
                    ui_events.extend(_poll_extension_ui())
                    command_text = json.dumps(command_results, sort_keys=True).lower() if isinstance(command_results, dict) else str(command_results).lower()
                    message_text = " ".join(str(event) for event in ui_events + [activation_errors, activation_result, command_text]).lower()
                    if "dart sdk" in message_text or "flutter sdk" in message_text or DART_CODE_DEGRADED_RUNTIME["missingDartSdk"].lower() in message_text:
                        break
                    time.sleep(0.5)

                spawned_processes = process_result.get("spawnedProcesses", []) if isinstance(process_result, dict) else []
                forked_processes = process_result.get("forkedProcesses", []) if isinstance(process_result, dict) else []
                real_dart_processes = [
                    item
                    for item in list(spawned_processes) + list(forked_processes)
                    if isinstance(item, dict)
                    and item.get("pid", 0)
                    and (
                        "dart" in str(item.get("command", "")).lower()
                        or "flutter" in str(item.get("command", "")).lower()
                        or "dart" in str(item.get("modulePath", "")).lower()
                        or "flutter" in str(item.get("modulePath", "")).lower()
                        or any("dart" in str(arg).lower() or "flutter" in str(arg).lower() for arg in item.get("args", []))
                    )
                ]
                if real_dart_processes:
                    raise AssertionError(f"Dart degraded smoke unexpectedly started Dart/Flutter process: {real_dart_processes}")

                command_result_text = json.dumps(command_results, sort_keys=True).lower() if isinstance(command_results, dict) else str(command_results).lower()
                message_text = " ".join(str(event) for event in ui_events + [activation_errors, activation_result, command_result_text]).lower()
                has_missing_sdk_ux = any(
                    marker in message_text
                    for marker in (
                        "dart sdk",
                        "flutter sdk",
                        "could not find dart",
                        "unable to find dart",
                        "sdk is not available",
                        "sdk was not found",
                        DART_CODE_DEGRADED_RUNTIME["missingDartSdk"].lower(),
                        DART_CODE_DEGRADED_RUNTIME["missingFlutterSdk"].lower(),
                    )
                )
                relevant_activation_errors = [
                    error
                    for error in (activation_errors.get("errors", []) if isinstance(activation_errors, dict) else [])
                    if "dart" in str(error).lower()
                    or "flutter" in str(error).lower()
                    or str(error.get("id", "")).lower() in {DART_CODE_DEGRADED_RUNTIME["extensionId"].lower(), install_path.name.lower()}
                ]
                if has_missing_sdk_ux and not relevant_activation_errors:
                    status = "dart-code-missing-sdk-degraded-verified"
                elif has_missing_sdk_ux:
                    status = "dart-code-missing-sdk-bounded"
                else:
                    status = "dart-code-runtime-bounded-no-sdk-ux"
                return {
                    "port": port,
                    "extensionId": DART_CODE_DEGRADED_RUNTIME["extensionId"],
                    "version": package.get("version"),
                    "package": package,
                    "installDirName": install_path.name,
                    "languageId": DART_CODE_DEGRADED_RUNTIME["languageId"],
                    "sourceFile": str(source_path),
                    "missingDartSdk": DART_CODE_DEGRADED_RUNTIME["missingDartSdk"],
                    "missingFlutterSdk": DART_CODE_DEGRADED_RUNTIME["missingFlutterSdk"],
                    "activeDocument": active_document,
                    "commandCount": len(command_payload.get("commands", [])) if isinstance(command_payload, dict) else 0,
                    "activationResult": activation_result,
                    "commandInvocations": dart_command_invocations,
                    "commandResults": command_results,
                    "runtimeProcesses": process_result,
                    "providerResult": provider_result,
                    "debugState": debug_state,
                    "uiEvents": ui_events[-12:],
                    "activationErrors": relevant_activation_errors,
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                    "status": status,
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "extensionId": DART_CODE_DEGRADED_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "status": "dart-code-degraded-runtime-failed",
                    "blockedReason": str(exc),
                    "runtimeProcesses": process_result,
                    "providerResult": provider_result,
                    "debugState": debug_state,
                    "activeDocument": active_document,
                    "activationResult": activation_result,
                    "commandInvocations": dart_command_invocations,
                    "commandResults": command_results,
                    "uiEvents": ui_events[-12:],
                    "activationErrors": activation_errors,
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def _dart_code_valid_sdk_paths() -> tuple[Path | None, Path | None]:
    flutter_candidates: list[Path] = []
    dart_candidates: list[Path] = []
    for value in (
        os.environ.get("WIZP_DART_CODE_VALID_FLUTTER_SDK"),
        os.environ.get("FLUTTER_ROOT"),
        "/home/lich/flutter",
    ):
        if value:
            flutter_candidates.append(Path(value))
    flutter_bin = shutil.which("flutter")
    if flutter_bin:
        flutter_candidates.append(Path(flutter_bin).resolve().parents[1])
    for flutter_candidate in flutter_candidates:
        dart_candidates.append(flutter_candidate / "bin" / "cache" / "dart-sdk")
    for value in (
        os.environ.get("WIZP_DART_CODE_VALID_DART_SDK"),
        os.environ.get("DART_SDK"),
    ):
        if value:
            dart_candidates.insert(0, Path(value))
    dart_bin = shutil.which("dart")
    if dart_bin:
        dart_candidates.append(Path(dart_bin).resolve().parents[1])

    dart_sdk: Path | None = None
    seen_dart: set[str] = set()
    for candidate in dart_candidates:
        key = str(candidate)
        if key in seen_dart:
            continue
        seen_dart.add(key)
        if (candidate / "bin" / "dart").exists():
            dart_sdk = candidate
            break
    if not dart_sdk:
        return None, None

    flutter_sdk: Path | None = None
    seen_flutter: set[str] = set()
    for candidate in flutter_candidates:
        key = str(candidate)
        if key in seen_flutter:
            continue
        seen_flutter.add(key)
        if (candidate / "bin" / "flutter").exists():
            flutter_sdk = candidate
            break
    if not flutter_sdk:
        inferred = dart_sdk.parent.parent.parent
        if (inferred / "bin" / "flutter").exists():
            flutter_sdk = inferred
    return dart_sdk, flutter_sdk


def _dart_like_runtime_processes(process_result: dict) -> list[dict]:
    spawned_processes = process_result.get("spawnedProcesses", []) if isinstance(process_result, dict) else []
    forked_processes = process_result.get("forkedProcesses", []) if isinstance(process_result, dict) else []
    result: list[dict] = []
    for item in list(spawned_processes) + list(forked_processes):
        if not isinstance(item, dict):
            continue
        text = " ".join(
            [str(item.get("command", "")), str(item.get("modulePath", ""))]
            + [str(arg) for arg in item.get("args", [])]
        ).lower()
        if "dart" in text or "flutter" in text:
            result.append(item)
    return result


def run_dart_code_valid_sdk_analysis_server_smoke() -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    dart_sdk, flutter_sdk = _dart_code_valid_sdk_paths()
    if not dart_sdk:
        return {
            "extensionId": DART_CODE_DEGRADED_RUNTIME["extensionId"],
            "status": "dart-code-valid-sdk-skipped-no-sdk",
            "blockedReason": "No local Dart SDK with bin/dart was found for the valid-SDK analysis-server probe.",
        }
    cache_dir = PROJECT_ROOT / "build" / "parity-real-extensions" / "language-vsix"
    namespace, name = DART_CODE_DEGRADED_RUNTIME["extensionId"].split(".", 1)
    metadata = _fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
    package = _package_record(DART_CODE_DEGRADED_RUNTIME["extensionId"], metadata, cache_dir)
    if package["status"] != "downloaded-and-manifest-verified":
        return {
            "extensionId": DART_CODE_DEGRADED_RUNTIME["extensionId"],
            "status": "dart-code-valid-sdk-package-unavailable",
            "package": package,
        }

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-dart-code-valid-sdk-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        logs = root / "logs"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        logs.mkdir()
        (workspace / "pubspec.yaml").write_text(str(DART_CODE_DEGRADED_RUNTIME["pubspec"]), encoding="utf-8")
        (workspace / "analysis_options.yaml").write_text(str(DART_CODE_DEGRADED_RUNTIME["analysisOptions"]), encoding="utf-8")
        source_path = workspace / str(DART_CODE_DEGRADED_RUNTIME["file"])
        source_path.parent.mkdir(parents=True, exist_ok=True)
        source_text = str(DART_CODE_DEGRADED_RUNTIME["source"])
        source_path.write_text(source_text, encoding="utf-8")

        manifest = _vsix_manifest(Path(str(package["cachePath"])))
        install_path = _install_vsix(Path(str(package["cachePath"])), ext_root, manifest)

        analysis_log = logs / "analysis-server.log"
        extension_log = logs / "extension.log"
        dart_config: dict = {
            "sdkPath": str(dart_sdk),
            "sdkPaths": [str(dart_sdk)],
            "checkForSdkUpdates": False,
            "allowAnalytics": False,
            "openDevTools": "never",
            "analyzerLogFile": str(analysis_log),
            "analysisServerLogFile": str(analysis_log),
            "extensionLogFile": str(extension_log),
            "disableAutomaticPub": True,
            "disableDartToolingDaemon": True,
        }
        if flutter_sdk:
            dart_config["flutterSdkPath"] = str(flutter_sdk)
            dart_config["flutterSdkPaths"] = [str(flutter_sdk)]

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        env["WIZP_DEFER_STARTUP_EXTENSIONS"] = "1"
        env["WIZP_EXTENSION_ACTIVATION_TIMEOUT_MS"] = "45000"
        env["DART_CODE_IS_TEST_RUN"] = "true"
        env["DC_TEST_LOGS"] = str(logs)
        if flutter_sdk:
            env["FLUTTER_ROOT"] = str(flutter_sdk)
            env["PATH"] = str(dart_sdk / "bin") + os.pathsep + str(flutter_sdk / "bin") + os.pathsep + env.get("PATH", "")
        else:
            env["PATH"] = str(dart_sdk / "bin") + os.pathsep + env.get("PATH", "")
        env["WIZP_EXTENSION_CONFIGURATION_JSON"] = json.dumps({"dart": dart_config})

        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
                start_new_session=True,
            )
            active_document: dict = {}
            activation_result: dict = {}
            activation_errors: dict = {}
            command_payload: dict = {}
            process_result: dict = {}
            provider_result: dict = {}
            provider_repeat_results: list = []
            debug_state: dict = {}
            ui_events: list = []
            saw_language_server = False
            try:
                _wait_for_server(timeout=30.0)
                command_payload, discovered_commands = _wait_for_command_surface(set(_manifest_commands(manifest)), timeout=45.0)
                missing_commands = sorted(set(_manifest_commands(manifest)) - discovered_commands)
                if missing_commands:
                    raise AssertionError(f"Dart-Code.dart-code valid-SDK command surface missing commands: {missing_commands[:10]}")
                active_document = _set_active_text_document(
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": DART_CODE_DEGRADED_RUNTIME["languageId"],
                        "content": source_text,
                        "line": 1,
                        "character": 8,
                    },
                    request_id=311,
                    timeout=10.0,
                )

                activation_requested = False
                deadline = time.time() + 45.0
                while time.time() < deadline:
                    try:
                        process_result = _rpc("extension/runtimeProcesses", request_id=312, timeout=8.0)
                    except Exception as exc:
                        process_result = {"pollError": str(exc)}
                    try:
                        activation_errors = _activation_errors_payload(request_id=313)
                    except Exception as exc:
                        activation_errors = {"pollError": str(exc)}
                    try:
                        debug_state = _rpc(
                            "extension/debugState",
                            {
                                "configSection": "dart",
                                "configKeys": [
                                    "sdkPath",
                                    "flutterSdkPath",
                                    "sdkPaths",
                                    "flutterSdkPaths",
                                    "checkForSdkUpdates",
                                    "allowAnalytics",
                                    "openDevTools",
                                    "disableDartToolingDaemon",
                                ],
                                "inspect": True,
                            },
                            request_id=314,
                            timeout=8.0,
                        )
                    except Exception as exc:
                        debug_state = {"pollError": str(exc)}
                    ui_events.extend(_poll_extension_ui())
                    dart_like_processes = _dart_like_runtime_processes(process_result)
                    saw_language_server = any(
                        "language-server" in " ".join(str(arg) for arg in item.get("args", [])).lower()
                        for item in dart_like_processes
                    )
                    provider_counts = debug_state.get("providerCounts", {}) if isinstance(debug_state, dict) else {}
                    if saw_language_server and provider_counts.get("completions", 0) >= 1 and provider_counts.get("diagnostics", 0) >= 1:
                        break
                    if not activation_requested and time.time() > deadline - 35.0 and not dart_like_processes:
                        activation_requested = True
                        try:
                            activation_result = _activate_by_event("workspaceContains:pubspec.yaml", request_id=315, timeout=20.0)
                        except Exception as exc:
                            activation_result = {"error": str(exc), "event": "workspaceContains:pubspec.yaml"}
                    time.sleep(0.75)

                try:
                    provider_result = _rpc(
                        "extension/languageProviders",
                        {
                            "uri": source_path.resolve().as_uri(),
                            "languageId": DART_CODE_DEGRADED_RUNTIME["languageId"],
                            "text": source_text,
                            "line": 1,
                            "character": 8,
                        },
                        request_id=316,
                        timeout=20.0,
                    )
                except Exception as exc:
                    provider_result = {"pollError": str(exc)}
                for repeat_index in range(3):
                    try:
                        repeat_result = _rpc(
                            "extension/languageProviders",
                            {
                                "uri": source_path.resolve().as_uri(),
                                "languageId": DART_CODE_DEGRADED_RUNTIME["languageId"],
                                "text": source_text,
                                "line": 1,
                                "character": 8,
                            },
                            request_id=319 + repeat_index,
                            timeout=20.0,
                        )
                        provider_repeat_results.append(
                            {
                                "completionItemCount": len(repeat_result.get("completion", {}).get("items", []))
                                if isinstance(repeat_result, dict)
                                else 0,
                                "providerResolution": repeat_result.get("providerResolution", {})
                                if isinstance(repeat_result, dict)
                                else {},
                            }
                        )
                    except Exception as exc:
                        provider_repeat_results.append({"pollError": str(exc)})
                try:
                    process_result = _rpc("extension/runtimeProcesses", request_id=317, timeout=8.0)
                except Exception as exc:
                    process_result = {"pollError": str(exc)}
                try:
                    activation_errors = _activation_errors_payload(request_id=318)
                except Exception as exc:
                    activation_errors = {"pollError": str(exc)}

                relevant_activation_errors = []
                for error in activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []:
                    error_text = str(error).lower()
                    error_id = str(error.get("id", "")).lower() if isinstance(error, dict) else ""
                    if (
                        "dart" in error_text
                        or "flutter" in error_text
                        or error_id in {DART_CODE_DEGRADED_RUNTIME["extensionId"].lower(), install_path.name.lower()}
                    ):
                        relevant_activation_errors.append(error)
                dart_like_processes = _dart_like_runtime_processes(process_result)
                saw_language_server = any(
                    "language-server" in " ".join(str(arg) for arg in item.get("args", [])).lower()
                    for item in dart_like_processes
                )
                language_server_process_count = sum(
                    1
                    for item in dart_like_processes
                    if "language-server" in " ".join(str(arg) for arg in item.get("args", [])).lower()
                )
                dart_runtime_bounded = language_server_process_count == 1 and len(dart_like_processes) <= 2
                provider_counts = debug_state.get("providerCounts", {}) if isinstance(debug_state, dict) else {}
                if (
                    saw_language_server
                    and dart_runtime_bounded
                    and not relevant_activation_errors
                    and provider_counts.get("completions", 0) >= 1
                    and provider_counts.get("diagnostics", 0) >= 1
                ):
                    status = "dart-code-valid-sdk-analysis-server-runtime-verified"
                elif saw_language_server and dart_runtime_bounded and not relevant_activation_errors:
                    status = "dart-code-valid-sdk-analysis-server-started"
                elif saw_language_server and not relevant_activation_errors:
                    status = "dart-code-valid-sdk-analysis-server-unbounded"
                else:
                    status = "dart-code-valid-sdk-analysis-server-unverified"
                return {
                    "port": port,
                    "extensionId": DART_CODE_DEGRADED_RUNTIME["extensionId"],
                    "version": package.get("version"),
                    "package": package,
                    "installDirName": install_path.name,
                    "dartSdk": str(dart_sdk),
                    "flutterSdk": str(flutter_sdk) if flutter_sdk else None,
                    "languageId": DART_CODE_DEGRADED_RUNTIME["languageId"],
                    "sourceFile": str(source_path),
                    "activeDocument": active_document,
                    "commandCount": len(command_payload.get("commands", [])) if isinstance(command_payload, dict) else 0,
                    "activationResult": activation_result,
                    "runtimeProcesses": process_result,
                    "dartLikeProcesses": dart_like_processes[:5],
                    "languageServerProcessCount": language_server_process_count,
                    "dartRuntimeBounded": dart_runtime_bounded,
                    "providerResult": provider_result,
                    "providerRepeatResults": provider_repeat_results,
                    "debugState": debug_state,
                    "uiEvents": ui_events[-12:],
                    "activationErrors": relevant_activation_errors,
                    "analysisLogTail": analysis_log.read_text(encoding="utf-8", errors="replace")[-3000:] if analysis_log.exists() else None,
                    "extensionLogTail": extension_log.read_text(encoding="utf-8", errors="replace")[-3000:] if extension_log.exists() else None,
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                    "status": status,
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                return {
                    "port": port,
                    "extensionId": DART_CODE_DEGRADED_RUNTIME["extensionId"],
                    "installDirName": install_path.name,
                    "dartSdk": str(dart_sdk),
                    "flutterSdk": str(flutter_sdk) if flutter_sdk else None,
                    "status": "dart-code-valid-sdk-analysis-server-probe-failed",
                    "blockedReason": str(exc),
                    "activeDocument": active_document,
                    "activationResult": activation_result,
                    "runtimeProcesses": process_result,
                    "providerResult": provider_result,
                    "providerRepeatResults": provider_repeat_results,
                    "debugState": debug_state,
                    "uiEvents": ui_events[-12:],
                    "activationErrors": activation_errors,
                    "analysisLogTail": analysis_log.read_text(encoding="utf-8", errors="replace")[-3000:] if analysis_log.exists() else None,
                    "extensionLogTail": extension_log.read_text(encoding="utf-8", errors="replace")[-3000:] if extension_log.exists() else None,
                    "stdoutTail": stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:],
                    "stderrTail": stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:],
                }
            finally:
                if proc.poll() is None:
                    try:
                        os.killpg(proc.pid, signal.SIGTERM)
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(proc.pid, signal.SIGKILL)
                        proc.wait(timeout=5)
                    except ProcessLookupError:
                        pass


def run_runtime_auto_close_tag_smoke(packages: list[dict]) -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    target = next((package for package in packages if package["id"] == RUNTIME_AUTO_CLOSE_TAG["extensionId"]), None)
    if not target:
        raise AssertionError(f"auto-close-tag extension missing from package set: {RUNTIME_AUTO_CLOSE_TAG['extensionId']}")

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-real-extension-auto-close-tag-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        source_path = workspace / str(RUNTIME_AUTO_CLOSE_TAG["file"])
        source_text = "<section><article>"
        source_path.write_text(source_text, encoding="utf-8")

        manifest = _vsix_manifest(Path(str(target["cachePath"])))
        install_path = _install_vsix(Path(str(target["cachePath"])), ext_root, manifest)

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            try:
                _wait_for_server(required_commands={RUNTIME_AUTO_CLOSE_TAG["command"]}, timeout=20.0)
                opened = _rpc(
                    "extension/activeTextDocument",
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": RUNTIME_AUTO_CLOSE_TAG["languageId"],
                        "content": source_text,
                        "line": 0,
                        "character": len(source_text),
                    },
                    request_id=81,
                )
                execute_result = _rpc(
                    "extension/execute",
                    {"command": RUNTIME_AUTO_CLOSE_TAG["command"], "timeoutMs": 5000},
                    request_id=82,
                    timeout=8.0,
                )
                edited = _rpc(
                    "extension/activeTextDocument",
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": RUNTIME_AUTO_CLOSE_TAG["languageId"],
                    },
                    request_id=83,
                )
                activation_errors = _rpc("extension/activationErrors", request_id=84)
                activation_error_items = (
                    activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []
                )
                if activation_error_items:
                    raise AssertionError(f"auto-close-tag activation error(s): {activation_error_items}")
                edited_text = edited.get("text", "") if isinstance(edited, dict) else ""
                if edited_text != source_text + "</article>":
                    raise AssertionError(
                        f"auto-close-tag did not insert expected close tag: opened={opened!r}; "
                        f"execute={execute_result!r}; edited={edited!r}"
                    )
                return {
                    "port": port,
                    "extensionId": RUNTIME_AUTO_CLOSE_TAG["extensionId"],
                    "installDirName": install_path.name,
                    "command": RUNTIME_AUTO_CLOSE_TAG["command"],
                    "languageId": RUNTIME_AUTO_CLOSE_TAG["languageId"],
                    "sourceFile": str(source_path),
                    "before": source_text,
                    "after": edited_text,
                    "activationErrors": activation_error_items,
                    "status": "real-editor-command-text-edit-verified",
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                proc_code = proc.poll()
                stdout_tail = stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:]
                stderr_tail = stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:]
                raise AssertionError(
                    "real extension auto-close-tag runtime smoke failed: "
                    f"{exc}; procExit={proc_code}; stdoutTail={stdout_tail!r}; stderrTail={stderr_tail!r}"
                ) from exc
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def run_runtime_color_highlight_smoke(packages: list[dict]) -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    target = next((package for package in packages if package["id"] == RUNTIME_COLOR_HIGHLIGHT["extensionId"]), None)
    if not target:
        raise AssertionError(f"color-highlight extension missing from package set: {RUNTIME_COLOR_HIGHLIGHT['extensionId']}")

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-real-extension-color-highlight-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        source_path = workspace / str(RUNTIME_COLOR_HIGHLIGHT["file"])
        source_text = 'const primary = "#ff0000"; const accent = "rgb(0, 255, 0)";\n'
        source_path.write_text(source_text, encoding="utf-8")

        manifest = _vsix_manifest(Path(str(target["cachePath"])))
        install_path = _install_vsix(Path(str(target["cachePath"])), ext_root, manifest)

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            try:
                _wait_for_server(required_commands={RUNTIME_COLOR_HIGHLIGHT["command"]}, timeout=20.0)
                _rpc("extension/activateByEvent", {"event": "startup"}, request_id=90)
                time.sleep(0.5)
                _rpc(
                    "extension/activeTextDocument",
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": RUNTIME_COLOR_HIGHLIGHT["languageId"],
                        "content": source_text,
                        "line": 0,
                        "character": source_text.index("#ff0000"),
                    },
                    request_id=91,
                )
                _rpc(
                    "extension/execute",
                    {"command": RUNTIME_COLOR_HIGHLIGHT["command"], "timeoutMs": 5000},
                    request_id=92,
                    timeout=8.0,
                )
                decorations = None
                deadline = time.time() + 6.0
                while time.time() < deadline:
                    decorations = _rpc("extension/decorations", request_id=93, timeout=5.0)
                    editor_entries = decorations.get("editors", []) if isinstance(decorations, dict) else []
                    if any(
                        decoration.get("ranges")
                        for editor in editor_entries
                        if isinstance(editor, dict) and editor.get("uri") == source_path.resolve().as_uri()
                        for decoration in editor.get("decorations", [])
                        if isinstance(decoration, dict)
                    ):
                        break
                    time.sleep(0.2)
                activation_errors = _rpc("extension/activationErrors", request_id=94)
                activation_error_items = (
                    activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []
                )
                if activation_error_items:
                    raise AssertionError(f"color-highlight activation error(s): {activation_error_items}")
                editor_entries = decorations.get("editors", []) if isinstance(decorations, dict) else []
                matching = [
                    decoration
                    for editor in editor_entries
                    if isinstance(editor, dict) and editor.get("uri") == source_path.resolve().as_uri()
                    for decoration in editor.get("decorations", [])
                    if isinstance(decoration, dict) and decoration.get("ranges")
                ]
                total_ranges = sum(len(decoration.get("ranges", [])) for decoration in matching)
                if total_ranges < 2:
                    raise AssertionError(f"color-highlight did not publish expected decoration ranges: {decorations!r}")
                return {
                    "port": port,
                    "extensionId": RUNTIME_COLOR_HIGHLIGHT["extensionId"],
                    "installDirName": install_path.name,
                    "command": RUNTIME_COLOR_HIGHLIGHT["command"],
                    "languageId": RUNTIME_COLOR_HIGHLIGHT["languageId"],
                    "sourceFile": str(source_path),
                    "decorationTypes": len(decorations.get("types", [])) if isinstance(decorations, dict) else 0,
                    "decoratedRanges": total_ranges,
                    "activationErrors": activation_error_items,
                    "status": "real-decoration-command-verified",
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                proc_code = proc.poll()
                stdout_tail = stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:]
                stderr_tail = stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:]
                raise AssertionError(
                    "real extension color-highlight runtime smoke failed: "
                    f"{exc}; procExit={proc_code}; stdoutTail={stdout_tail!r}; stderrTail={stderr_tail!r}"
                ) from exc
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def _stderr_js_errors(stderr_path: Path) -> list[str]:
    text = stderr_path.read_text(encoding="utf-8", errors="replace")
    result: list[str] = []
    for line in text.splitlines():
        marker = "WIZP ExtHost: JS error:"
        if marker in line:
            result.append(line.split(marker, 1)[1].strip())
    return result[-10:]


def run_cspell_runtime_probe(packages: list[dict]) -> dict:
    if not BIN.exists():
        raise AssertionError(f"missing WIZP binary: {BIN}; run npm run build first")
    target = next((package for package in packages if package["id"] == CSPELL_RUNTIME_PROBE["extensionId"]), None)
    if not target:
        raise AssertionError(f"cSpell extension missing from package set: {CSPELL_RUNTIME_PROBE['extensionId']}")

    global RPC_URL
    port = _free_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    with tempfile.TemporaryDirectory(prefix="wizp-real-extension-cspell-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        source_path = workspace / "spell.txt"
        source_path.write_text("mispelled wurd\n", encoding="utf-8")

        manifest = _vsix_manifest(Path(str(target["cachePath"])))
        install_path = _install_vsix(Path(str(target["cachePath"])), ext_root, manifest)

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        env["WIZP_NO_BROWSER"] = "1"
        env["WIZP_WEBVIEW"] = "false"
        stdout_path = root / "wizp.stdout.log"
        stderr_path = root / "wizp.stderr.log"
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            proc = subprocess.Popen(
                [str(BIN)],
                cwd=str(workspace),
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            try:
                _wait_for_server(required_commands=set(CSPELL_RUNTIME_PROBE["commands"]), timeout=30.0)
                time.sleep(2.0)
                active_document = _rpc(
                    "extension/activeTextDocument",
                    {
                        "uri": source_path.resolve().as_uri(),
                        "languageId": "plaintext",
                        "content": source_path.read_text(encoding="utf-8"),
                    },
                    request_id=49,
                    timeout=5.0,
                )
                api_probe = _rpc("extension/cspellRuntimeProbe", request_id=50, timeout=8.0)
                command_results: dict[str, object] = {}
                ui_events: list = []
                command_errors: dict[str, str] = {}
                for index, command in enumerate(CSPELL_RUNTIME_PROBE["commands"], start=1):
                    try:
                        command_results[command] = _rpc(
                            "extension/execute",
                            {"command": command, "timeoutMs": 5000},
                            request_id=50 + index,
                            timeout=8.0,
                        )
                    except Exception as exc:
                        command_errors[command] = str(exc)
                        break
                    time.sleep(0.5)
                    ui_events.extend(_poll_extension_ui())
                try:
                    diagnostics = _rpc("extension/diagnostics", request_id=60, timeout=5.0)
                except Exception as exc:
                    diagnostics = {"pollError": str(exc), "collections": []}
                try:
                    activation_errors = _rpc("extension/activationErrors", request_id=61, timeout=5.0)
                except Exception as exc:
                    activation_errors = {"errors": [], "pollError": str(exc)}
                activation_error_items = (
                    activation_errors.get("errors", []) if isinstance(activation_errors, dict) else []
                )
                stderr.flush()
                js_errors = _stderr_js_errors(stderr_path)
                return {
                    "port": port,
                    "extensionId": CSPELL_RUNTIME_PROBE["extensionId"],
                    "installDirName": install_path.name,
                    "sourceFile": str(source_path),
                    "activeDocument": active_document,
                    "commands": list(CSPELL_RUNTIME_PROBE["commands"]),
                    "commandResults": command_results,
                    "commandErrors": command_errors,
                    "apiProbe": api_probe,
                    "uiEventCount": len(ui_events),
                    "diagnosticCollections": len(diagnostics.get("collections", [])) if isinstance(diagnostics, dict) else 0,
                    "activationErrors": activation_error_items,
                    "stderrJsErrors": js_errors,
                    "status": "cspell-client-api-verified"
                    if isinstance(api_probe, dict) and api_probe.get("status") == "cspell-client-api-verified"
                    else "runtime-command-effects-not-yet-verified",
                    "blockedReason": None
                    if isinstance(api_probe, dict) and api_probe.get("status") == "cspell-client-api-verified"
                    else "commands are discoverable, but runtime command execution can time out or produce no WIZP-visible UI/diagnostics; deeper spelling-server/client behavior still needs deterministic runtime coverage",
                }
            except Exception as exc:
                stdout.flush()
                stderr.flush()
                proc_code = proc.poll()
                stdout_tail = stdout_path.read_text(encoding="utf-8", errors="replace")[-2000:]
                stderr_tail = stderr_path.read_text(encoding="utf-8", errors="replace")[-4000:]
                raise AssertionError(
                    "real extension cSpell runtime probe failed: "
                    f"{exc}; procExit={proc_code}; stdoutTail={stdout_tail!r}; stderrTail={stderr_tail!r}"
                ) from exc
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=5)


def main() -> int:
    text = LEDGER.read_text(encoding="utf-8")
    missing = sorted(item for item in CURATED if item not in text)
    if missing:
        raise AssertionError(f"curated extension(s) missing from ledger: {missing}")
    tiers = TIERS.read_text(encoding="utf-8")
    if "Unknown" not in text or "Unsupported" not in text:
        raise AssertionError("ledger is missing current evaluated tiers")
    if "Verified" not in tiers or "Compatible" not in tiers or "Shimmed" not in tiers:
        raise AssertionError("compatibility tier vocabulary missing from tier definition")
    workflow = WORKFLOW.read_text(encoding="utf-8")
    if "real-extension-smoke" not in workflow or "parity_real_extension_smoke.py" not in workflow:
        raise AssertionError("real extension CI workflow entry is missing")
    existing_report: dict[str, object] = {}
    if REPORT.exists():
        try:
            loaded = json.loads(REPORT.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                existing_report = loaded
        except json.JSONDecodeError:
            existing_report = {}

    payload = {
        "curated": sorted(CURATED),
        "networkMode": os.environ.get("WIZP_REAL_EXTENSION_NETWORK") == "1",
        "loadabilityMode": os.environ.get("WIZP_REAL_EXTENSION_LOAD") == "1",
        "runtimeMode": os.environ.get("WIZP_REAL_EXTENSION_RUNTIME") == "1",
        "topOpenVSXMode": os.environ.get("WIZP_OPENVSX_TOP_LOAD") == "1",
        "topOpenVSXLimit": int(os.environ.get("WIZP_OPENVSX_TOP_LIMIT", str(existing_report.get("topOpenVSXLimit", 20)))),
        "topOpenVSXThemeIconMode": os.environ.get("WIZP_OPENVSX_THEME_ICON") == "1",
        "topOpenVSXThemeIconLimit": int(os.environ.get("WIZP_OPENVSX_THEME_ICON_LIMIT", str(existing_report.get("topOpenVSXThemeIconLimit", 20)))),
        "topOpenVSXLaneBaselineMode": os.environ.get("WIZP_OPENVSX_LANE_BASELINE") == "1",
        "topOpenVSXLaneBaselinePerLaneLimit": int(os.environ.get("WIZP_OPENVSX_LANE_BASELINE_LIMIT", str(existing_report.get("topOpenVSXLaneBaselinePerLaneLimit", 3)))),
        "topOpenVSXExtensionPacksMode": os.environ.get("WIZP_OPENVSX_EXTENSION_PACKS") == "1",
        "topOpenVSXExtensionPacksLimit": int(os.environ.get("WIZP_OPENVSX_EXTENSION_PACKS_LIMIT", str(existing_report.get("topOpenVSXExtensionPacksLimit", 5)))),
        "topOpenVSXFormatterRuntimeMode": os.environ.get("WIZP_OPENVSX_FORMATTER_RUNTIME") == "1",
        "topOpenVSXLanguageRuntimeMode": os.environ.get("WIZP_OPENVSX_LANGUAGE_RUNTIME") == "1",
        "topOpenVSXTop20RuntimeMode": os.environ.get("WIZP_OPENVSX_TOP20_RUNTIME") == "1",
        "officialCodexMode": os.environ.get("WIZP_OPENVSX_CODEX") == "1",
        "status": "runner-contract-verified",
        "packages": [],
        "topOpenVSXLoadability": None,
        "topOpenVSXThemeIcon": None,
        "topOpenVSXLaneBaseline": None,
        "topOpenVSXExtensionPacks": None,
        "topOpenVSXFormatterRuntime": None,
        "topOpenVSXLanguageRuntime": None,
        "topOpenVSXTop20Runtime": None,
        "officialCodex": None,
        "loadability": None,
        "runtimeCommand": None,
        "runtimeProvider": None,
        "runtimeNpmProvider": None,
        "runtimeAutoCloseTag": None,
        "runtimeColorHighlight": None,
        "cspellRuntimeProbe": None,
    }
    for field in PRESERVED_REPORT_FIELDS:
        if field in existing_report and existing_report[field] is not None:
            payload[field] = existing_report[field]

    # Preserve prior sections for reporting continuity, but keep the current run
    # scope driven only by explicit env flags so targeted reruns stay targeted.
    if payload["networkMode"]:
        payload["packages"] = run_network_package_smoke()
        payload["status"] = "real-packages-downloaded-and-manifest-verified"
    if payload["topOpenVSXMode"]:
        if not payload["networkMode"]:
            raise AssertionError("WIZP_OPENVSX_TOP_LOAD=1 requires WIZP_REAL_EXTENSION_NETWORK=1")
        if payload["topOpenVSXLimit"] < 1 or payload["topOpenVSXLimit"] > 100:
            raise AssertionError("WIZP_OPENVSX_TOP_LIMIT must be between 1 and 100")
        payload["topOpenVSXLoadability"] = run_top_openvsx_package_smoke(payload["topOpenVSXLimit"])
        payload["status"] = "top-openvsx-loadability-recorded"
    if payload["topOpenVSXThemeIconMode"]:
        if not payload["networkMode"]:
            raise AssertionError("WIZP_OPENVSX_THEME_ICON=1 requires WIZP_REAL_EXTENSION_NETWORK=1")
        if payload["topOpenVSXThemeIconLimit"] < 1 or payload["topOpenVSXThemeIconLimit"] > 100:
            raise AssertionError("WIZP_OPENVSX_THEME_ICON_LIMIT must be between 1 and 100")
        payload["topOpenVSXThemeIcon"] = run_top_openvsx_theme_icon_smoke(payload["topOpenVSXThemeIconLimit"])
        payload["status"] = "top-openvsx-theme-icon-recorded"
    if payload["topOpenVSXLaneBaselineMode"]:
        if not payload["networkMode"]:
            raise AssertionError("WIZP_OPENVSX_LANE_BASELINE=1 requires WIZP_REAL_EXTENSION_NETWORK=1")
        if payload["topOpenVSXLaneBaselinePerLaneLimit"] < 1 or payload["topOpenVSXLaneBaselinePerLaneLimit"] > 10:
            raise AssertionError("WIZP_OPENVSX_LANE_BASELINE_LIMIT must be between 1 and 10")
        payload["topOpenVSXLaneBaseline"] = run_top_openvsx_lane_baseline_smoke(payload["topOpenVSXLaneBaselinePerLaneLimit"])
        payload["status"] = "top-openvsx-lane-baseline-recorded"
    if payload["topOpenVSXExtensionPacksMode"]:
        if not payload["networkMode"]:
            raise AssertionError("WIZP_OPENVSX_EXTENSION_PACKS=1 requires WIZP_REAL_EXTENSION_NETWORK=1")
        if payload["topOpenVSXExtensionPacksLimit"] < 1 or payload["topOpenVSXExtensionPacksLimit"] > 10:
            raise AssertionError("WIZP_OPENVSX_EXTENSION_PACKS_LIMIT must be between 1 and 10")
        payload["topOpenVSXExtensionPacks"] = run_top_openvsx_extension_pack_smoke(payload["topOpenVSXExtensionPacksLimit"])
        payload["status"] = "top-openvsx-extension-packs-recorded"
    if payload["topOpenVSXFormatterRuntimeMode"]:
        if not payload["networkMode"]:
            raise AssertionError("WIZP_OPENVSX_FORMATTER_RUNTIME=1 requires WIZP_REAL_EXTENSION_NETWORK=1")
        prettier_runtime = run_prettier_formatter_runtime_smoke()
        ruff_runtime = run_ruff_formatter_linter_runtime_smoke()
        ruff_external_runtime = run_ruff_external_binary_discovery_smoke()
        eslint_runtime = run_eslint_formatter_linter_runtime_smoke()
        intelephense_runtime = run_intelephense_php_diagnostics_lifecycle_smoke()
        payload["topOpenVSXFormatterRuntime"] = {
            "prettier": prettier_runtime,
            "ruff": ruff_runtime,
            "ruffExternalBinary": ruff_external_runtime,
            "eslint": eslint_runtime,
            "intelephense": intelephense_runtime,
            "status": "top-openvsx-formatter-runtime-verified"
            if prettier_runtime.get("status") == "prettier-document-formatting-runtime-verified"
            and ruff_runtime.get("status") == "ruff-formatter-linter-runtime-verified"
            and ruff_external_runtime.get("status") == "ruff-external-binary-discovery-verified"
            and eslint_runtime.get("status") == "eslint-formatter-linter-runtime-verified"
            and intelephense_runtime.get("status") == "intelephense-php-diagnostics-lifecycle-verified"
            else "top-openvsx-formatter-runtime-partial",
        }
        payload["status"] = "top-openvsx-formatter-runtime-recorded"
    if payload["topOpenVSXLanguageRuntimeMode"]:
        if not payload["networkMode"]:
            raise AssertionError("WIZP_OPENVSX_LANGUAGE_RUNTIME=1 requires WIZP_REAL_EXTENSION_NETWORK=1")
        pyright_runtime = run_pyright_language_runtime_smoke()
        yaml_runtime = run_yaml_language_runtime_smoke()
        clangd_runtime = run_clangd_degraded_runtime_smoke()
        tailwind_runtime = run_tailwind_language_runtime_smoke()
        pyrefly_runtime = run_pyrefly_degraded_runtime_smoke()
        rust_analyzer_runtime = run_rust_analyzer_degraded_runtime_smoke()
        redhat_java_runtime = run_redhat_java_bounded_activation_smoke()
        redhat_java_valid_jdk_runtime = run_redhat_java_valid_jdk_timeout_smoke()
        go_runtime = run_go_missing_tool_degraded_smoke()
        ruby_lsp_runtime = run_ruby_lsp_degraded_runtime_smoke()
        vue_volar_runtime = run_vue_volar_language_runtime_smoke()
        dart_code_runtime = run_dart_code_degraded_runtime_smoke()
        dart_code_valid_sdk_runtime = run_dart_code_valid_sdk_analysis_server_smoke()
        payload["topOpenVSXLanguageRuntime"] = {
            "pyright": pyright_runtime,
            "yaml": yaml_runtime,
            "clangd": clangd_runtime,
            "tailwind": tailwind_runtime,
            "pyrefly": pyrefly_runtime,
            "rustAnalyzer": rust_analyzer_runtime,
            "redhatJava": redhat_java_runtime,
            "redhatJavaValidJdk": redhat_java_valid_jdk_runtime,
            "go": go_runtime,
            "rubyLsp": ruby_lsp_runtime,
            "vueVolar": vue_volar_runtime,
            "dartCode": dart_code_runtime,
            "dartCodeValidSdk": dart_code_valid_sdk_runtime,
            "status": "top-openvsx-language-runtime-verified"
            if pyright_runtime.get("status") == "pyright-language-server-runtime-verified"
            and yaml_runtime.get("status") == "yaml-language-server-runtime-verified"
            and clangd_runtime.get("status") == "clangd-missing-binary-degraded-verified"
            and tailwind_runtime.get("status") == "tailwind-language-server-completion-runtime-verified"
            and pyrefly_runtime.get("status") == "pyrefly-bundled-binary-platform-mismatch-verified"
            and rust_analyzer_runtime.get("status") == "rust-analyzer-missing-binary-degraded-verified"
            and redhat_java_runtime.get("status") == "redhat-java-missing-jdk-degraded-verified"
            and redhat_java_valid_jdk_runtime.get("status")
            in {
                "redhat-java-valid-jdk-host-timeout-recovered",
                "redhat-java-valid-jdk-started-jdt-bounded",
                "redhat-java-valid-jdk-timeout-skipped-no-jdk",
            }
            and go_runtime.get("status") == "go-missing-tool-degraded-verified"
            and ruby_lsp_runtime.get("status")
            in {"ruby-lsp-missing-ruby-degraded-verified", "ruby-lsp-activation-bounded-no-runtime-ux"}
            and vue_volar_runtime.get("status")
            in {
                "vue-volar-language-server-runtime-verified",
                "vue-volar-activation-bounded",
                "vue-volar-typescript-restart-bounded",
                "vue-volar-runtime-bounded-no-server",
            }
            and dart_code_runtime.get("status")
            in {
                "dart-code-missing-sdk-degraded-verified",
                "dart-code-missing-sdk-bounded",
                "dart-code-runtime-bounded-no-sdk-ux",
            }
            and dart_code_valid_sdk_runtime.get("status")
            in {
                "dart-code-valid-sdk-analysis-server-runtime-verified",
                "dart-code-valid-sdk-analysis-server-started",
                "dart-code-valid-sdk-skipped-no-sdk",
            }
            else "top-openvsx-language-runtime-partial",
        }
        payload["status"] = "top-openvsx-language-runtime-recorded"
    if payload["topOpenVSXTop20RuntimeMode"]:
        if not payload["networkMode"]:
            raise AssertionError("WIZP_OPENVSX_TOP20_RUNTIME=1 requires WIZP_REAL_EXTENSION_NETWORK=1")
        payload["topOpenVSXTop20Runtime"] = run_top20_python_runtime_smoke()
        payload["status"] = "top-openvsx-top20-runtime-recorded"
    if payload["officialCodexMode"]:
        if not payload["networkMode"]:
            raise AssertionError("WIZP_OPENVSX_CODEX=1 requires WIZP_REAL_EXTENSION_NETWORK=1")
        payload["officialCodex"] = run_official_codex_smoke()
        payload["status"] = payload["officialCodex"].get(
            "status",
            "official-codex-vscode-extension-and-cli-contract-recorded",
        )
    if payload["loadabilityMode"]:
        if not payload["networkMode"]:
            raise AssertionError("WIZP_REAL_EXTENSION_LOAD=1 requires WIZP_REAL_EXTENSION_NETWORK=1")
        payload["loadability"] = run_loadability_smoke(payload["packages"])
        payload["status"] = "real-packages-installed-command-surface-with-startup-activation-deferred-verified"
    if payload["runtimeMode"]:
        if not payload["networkMode"]:
            raise AssertionError("WIZP_REAL_EXTENSION_RUNTIME=1 requires WIZP_REAL_EXTENSION_NETWORK=1")
        payload["runtimeCommand"] = run_runtime_command_smoke(payload["packages"])
        payload["runtimeProvider"] = run_runtime_provider_smoke(payload["packages"])
        payload["runtimeNpmProvider"] = run_runtime_npm_provider_smoke(payload["packages"])
        payload["runtimeAutoCloseTag"] = run_runtime_auto_close_tag_smoke(payload["packages"])
        payload["runtimeColorHighlight"] = run_runtime_color_highlight_smoke(payload["packages"])
        payload["cspellRuntimeProbe"] = run_cspell_runtime_probe(payload["packages"])
        payload["status"] = "real-package-runtime-command-and-providers-verified"
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"real extension runner ok: {REPORT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
