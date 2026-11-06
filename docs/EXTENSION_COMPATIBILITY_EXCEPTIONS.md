# Extension Compatibility Exception Register

This register covers core branches that are intentionally specific to an extension or extension-owned dependency. An exception must remain narrow, tested, and removable. New entries require a failing compatibility fixture and an update to `scripts/check_core_extension_boundary.py`.

| Exception | Reason | Removal condition |
| --- | --- | --- |
| `redhat.java` background activation | Java JDT lifecycle requires host preparation before the normal activation path can settle. | Paired Java Pack/JDT activation succeeds without host-side precreation or background activation support. |
| `redhat.java` runtime preflight | Surface a deterministic missing-JDK error instead of entering an unbounded adapter startup path. | Missing-JDK behavior is fully owned by the extension and matches the reference host without the core preflight. |
| `ms-python.python` dependency shim | Permit the Python extension dependency graph to activate when the compatible host API is explicitly enabled. | Python extension activation succeeds through the normal dependency path with the shim environment variable unset. |
| `vscode.git`, `vscode.docker`, `vscode.yaml`, `vscode.typescript-language-features` dependency shims | Permit built-in dependency identifiers represented by WIZP-owned host surfaces. | Each dependency is provided by a real compatible built-in extension/runtime surface. |
| `ms-python.python`, `vscode.git`, `vscode.docker`, `vscode.yaml`, `vscode.typescript-language-features` `getExtension` branches | Preserve lookup compatibility for built-in or bundled identifiers. | Generic extension lookup covers the identifier without a core branch. |
| GitKraken configuration fetch policy | Keep a known extension-owned remote configuration path behind the explicit network policy and audit trail. | GitLens/GitKraken behavior uses the generic consent-gated network path. |

The register is descriptive evidence, not permission to add behavior. The executable allowlists remain in `scripts/check_core_extension_boundary.py`.
