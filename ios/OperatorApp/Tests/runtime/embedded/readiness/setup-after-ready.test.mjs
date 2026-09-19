import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { execFileSync } from 'node:child_process';

test('temporary scene inactivity preserves the runtime; background stops it', () => {
  const source = readFileSync(new URL('../../../../Sources/app/OperatorApp.swift', import.meta.url), 'utf8');
  const handler = source.match(/\.onChange\(of: self.scenePhase, initial: true\) \{ _, phase in\n([\s\S]*?)\n                \}/);
  assert.ok(handler, 'runtime phase handling must distinguish inactivity from background');
  assert.ok(source.includes('.task(id: self.runtimeIsForeground)'), 'runtime task must not be cancelled by temporary inactivity');
  const fixture = `enum Phase { case active, inactive, background }
  final class Harness {
    var runtimeIsForeground = false
    func change(_ phase: Phase) {
      ${handler[1]}
    }
  }
  let app = Harness()
  app.change(.inactive); precondition(!app.runtimeIsForeground)
  app.change(.active); precondition(app.runtimeIsForeground)
  app.change(.inactive); precondition(app.runtimeIsForeground)
  app.change(.active); precondition(app.runtimeIsForeground)
  app.change(.background); precondition(!app.runtimeIsForeground)
  app.change(.inactive); precondition(!app.runtimeIsForeground)
  app.change(.active); precondition(app.runtimeIsForeground)
  `;
  execFileSync('swift', ['-'], { input: fixture, encoding: 'utf8' });
});

test('Operator refreshes sign-in after its native gateway becomes ready', () => {
  const source = readFileSync(new URL('../../../../Sources/app/OperatorApp.swift', import.meta.url), 'utf8');
  const readiness = source.indexOf('try await self.embeddedRuntime.waitUntilReady(token: token)');
  assert.ok(readiness >= 0, 'test must locate the real embedded readiness path');
  const confirmed = source.indexOf('self.chat.runtimeBecameReady()', readiness);
  const refresh = source.indexOf('await self.setup.check()', confirmed);
  const catchBoundary = source.indexOf('} catch', confirmed);
  assert.ok(refresh > confirmed && refresh < catchBoundary,
    'refresh setup in the successful readiness path so an early unavailable result cannot hide Connect ChatGPT');
});
