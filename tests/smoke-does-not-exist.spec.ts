import { describe, expect, it } from 'vitest'
import * as entry from '../src/index.ts'

/**
 * A smoke test of the plugin entry as DeepSeek Harness loads it: the module has to resolve with its whole import
 * graph, name itself, declare the services it injects and apply them. What `apply` then does has its own specs.
 */
describe('plugin entry', () => {
  it('resolves from the package entry and declares the plugin identity DSH mounts', () => {
    expect(entry.name).toBe('dsh-superagent')
    expect(entry.inject).toEqual(expect.arrayContaining(['agents', 'sessionController', 'tools', 'llm', 'subprocess']))
    expect(typeof entry.apply).toBe('function')
    expect(typeof entry.Config).toBe('function')
  })
})
