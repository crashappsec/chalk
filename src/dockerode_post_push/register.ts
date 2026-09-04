declare function require(id: string): unknown;

// Loaded with --require in every Node process in the wrapped command tree.
// Keep this bootstrap syntax deliberately old and make loading completely
// fail-open: unsupported runtimes or missing/corrupt private loader files must
// never change the wrapped process's behavior or exit status.
try {
  require('./register_impl.cjs');
} catch (_) {
  // Instrumentation is best-effort. Never rethrow from the preload hook.
}
