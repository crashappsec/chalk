import type Serverless from 'serverless';
import ServerlessPlugin from '../src/index.js';
import { execSync } from 'child_process';
import * as fs from 'fs';

jest.mock('child_process');
jest.mock('fs');
jest.mock('chalk', () => ({
  __esModule: true,
  default: {
    blue: (text: string) => text,
    green: (text: string) => text,
    yellow: (text: string) => text,
    red: (text: string) => text,
    cyan: (text: string) => text,
    dim: (text: string) => text,
    gray: (text: string) => text,
    bold: (text: string) => text,
  },
}));

const mockServerless = {
  getProvider: jest.fn().mockReturnValue({}),
  config: {
    servicePath: '/test/project'
  },
  service: {
    service: 'test-service',
    provider: {
      stage: 'dev'
    },
    functions: {
      'function1': {},
      'function2': {
        layers: ['arn:aws:lambda:us-east-1:123456789012:layer:existing1', 'arn:aws:lambda:us-east-1:123456789012:layer:existing2']
      },
      'function3': {
        layers: new Array(14).fill(0).map((_, i) => `arn:aws:lambda:us-east-1:123456789012:layer:layer${i}`)
      },
      'function4': {
        layers: new Array(15).fill(0).map((_, i) => `arn:aws:lambda:us-east-1:123456789012:layer:layer${i}`)
      }
    }
  }
} as any as Serverless;

const mockLog = {
  error: jest.fn(),
  warning: jest.fn(),
  notice: jest.fn(),
  info: jest.fn(),
  debug: jest.fn(),
};

describe('ServerlessPlugin', () => {
  let plugin: ServerlessPlugin;

  beforeEach(() => {
    plugin = new ServerlessPlugin(mockServerless, {}, { log: mockLog });
  });

  afterEach(() => {
    jest.clearAllMocks();
  });

  it('should initialize with correct properties', () => {
    expect(plugin.serverless).toBe(mockServerless);
    expect(plugin.options).toEqual({});
    expect(plugin.hooks).toBeDefined();
  });

  it('should have the correct hooks registered', () => {
    expect(plugin.hooks['before:package:initialize']).toBeDefined();
    expect(plugin.hooks['after:aws:package:finalize:mergeCustomProviderResources']).toBeDefined();
  });

  it('should log before package initialize and check for chalk binary', async () => {
    const mockExecSync = execSync as jest.MockedFunction<typeof execSync>;
    mockExecSync.mockImplementation(() => Buffer.from(''));

    const hook = plugin.hooks['before:package:initialize'];
    if (hook) {
      await hook();
    }

    expect(mockLog.notice).toHaveBeenCalledWith(
      '🔧 Dust Plugin: Initializing package process'
    );
    expect(mockLog.info).toHaveBeenCalledWith('ℹ Checking for chalk binary...');
    expect(mockLog.info).toHaveBeenCalledWith('✓ Chalk binary found');
    expect(mockLog.info).toHaveBeenCalledWith('ℹ Chalk binary found and will be used to add chalkmarks');
    expect(mockExecSync).toHaveBeenCalledWith('which chalk', { stdio: 'ignore' });
  });

  it('should handle chalk binary not found', () => {
    const mockExecSync = execSync as jest.MockedFunction<typeof execSync>;
    mockExecSync.mockImplementation(() => {
      throw new Error('Command not found');
    });

    const result = (plugin as any).chalkBinaryAvailable();

    expect(result).toBe(false);
    expect(mockLog.info).toHaveBeenCalledWith('ℹ Checking for chalk binary...');
    expect(mockLog.warning).toHaveBeenCalledWith('⚠ Chalk binary not found in PATH');
  });

  it('should run both addDustLambdaExtension and injectChalkBinary after package initialize', async () => {
    const mockExecSync = execSync as jest.MockedFunction<typeof execSync>;
    const mockFs = fs as jest.Mocked<typeof fs>;

    // Create plugin with functions that won't exceed layer limit
    const integrationPlugin = new ServerlessPlugin({
      ...mockServerless,
      service: {
        ...mockServerless.service,
        functions: {
          'function1': {},
          'function2': { layers: ['existing-layer-1'] }
        }
      }
    } as any, {}, { log: mockLog });

    mockExecSync.mockImplementation((cmd: string) => {
      if (cmd === 'which chalk') {
        return Buffer.from('');
      }
      if (cmd.includes('chalk insert')) {
        return Buffer.from('Successfully inserted chalkmarks');
      }
      return Buffer.from('');
    });

    mockFs.existsSync.mockReturnValue(true);

    const hook = integrationPlugin.hooks['after:aws:package:finalize:mergeCustomProviderResources'];
    if (hook) {
      await hook();
    }

    // Check that afterPackageInitialize was called
    expect(mockLog.notice).toHaveBeenCalledWith('📦 Dust Plugin: Processing packaged functions');

    // Check that addDustLambdaExtension was called
    expect(mockLog.notice).toHaveBeenCalledWith('🚀 Adding Dust Lambda Extension to all functions');
    expect(mockLog.notice).toHaveBeenCalledWith('✓ Successfully added Dust Lambda Extension to 2 function(s)');

    // Check that injectChalkBinary was called
    expect(mockLog.info).toHaveBeenCalledWith(expect.stringContaining('ℹ Injecting chalkmarks into'));
    expect(mockLog.notice).toHaveBeenCalledWith('✓ Successfully injected chalkmarks into package');
    expect(mockExecSync).toHaveBeenCalledWith(
      expect.stringContaining('chalk insert --inject-binary-into-zip'),
      { stdio: 'pipe', encoding: 'utf8' }
    );
  });

  it('should skip chalkmark injection when chalk is not available', async () => {
    const mockExecSync = execSync as jest.MockedFunction<typeof execSync>;

    // Create plugin with functions that won't exceed layer limit
    const chalkUnavailablePlugin = new ServerlessPlugin({
      ...mockServerless,
      service: {
        ...mockServerless.service,
        functions: {
          'function1': {}
        }
      }
    } as any, {}, { log: mockLog });

    mockExecSync.mockImplementation((cmd: string) => {
      if (cmd === 'which chalk') {
        throw new Error('Command not found');
      }
      return Buffer.from('');
    });

    const hook = chalkUnavailablePlugin.hooks['after:aws:package:finalize:mergeCustomProviderResources'];
    if (hook) {
      await hook();
    }

    expect(mockLog.notice).toHaveBeenCalledWith('📦 Dust Plugin: Processing packaged functions');
    expect(mockLog.warning).toHaveBeenCalledWith('⚠ Chalk binary not available, skipping chalkmark injection');
  });

  it('should handle missing zip file', async () => {
    const mockExecSync = execSync as jest.MockedFunction<typeof execSync>;
    const mockFs = fs as jest.Mocked<typeof fs>;

    // Create plugin with functions that won't exceed layer limit
    const zipMissingPlugin = new ServerlessPlugin({
      ...mockServerless,
      service: {
        ...mockServerless.service,
        functions: {
          'function1': {}
        }
      }
    } as any, {}, { log: mockLog });

    mockExecSync.mockImplementation((cmd: string) => {
      if (cmd === 'which chalk') {
        return Buffer.from('');
      }
      return Buffer.from('');
    });

    mockFs.existsSync.mockReturnValue(false);

    const hook = zipMissingPlugin.hooks['after:aws:package:finalize:mergeCustomProviderResources'];
    if (hook) {
      await hook();
    }

    expect(mockLog.notice).toHaveBeenCalledWith('📦 Dust Plugin: Processing packaged functions');
    expect(mockLog.warning).toHaveBeenCalledWith('⚠ Package zip file not found at /test/project/.serverless/test-service.zip');
    expect(mockLog.error).toHaveBeenCalledWith('✗ Could not locate package zip file');
  });

  it('should add dust Lambda Extension to functions with no existing layers', () => {
    // Create a simple mock serverless with one function
    const simplePlugin = new ServerlessPlugin({
      ...mockServerless,
      service: {
        ...mockServerless.service,
        functions: {
          'testFunction': {}
        }
      }
    } as any, {}, { log: mockLog });

    (simplePlugin as any).addDustLambdaExtension();

    expect(mockLog.notice).toHaveBeenCalledWith('🚀 Adding Dust Lambda Extension to all functions');
    expect(mockLog.info).toHaveBeenCalledWith('ℹ Added Dust Lambda Extension to function: testFunction (1/15 layers/extensions)');
    expect(mockLog.notice).toHaveBeenCalledWith('✓ Successfully added Dust Lambda Extension to 1 function(s)');

    // Verify the layer was actually added
    const func = (simplePlugin.serverless.service.functions as any)['testFunction'];
    expect(func.layers).toEqual(['arn:aws:lambda:us-east-1:123456789012:layer:my-extension']);
  });

  it('should add dust Lambda Extension to functions with existing layers', () => {
    // Create a plugin with function that has 2 existing layers
    const pluginWithLayers = new ServerlessPlugin({
      ...mockServerless,
      service: {
        ...mockServerless.service,
        functions: {
          'testFunction': {
            layers: ['existing-layer-1', 'existing-layer-2']
          }
        }
      }
    } as any, {}, { log: mockLog });

    (pluginWithLayers as any).addDustLambdaExtension();

    expect(mockLog.info).toHaveBeenCalledWith('ℹ Added Dust Lambda Extension to function: testFunction (3/15 layers/extensions)');
    expect(mockLog.notice).toHaveBeenCalledWith('✓ Successfully added Dust Lambda Extension to 1 function(s)');

    // Verify the layer was added to existing layers
    const func = (pluginWithLayers.serverless.service.functions as any)['testFunction'];
    expect(func.layers).toEqual([
      'existing-layer-1',
      'existing-layer-2',
      'arn:aws:lambda:us-east-1:123456789012:layer:my-extension'
    ]);
  });

  it('should handle function with 14 existing layers (should accept extension)', () => {
    const pluginWith14Layers = new ServerlessPlugin({
      ...mockServerless,
      service: {
        ...mockServerless.service,
        functions: {
          'testFunction': {
            layers: new Array(14).fill(0).map((_, i) => `layer-${i}`)
          }
        }
      }
    } as any, {}, { log: mockLog });

    (pluginWith14Layers as any).addDustLambdaExtension();

    expect(mockLog.info).toHaveBeenCalledWith('ℹ Added Dust Lambda Extension to function: testFunction (15/15 layers/extensions)');
    expect(mockLog.notice).toHaveBeenCalledWith('✓ Successfully added Dust Lambda Extension to 1 function(s)');
  });

  it('should throw error when function has 15 existing layers', () => {
    const pluginWith15Layers = new ServerlessPlugin({
      ...mockServerless,
      service: {
        ...mockServerless.service,
        functions: {
          'testFunction': {
            layers: new Array(15).fill(0).map((_, i) => `layer-${i}`)
          }
        }
      }
    } as any, {}, { log: mockLog });

    expect(() => {
      (pluginWith15Layers as any).addDustLambdaExtension();
    }).toThrow('Cannot add Dust Lambda Extension to function testFunction: would exceed maximum layer/extension limit of 15 (currently has 15)');

    expect(mockLog.error).toHaveBeenCalledWith('✗ Cannot add Dust Lambda Extension to function testFunction: would exceed maximum layer/extension limit of 15 (currently has 15)');
  });

  it('should handle service with no functions', () => {
    const pluginNoFunctions = new ServerlessPlugin({
      ...mockServerless,
      service: {
        ...mockServerless.service,
        functions: {}
      }
    } as any, {}, { log: mockLog });

    (pluginNoFunctions as any).addDustLambdaExtension();

    expect(mockLog.notice).toHaveBeenCalledWith('🚀 Adding Dust Lambda Extension to all functions');
    expect(mockLog.warning).toHaveBeenCalledWith('⚠ No functions found in service - no extensions added');
  });

  it('should validate all functions before modifying any (atomic operation)', () => {
    const pluginMixedFunctions = new ServerlessPlugin({
      ...mockServerless,
      service: {
        ...mockServerless.service,
        functions: {
          'validFunction': { layers: [] },
          'invalidFunction': { layers: new Array(15).fill(0).map((_, i) => `layer-${i}`) }
        }
      }
    } as any, {}, { log: mockLog });

    expect(() => {
      (pluginMixedFunctions as any).addDustLambdaExtension();
    }).toThrow('Cannot add Dust Lambda Extension to function invalidFunction: would exceed maximum layer/extension limit of 15 (currently has 15)');

    // Verify that the valid function was not modified
    const validFunc = (pluginMixedFunctions.serverless.service.functions as any)['validFunction'];
    expect(validFunc.layers).toEqual([]); // Should still be empty array, not modified
  });
});
