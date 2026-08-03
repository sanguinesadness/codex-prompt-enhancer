import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { describe, it } from "node:test";

import {
  ProcessTerminationController,
  ProcessTerminationScheduler,
  ProcessTerminationTimer,
  TerminableChildProcess,
} from "../src/processTermination";

class FakeChild extends EventEmitter
  implements TerminableChildProcess {
  public exitCode: number | null = null;
  public signalCode: NodeJS.Signals | null = null;
  public readonly signals: NodeJS.Signals[] = [];

  public kill(signal: NodeJS.Signals): boolean {
    this.signals.push(signal);
    return true;
  }
}

class FakeTimer implements ProcessTerminationTimer {
  public cleared = false;
  public unreferenced = false;

  public constructor(
    public readonly callback: () => void,
    public readonly delayMilliseconds: number,
  ) {}

  public unref(): void {
    this.unreferenced = true;
  }
}

class FakeScheduler
  implements ProcessTerminationScheduler {
  public readonly timers: FakeTimer[] = [];

  public setTimeout = (
    callback: () => void,
    delayMilliseconds: number,
  ): FakeTimer => {
    const timer = new FakeTimer(
      callback,
      delayMilliseconds,
    );
    this.timers.push(timer);
    return timer;
  };

  public clearTimeout = (
    timer: ProcessTerminationTimer,
  ): void => {
    (timer as FakeTimer).cleared = true;
  };
}

describe("process termination controller", () => {
  it("sends one SIGTERM for repeated requests", () => {
    const child = new FakeChild();
    const scheduler = new FakeScheduler();
    const controller =
      new ProcessTerminationController(
        child,
        5_000,
        scheduler,
      );

    controller.requestTermination();
    controller.requestTermination();

    assert.deepEqual(child.signals, ["SIGTERM"]);
    assert.equal(scheduler.timers.length, 1);
    assert.equal(
      scheduler.timers[0]?.delayMilliseconds,
      5_000,
    );
    assert.equal(
      scheduler.timers[0]?.unreferenced,
      true,
    );
  });

  it("supports helper and Codex grace periods", () => {
    for (const grace of [5_000, 2_000]) {
      const child = new FakeChild();
      const scheduler = new FakeScheduler();
      const controller =
        new ProcessTerminationController(
          child,
          grace,
          scheduler,
        );

      controller.requestTermination();

      assert.equal(
        scheduler.timers[0]?.delayMilliseconds,
        grace,
      );
      controller.dispose();
    }
  });

  it("escalates to SIGKILL after grace expires", () => {
    const child = new FakeChild();
    const scheduler = new FakeScheduler();
    const controller =
      new ProcessTerminationController(
        child,
        2_000,
        scheduler,
      );

    controller.requestTermination();
    scheduler.timers[0]?.callback();

    assert.deepEqual(
      child.signals,
      ["SIGTERM", "SIGKILL"],
    );
  });

  it("clears escalation after child exit", () => {
    const child = new FakeChild();
    const scheduler = new FakeScheduler();
    const controller =
      new ProcessTerminationController(
        child,
        5_000,
        scheduler,
      );

    controller.requestTermination();
    child.exitCode = 0;
    child.emit("close", 0, null);
    scheduler.timers[0]?.callback();

    assert.deepEqual(child.signals, ["SIGTERM"]);
    assert.equal(
      scheduler.timers[0]?.cleared,
      true,
    );
  });

  it("disposes timers and completion listeners", () => {
    const child = new FakeChild();
    const scheduler = new FakeScheduler();
    const controller =
      new ProcessTerminationController(
        child,
        5_000,
        scheduler,
      );

    controller.requestTermination();
    controller.dispose();
    controller.dispose();

    assert.equal(child.listenerCount("close"), 0);
    assert.equal(child.listenerCount("error"), 0);
    assert.equal(
      scheduler.timers[0]?.cleared,
      true,
    );
  });

  it("does nothing after exit or spawn failure", () => {
    const exitedChild = new FakeChild();
    exitedChild.exitCode = 1;
    const exitedScheduler = new FakeScheduler();
    const exitedController =
      new ProcessTerminationController(
        exitedChild,
        2_000,
        exitedScheduler,
      );

    exitedController.requestTermination();

    assert.deepEqual(exitedChild.signals, []);
    assert.equal(exitedScheduler.timers.length, 0);

    const failedChild = new FakeChild();
    const failedScheduler = new FakeScheduler();
    const failedController =
      new ProcessTerminationController(
        failedChild,
        2_000,
        failedScheduler,
      );

    failedChild.emit("error", new Error("synthetic"));
    failedController.requestTermination();

    assert.deepEqual(failedChild.signals, []);
    assert.equal(failedScheduler.timers.length, 0);
  });
});
