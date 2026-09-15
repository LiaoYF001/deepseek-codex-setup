import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';

// Only Broker's stdio App Server and version probe are supported. The caller
// cannot append another -c, sandbox option, or approval-policy override.
const args = process.argv.slice(2);
const broker011Args = [
  'app-server', '--stdio', '--strict-config',
  '--disable', 'multi_agent', '--disable', 'multi_agent_v2', '--disable', 'plugins',
];
const allowed = (args.length === 1 && ['app-server', '--version'].includes(args[0]))
  || (args.length === 3 && args[0] === 'app-server'
    && args[1] === '--listen' && args[2] === 'stdio://')
  || (args.length === broker011Args.length && args.every((arg, index) => arg === broker011Args[index]));
if (process.platform !== 'win32' || !allowed) {
  process.stderr.write('[mixagents-windows] unsupported_invocation\n');
  process.exitCode = 64;
} else {
  const directory = path.dirname(fileURLToPath(import.meta.url));
  function executable(candidate) {
    if (!candidate || !path.isAbsolute(candidate) || path.extname(candidate).toLowerCase() !== '.exe') return null;
    try {
      const resolved = fs.realpathSync.native(candidate);
      return fs.statSync(resolved).isFile() ? resolved : null;
    } catch { return null; }
  }
  function locateCodex() {
    const npmRoots = [];
    // Execute only a real .exe. A shim is used solely to infer its npm package
    // directory; the .cmd/.bat contents are never read or executed.
    for (const entry of (process.env.PATH || '').split(path.delimiter)) {
      const folder = entry.trim().replace(/^"(.*)"$/, '$1');
      if (!path.isAbsolute(folder)) continue;
      const found = executable(path.join(folder, 'codex.exe'));
      if (found) return found;
      if (fs.existsSync(path.join(folder, 'codex.cmd')) || fs.existsSync(path.join(folder, 'codex.bat'))) {
        npmRoots.push(path.join(folder, 'node_modules', '@openai', 'codex'));
      }
    }
    const managedRoot = process.env.CODEX_MANAGED_PACKAGE_ROOT;
    const discoveryRoots = managedRoot && path.isAbsolute(managedRoot) ? [managedRoot, ...npmRoots] : npmRoots;
    for (const root of discoveryRoots) {
      const architectures = process.arch === 'arm64' ? ['aarch64-pc-windows-msvc', 'x86_64-pc-windows-msvc'] : ['x86_64-pc-windows-msvc'];
      const packageRoots = [root];
      try {
        const require = createRequire(path.join(root, 'package.json'));
        const platformPackage = `@openai/codex-win32-${process.arch === 'arm64' ? 'arm64' : 'x64'}`;
        packageRoots.push(path.dirname(require.resolve(`${platformPackage}/package.json`)));
      } catch { /* Older packages keep the executable directly under root. */ }
      const candidates = [];
      for (const packageRoot of packageRoots) {
        candidates.push(path.join(packageRoot, 'codex.exe'), path.join(packageRoot, 'bin', 'codex.exe'));
        for (const architecture of architectures) {
          candidates.push(path.join(packageRoot, 'vendor', architecture, 'bin', 'codex.exe'));
          candidates.push(path.join(packageRoot, 'vendor', architecture, 'codex', 'codex.exe'));
        }
      }
      for (const candidate of candidates) {
        const found = executable(candidate);
        if (found) return found;
      }
    }
    try {
      const settings = JSON.parse(fs.readFileSync(path.join(directory, 'settings.json'), 'utf8'));
      if (settings && settings.schemaVersion === 1 && typeof settings.codexExecutable === 'string') {
        return executable(settings.codexExecutable);
      }
    } catch { /* Missing/invalid settings never disclose file contents. */ }
    return null;
  }
  const codex = locateCodex();
  if (!codex) {
    process.stderr.write('[mixagents-windows] codex_unavailable\n');
    process.exitCode = 127;
  } else {
    // Official per-process CLI override; user configuration, access mode and
    // on-request approval remain under Codex/App Server control.
    let failed = false;
    const launchFailed = () => {
      failed = true;
      process.stderr.write('[mixagents-windows] launch_failed\n');
      process.exitCode = 127;
    };
    let child;
    try {
      child = spawn(codex, ['-c', 'windows.sandbox="unelevated"', ...args], {
        stdio: 'inherit', windowsHide: true, shell: false,
      });
    } catch { launchFailed(); }
    if (child) {
      child.once('error', launchFailed);
      child.once('exit', (code, signal) => {
        if (!failed) process.exitCode = code ?? (128 + (os.constants.signals[signal] || 1));
      });
    }
  }
}
