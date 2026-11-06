#!/usr/bin/env node
/**
 * WIZP - VS Code Extension Host
 * Loads and runs VS Code extensions (.vsix) in a subprocess.
 * Communicates with WIZP via MCP JSON-RPC over stdin/stdout.
 * 
 * Usage: node extension_host.js /path/to/extension/
 */

const path = require('path');
const fs = require('fs');

// Load our vscode API shim
const vscode = require('./vscode');

// Loaded extensions
const loadedExtensions = new Map();

/**
 * Load a VS Code extension from a directory
 */
function loadExtension(extensionPath) {
    try {
        const packageJsonPath = path.join(extensionPath, 'package.json');
        if (!fs.existsSync(packageJsonPath)) {
            console.error(`No package.json found in ${extensionPath}`);
            return false;
        }

        const manifest = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'));
        const mainFile = manifest.main || './extension.js';
        const mainPath = path.join(extensionPath, mainFile);

        if (!fs.existsSync(mainPath)) {
            console.error(`Main file not found: ${mainPath}`);
            return false;
        }

        console.error(`Loading extension: ${manifest.name} v${manifest.version}`);

        // Set up extension context
        const context = new vscode.ExtensionContext();
        context.extensionPath = extensionPath;
        context.extensionUri = vscode.Uri.file(extensionPath);

        // Require and activate
        const extension = require(mainPath);
        if (typeof extension.activate === 'function') {
            extension.activate(context);
        }

        // Register activation events from manifest
        if (manifest.activationEvents) {
            for (const event of manifest.activationEvents) {
                if (event === 'onLanguage:javascript' || event.startsWith('onLanguage:')) {
                    // Extension activates for specific languages
                }
            }
        }

        loadedExtensions.set(manifest.name, { manifest, context, extension });
        console.error(`Activated: ${manifest.name}`);

        // Report back to WIZP
        process.stdout.write(JSON.stringify({
            jsonrpc: '2.0',
            method: 'vscode/extension/activated',
            params: { name: manifest.name, version: manifest.version }
        }) + '\n');

        return true;
    } catch (e) {
        console.error(`Failed to load extension: ${e.message}`);
        return false;
    }
}

/**
 * Parse a .vsix file (ZIP)
 */
function extractVsix(vsixPath, destDir) {
    const AdmZip = require('adm-zip');
    try {
        const zip = new AdmZip(vsixPath);
        zip.extractAllTo(destDir, true);
        return true;
    } catch (e) {
        console.error(`Failed to extract .vsix: ${e.message}`);
        return false;
    }
}

// ============================================================
// MCP Message Loop
// ============================================================

let buffer = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
    buffer += chunk;
    const lines = buffer.split('\n');
    buffer = lines.pop() || '';
    
    for (const line of lines) {
        if (!line.trim()) continue;
        try {
            const msg = JSON.parse(line);
            handleMessage(msg);
        } catch (e) {}
    }
});

function handleMessage(msg) {
    const { id, method, params } = msg;

    if (method === 'initialize') {
        sendResponse(id, { capabilities: { tools: {}, resources: {} } });
    } else if (method === 'vscode/extension/load') {
        const success = loadExtension(params.path);
        sendResponse(id, { success });
    } else if (method === 'vscode/extension/loadVsix') {
        const tmpDir = path.join(params.destDir, params.name);
        fs.mkdirSync(tmpDir, { recursive: true });
        extractVsix(params.vsixPath, tmpDir);
        const success = loadExtension(tmpDir);
        sendResponse(id, { success });
    } else if (method === 'vscode/extension/unload') {
        loadedExtensions.delete(params.name);
        sendResponse(id, { success: true });
    } else if (method === 'shutdown') {
        // Deactivate all extensions
        for (const [name, entry] of loadedExtensions) {
            if (typeof entry.extension.deactivate === 'function') {
                try { entry.extension.deactivate(); } catch (e) {}
            }
        }
        process.exit(0);
    } else {
        sendResponse(id, null);
    }
}

function sendResponse(id, result) {
    if (id === undefined) return;
    process.stdout.write(JSON.stringify({
        jsonrpc: '2.0', id,
        result: result !== undefined ? result : null
    }) + '\n');
}

// Ready signal
process.stdout.write(JSON.stringify({
    jsonrpc: '2.0', method: 'vscode/extension/ready', params: {}
}) + '\n');
