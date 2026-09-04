import test = require('node:test');
import { verifyEmittedBootstrap } from './bootstrap-regression.cjs';

test('emitted ES5 bootstrap is minimal and fail-open for missing or corrupt implementation', () => {
  verifyEmittedBootstrap();
});
